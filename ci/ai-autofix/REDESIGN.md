# CI auto-fix — redesign working document

Living document for reviewing the existing CI auto-fix implementation phase by
phase, recording what we find, and planning the next implementation. We work in
this repo; `README.md` describes the system **as built**, this file describes
what we intend to change and why.

## How to use this document

Walk the phases one at a time. For each, fill in the template below. A phase
stays `Not yet reviewed` until we have actually gone through it together — an
empty section is a signal, not an oversight.

```
**Status:**      Not yet reviewed | In review | Reviewed — decision recorded
**Code:**        files that implement it
**Today:**       what it actually does now (not what we wish it did)
**Issues:**      defects, fragility, silent-failure modes
**Options:**     alternatives with honest tradeoffs
**Decision:**    what we chose, or "open"
**Follow-ups:**  concrete work items
```

Two rules that came out of the Phase B review and are worth keeping:

1. **Prefer a loud failure to a clever one.** Most of what we found in Phase B
   was not "wrong output" but "no output, logged as ambiguity." Silent
   degradation is the dominant failure mode in this codebase.
2. **Record what we could not verify.** This repo is an extract — there is no
   `apps/` tree, no `ci/Dockerfile`, no `ci/nx-e2e-affected.sh`. Anything that
   depends on the real monorepo gets written down as an open question rather
   than assumed.

## Phase map

The system is a chain. Each link is gated on the previous one producing an
artifact, so any link that fails quietly disables everything downstream.

| Phase | Name                | Trigger                        | Produces                              |
| ----- | ------------------- | ------------------------------ | ------------------------------------- |
| 0     | Capture             | every instrumented stage       | `ci-output.txt`, `FAILED_STAGE`       |
| A     | Deterministic fix   | Check Format / Lint failure    | `autofix.patch`, `autofix.env`        |
| B     | E2E identity parse  | E2E Tests failure              | `e2e-failure.env`                     |
| C     | E2E isolation       | `e2e-failure.env` exists       | `e2e-isolation.env`                   |
| D     | Quarantine patch    | isolation verdict is `pass`    | `e2e-quarantine.patch` + `.env`       |
| E     | Publish             | artifacts + `ENABLE_AI_AUTOFIX` | PR comment, or commit on feature branch |

Plus three cross-cutting concerns that are not phases but constrain all of
them: the credential boundary, the mechanical gates, and the local test
harness. And one parked component: the Tier 1 Cursor agent.

---

## Phase 0 — Capture

**Status:** In review — Format/Lint scope reviewed, E2E capture still open
**Code:** `pipeline-helpers.groovy` (`runCaptured`), `Jenkinsfile` stage blocks

**Today:** Each instrumented stage runs inside the CI Docker image with stdout
and stderr tee'd to a temp file, then truncated into `ci-output.txt` with
`tail -c <captureBytes>` — 200 KiB for most stages, 2 MiB for E2E. The real
exit status is preserved through `PIPESTATUS[0]`, and the `catch` block records
`FAILED_STAGE` before rethrowing.

Worth noting up front, because it shaped the Phase B discussion: the capture is
a **tail**, which is the correct choice for a Cypress log, since the end-of-run
summary is exactly what the parser needs. Any redesign that starts reading from
the top of the log inherits a truncation hazard that does not exist today.

### Issues — Format/Lint scope

**The capture is unused on this path.** Nothing in Phase A ever reads
`ci-output.txt`. `run.sh:34` checks only that the file *exists*:

```sh
[[ -f ci-output.txt ]] || { log "ci-output.txt missing; skipping"; exit 0; }
```

So on the Format/Lint path we produce up to 200 KiB of captured text purely so
that a file exists. It is a gate token, not data. The only consumers of the
*contents* anywhere in the repo are `parse-e2e-failure.sh` and the parked
`agent-fix.sh` / `PROMPT.md`.

**Most instrumented stages need no capture at all.** `runCaptured` wraps five
stages — Check Format, Lint, Unit Tests, E2E Tests, Build. Exactly one of them
has its text consumed. Unit Tests and Build are not even autofix-eligible, so
their captures are entirely dead.

**The gate is close to vacuous.** `tail` runs regardless of the command's exit
status, so the file exists after any instrumented stage, passing or failing. It
cannot distinguish "we captured a failure" from "docker ran at all." It is
effectively unfalsifiable rather than a real precondition.

**The location costs more than the bytes.** Because the file is written to the
repo root, five places exist solely to stop it being read as a dirty tree or
swept into a patch: `_E2E_ARTIFACT_RE` and the `-e` list in `restore_tree`
(`lib.sh`), two `grep -vE` filters in `run.sh`, and
`git add -A -- ':(exclude)ci-output.txt'`. This tax already grew once, when the
E2E artifacts had to be added to the same lists.

**Two smaller footguns in `runCaptured`:**

- The shell script is assembled by Groovy string concatenation
  (`''' + command + '''`). A command containing a quote would behave
  surprisingly; one containing `'''` would break the build. All five current
  commands are simple, so this is latent, not active.
- `tail -c` cuts on a byte boundary, so it can split a line and mangle UTF-8 at
  the head of the file. Harmless for the E2E parser only because that parser
  reads from the end — luck, not design. `tail -n` would be line-safe.

Not a defect, but worth writing down: `set -uo pipefail` without `-e` is
deliberate and correct here, since the real status is recovered from
`PIPESTATUS[0]`.

### Options — Format/Lint scope

**1. Stop capturing on Check Format, Lint, Unit Tests and Build.** A plain `sh`
step inside the same try/catch that records `FAILED_STAGE` gives Phase A
everything it consumes, because `FAILED_STAGE` plus `CHANGE_TARGET` is the
entire input. Jenkins already retains full console output for humans, so
nothing is lost. The existence gate in `run.sh` should then be deleted outright
rather than left as a check that cannot meaningfully fail.

**2. Move any remaining capture out of the working tree**, into a sibling
directory of the pattern `AI_AUTOFIX_ARTIFACT_DIR` already uses. This is the
one change that helps the E2E path too, and it deletes all five exclusions.

**3. If we want structured Format/Lint data, take it from the tools.** The
`@nx/eslint:lint` executor exposes `format` and `outputFile`, so ESLint JSON
can be written directly; `nx format:check` already emits a plain file list. But
this would be for *reporting* — a richer PR comment such as "7 rules across 3
files" — and not for fixing.

The reason option 3 is optional is the most important finding of this review:
**Phase A deliberately recomputes rather than parses.** The fixer reruns
`nx format:write` / `lint --fix` over the affected set and never needs to know
which files failed. That is the correct design, and it is precisely why the log
went unread. Any redesign should preserve "recompute, don't parse" and treat
captured text as a reporting concern only.

### Decision

Open, but the direction is to drop the capture on the three or four stages that
do not consume it, delete the vacuous gate, and relocate the remaining E2E
capture outside the repo root.

**Coupling to flag:** `PROMPT.md` instructs the parked Tier 1 agent to read
`ci-output.txt`. Dropping the Format/Lint capture is safe while the agent stays
parked, so the capture decision and the revive-or-delete decision on the agent
should be taken together.

### Still open for Phase 0

- Whether the E2E capture keeps a byte tail or moves to a line tail.
- Whether 200 KiB would have been enough for a wide `nx affected` Lint failure
  — now moot if the capture is dropped on that path.
- Nothing records *which* stage produced `ci-output.txt` inside the file
  itself; correlation is via `FAILED_STAGE` only. Each instrumented stage
  overwrites it, so it holds the last stage to run. Correct in practice only
  because the pipeline aborts on failure.

---

## Phase A — Deterministic Format/Lint fix

**Status:** Reviewed — action list agreed, sequencing open
**Code:** `run.sh`, `lib.sh` (`deterministic_fix`, `verify_cmd`, `gate_patch`)

**Today:** On a Check Format or Lint failure, `run.sh` runs with no Bitbucket
token and no Cursor key. It resets the tree to `HEAD` to drop Compile and
postinstall noise, runs the matching deterministic fixer (`nx format:write` or
`nx affected --target=lint --fix`), captures the result as a patch, runs it
through the path gate, then proves it by applying to a pristine tree and
re-running the real stage check. Only a genuine pass emits an artifact. Every
gate fails open with exit 0 so the original build failure stays the signal.

The goal for this phase is narrow and worth restating: **offer an autofix when
Format or Lint fails.** The machinery already does that. What follows is about
making it correct in more cases, helpful in more cases, and cheaper to act on.

### Actions — correctness

Small, independent, no policy implications.

**A1. Make the fixer and the verifier cover the same range.** `verify_cmd`
calls `format:check --base origin/$CHANGE_TARGET --head HEAD`, but
`deterministic_fix` calls `format:write --base origin/$CHANGE_TARGET` with no
`--head`. The set we fix is not guaranteed to equal the set we check. One-word
fix; removes a category of "fixed it, verify still fails."

**A2. Verify both Format and Lint, not only the failed stage.**
`try_publishable_patch` calls `verify_cmd "$FAILED_STAGE"`. If `eslint --fix`
emits code Prettier disagrees with, the patch passes Lint verification and then
breaks Check Format on the next build. Running `format:write` as a
normalization step after `lint --fix` is nearly free insurance.
*Verify first:* whether the ESLint config includes `eslint-config-prettier`. If
it does the risk is largely theoretical; if not, this is live.

**A3. Build the patch from tracked changes only.** Today it is `git add -A`
followed by `git diff --cached`, so a stray untracked file that is not
gitignored can ride along. The path gate blocks *denied* paths but accepts an
unexpected source file. Formatters and linters never create files, so
`git diff HEAD` loses nothing and makes stray content structurally impossible.

### Actions — coverage

**A4. Support partial fixes.** The biggest usefulness gap. If `lint --fix`
resolves nine violations and one needs a human, verification fails and the
whole patch is discarded — the contributor gets nothing despite nine being
fixable. Add a third outcome: comment-only, never apply, labelled honestly as
"fixes 9 of 10." This needs before/after violation counts, which is the one
legitimate use for ESLint JSON via the executor's `outputFile` — measuring, not
fixing, consistent with the Phase 0 conclusion.

**A5. Consider running both fixers whenever either stage fails.** The pipeline
aborts at the first failure, so when Check Format fails, Lint never runs. Fix
only Format and the contributor pushes, Lint then fails, and that is a second
round trip. Tradeoff: verify cost doubles, and we must not claim to have
verified a stage that never failed.

### Actions — delivery

**A6. Reconsider the sibling PR for Format/Lint.** `apply` mode opens a whole
PR into the feature branch for what is often a whitespace diff, which the
contributor must then merge. The E2E path already pushes straight to the branch
tip — and that is the *riskier* change, since it alters test semantics. A
deterministic, verified formatting fix has a stronger claim to direct push than
quarantining does.

**A7. A6 requires rethinking the loop guard.** `open-bitbucket-pr.sh` writes
the `Cursor-Autofix: true` trailer, and `is_bot_change` treats that on HEAD as
"came from autofix, skip." Pushing that trailer directly onto the feature
branch would disable Format/Lint autofix for the remainder of the PR — exactly
why the E2E path invented a separate `e2e-flake` trailer. A6 and A7 move
together or not at all.

**A8. Split the mode parameter per path.** A single `AI_AUTOFIX_MODE` forces
the same risk appetite on deterministic formatting and on test quarantining.
Separate knobs allow Format/Lint in `apply` while E2E stays in `plan`.

**A9. Always leave a trace.** A no-op today is an `echo` into the Jenkins
console that nobody reads. A one-line PR comment saying autofix ran and why it
could not help is the difference between a feature people trust and one they do
not know exists. Same principle as Phase B: prefer a loud failure to a clever
one.

### Actions — cleanup

**A10.** Drop the unused capture and the vacuous existence gate, and move the
remaining E2E capture out of the repo root. See Phase 0.

**A11. Add a happy-path test.** `validate-gates.sh` covers gates and skip
conditions thoroughly but never exercises produce → gate → verify → emit with a
stub fixer, so the core loop is untested.

### Suggested first slice

A1, A2, A3 and A9 — small, independent, no policy implications. A4 is the one
that changes how often the feature actually pays off.

### Still open

- `verify_cmd` re-runs the full stage check, which on a large `nx affected` set
  may dominate the post-failure budget. Probably unavoidable if we want a real
  green, but the cost should be measured.
- Is "deterministic only" still the intended ceiling, or is the parked agent
  tier expected to come back? (See the parked-component section.)

---

## Phase B — E2E identity parse

**Status:** Reviewed — decision open, direction agreed
**Code:** `parse-e2e-failure.sh`, fixtures under `testdata/e2e-fail-*.txt`

### Today

It is **pure text scraping of the CI log**. There is no Cypress reporter, no
structured artifact — the script reads `ci-output.txt` and pattern-matches
prose intended for humans.

Input is the tee'd stdout/stderr of the E2E stage, tailed to 2 MiB, in the
shape Nx produces with `--output-style=static`. Output is three `printf %q`
quoted keys in `e2e-failure.env`: `E2E_PROJECT`, `E2E_SPEC`, `E2E_TITLE`.
Anything less than all three is treated as failure.

The pipeline inside the script:

- **Strip** ANSI/CSI escapes to a temp file so later regexes see plain text.
- **Title** — find the *last* `N failing` line (Cypress prints the block twice,
  per-spec and again at the end, so the last one is the aggregate), slice to
  EOF, take the `1)` entry and stop at `2)`, then take the first line indented
  two or more spaces whose first character is neither space nor digit. The
  digit exclusion is what stops it grabbing a sibling numbered entry. Trailing
  colon stripped. **In a multi-failure run, first failure wins.**
- **Spec** — searched only in the region *above* the failing summary, for the
  last `Spec Ran:` or `Running:` line, with a looser fallback. `normalize_spec`
  reduces absolute or `/apps/<project>/` paths to project-relative, which is
  what `nx --spec` expects.
- **Project** — three sources in priority order: the `Failed tasks:` block, any
  `*-e2e:e2e` target anywhere, then `/apps/<name>/` inferred from the path.
- **Ambiguity guard** — more than one distinct `*-e2e` target with no
  `Failed tasks:` block to break the tie is a hard bail.

Every rejection goes through `die`, which deletes the output file and exits 1.
Because Phases C through E are gated on `e2e-failure.env` existing, an
uncertain parse cleanly disables the rest of the chain instead of guessing.
That part of the design is sound and should survive any rewrite.

### Issues found

Three concrete defects, all fixed in PR #1 (`fix-parse-portability-and-test-fixtures`):

- **`mawk` incompatibility.** The leaf-title match used an awk interval
  expression, `/^[[:space:]]{2,}[^[:space:]0-9]/`. `mawk` — the default `awk`
  on Debian and Ubuntu, and what busybox ships — does not support `{2,}`. On
  any such image the pattern never matched, the title came back empty, and the
  script died with "could not extract leaf it title." Since C through E are
  gated on the output file, **the entire E2E isolate-and-quarantine path was
  dead on those images**, presenting as "every failure is unparseable." Works
  fine under `gawk`, so whether it bit depended entirely on which awk is in the
  CI Docker image — still unconfirmed against the real image.
- **Non-POSIX grep syntax.** `SPEC_RE` used a Perl-style non-capturing group
  `(?:` inside `grep -E`. GNU grep warns and continues; BSD and busybox grep
  may reject it. Only visible once parsing got far enough to reach it.
- **Fixture drift.** `validate-gates.sh` read `e2e-fail-acme-app.txt` while the
  file on disk was `e2e-fail-nxt.txt`, later renamed to
  `e2e-fail-acme-product.txt` with de-branded contents — three distinct names.
  The assertion also still expected the pre-de-branding spec path.

With PR #1 applied the suite goes from 72 passed / 10 failed to 76 / 6.

The underlying problem is structural, not any one regex: **the parser is
entirely positional and textual.** A Cypress or Nx reporter format change
breaks it with no signal beyond "ambiguous" in a log nobody reads. That is
precisely how the `mawk` bug stayed invisible.

### Options

**1. JUnit XML** via the bundled `mocha-junit-reporter` (`reporter: 'junit'`).
No custom code, and Jenkins consumes it natively with the `junit` step, which
would add test trend reporting in the UI as a side benefit. The catch: JUnit
XML is organized around suite and test *titles*, not spec *file paths*, and
Phase C needs a path for `nx --spec`. Whether the spec path survives into the
XML depends on reporter version and options — **this is the first thing to
verify** if we go this route, because if it does not, we are back to inferring
the file from the suite name.

**2. The `after:spec` Node event** in `setupNodeEvents`. Cypress passes
`(spec, results)`, where `spec.relative` is already the project-relative path
and `results.tests[]` carries `title` (an array of suite segments, leaf last),
`state`, and `attempts[]`. We write exactly the three fields Phase C consumes,
so nothing downstream changes. No parsing at all.

**3. The Module API** (`cypress.run()` from a Node script). Richest data, but
it replaces the `nx run <proj>:e2e` invocation with our own runner — a much
larger blast radius against the Nx executor.

### The timing tradeoff

Reporter output materializes when a spec or run *completes*. This is the real
cost of moving off log scraping, and it splits into three cases:

- **Hard kill** — the 20-minute `timeout` in `isolate-e2e-failure.sh`, an OOM,
  a container stop — produces no report at all. Scraped text at least survives
  partially. This is the strongest argument for **keeping the log parser as a
  fallback rather than deleting it.**
- **`after:run` is most exposed**, firing once at the very end. `after:spec`
  fires per spec, so a run killed midway still leaves results for everything
  that finished. That alone makes `after:spec` the safer hook.
- **Compile failures** — the webpack error in `testdata/e2e-fail-ambiguous.txt`
  — produce no test results, because Mocha never runs. But `after:spec` still
  fires with `results.error` populated, which is *strictly better* than today:
  an explicit "this is a build break, not a flake" signal instead of the parser
  coincidentally giving up.

### Direction agreed

Use `after:spec` to write one JSON file per spec, and keep
`parse-e2e-failure.sh` as the fallback when no JSON exists. Phase C onward is
untouched because the contract stays `E2E_PROJECT` / `E2E_SPEC` / `E2E_TITLE`.
This deletes the entire class of bug fixed in PR #1 — awk dialects, grep
dialects, ANSI stripping, reporter format drift.

Not yet a commitment: no spike has been run against the real monorepo.

### Implementation hazards

- **Parallelism.** `NX_PARALLEL_E2E=2` means concurrent writes, so it must be
  one file per spec plus a collector — and the collector needs a deterministic
  tiebreak, because "first failure in log order" stops being meaningful once
  specs finish out of order. The current first-failure-wins semantics need an
  explicit replacement rule.
- **Per-project config.** `setupNodeEvents` lives in each
  `apps/<proj>-e2e/cypress.config.ts`, so this is an edit per e2e project
  unless there is a shared Nx preset to hook instead.
- **Artifact location.** The results directory has to land in the Jenkins
  workspace root to be archived alongside the existing artifacts, and will need
  adding to the exclusion lists in `tree_is_clean` / `restore_tree`.
- **Fallback selection.** Needs a clear rule for when to trust JSON over the
  parser, and the two must not be able to disagree silently.

### Opportunity spotted

`results.tests[].attempts[]` tells us when a test failed and then passed on
retry. If retries are enabled on PR runs, **Cypress is already telling us a
test is flaky** — which is exactly what Phase C's isolation re-run exists to
discover. We may be able to skip that entire stage for tests that
self-identify, which would remove the most expensive step in the chain.

### Open questions

- Which `awk` is in the real CI Docker image? Determines whether the `mawk` bug
  was actually firing in production or was latent.
- Are Cypress retries enabled on PR runs? Gates the opportunity above.
- Does the spec path survive into JUnit XML with our reporter version?
- Is there a shared Nx e2e preset, or is `cypress.config.ts` duplicated per
  project?

---

## Phase C — E2E isolation re-run

**Status:** Not yet reviewed
**Code:** `isolate-e2e-failure.sh`

**Today:** Given `e2e-failure.env`, re-runs that single test via
`nx run <project>:e2e` with `--spec`, an escaped `--env.grep` on the title, and
`--env.grepTags=-@flaky`. Always writes a verdict file — `pass`, `fail`,
`no_match`, `error`, `skipped`, or `dry-run` — so downstream always has
something to read. Guards on the spec file existing, on `Tests: N` being at
least 1 so a grep that matched nothing is not read as a pass, and on timeout
exit codes 124 and 143. Kill switch `SKIP_E2E_ISOLATION`.

**Issues:** _to be filled during review._

**Open questions to seed the review:**

- `ATTEMPTS=1` is hardcoded. A single green re-run is thin evidence of flake;
  is N-of-M worth the runtime?
- Title matching goes through a regex-escaped `--env.grep`, which is a
  substring match — two tests whose titles share a prefix could both run. The
  `Tests: N` check confirms *something* ran, not that the *right* thing ran.
- Unlike `tag-e2e-flaky.sh`, this script does not honor an `AUTOFIX_ROOT`
  override, which is why six tests in `validate-gates.sh` cannot pass outside
  the monorepo.
- A test that is genuinely order-dependent passes in isolation and gets
  quarantined as flaky. Is that acceptable?

---

## Phase D — Quarantine patch

**Status:** Not yet reviewed
**Code:** `tag-e2e-flaky.sh`, `tag-e2e-flaky.mjs`,
`lib.sh` (`gate_e2e_quarantine_patch`)

**Today:** On a `pass` verdict, a hand-written scanner locates the matching leaf
`it()` — skipping strings, template literals and comments rather than
regex-matching blind — and adds `tags: ['@flaky']`, handling an existing `tags`
array and rewriting `it.only` back to `it`. It aborts on template-literal
titles, duplicate title matches, or an existing `@flaky`. The resulting
single-file diff must clear `gate_e2e_quarantine_patch`: exactly one
`*.cy.ts`/`*.cy.js` path, signature-only hunks, must introduce `@flaky`, must
not leave `it.only`. The working tree is restored either way. Kill switch
`SKIP_E2E_QUARANTINE`.

This is the best-tested part of the system — all the tagger shape fixtures
under `testdata/quarantine/` pass.

**Issues:** _to be filled during review._

**Open questions to seed the review:**

- Nothing ever *removes* `@flaky`. Quarantine is one-way, so coverage decays
  silently. Is there a companion process to un-quarantine?
- Template-literal titles abort. How common are they in the real specs?
- The tagger is bespoke parsing logic. Would a real TS AST (ts-morph,
  jscodeshift) be more robust, or is that overkill for a signature edit?

---

## Phase E — Publish

**Status:** Not yet reviewed
**Code:** `publish.sh`, `comment-bitbucket-pr.sh`, `open-bitbucket-pr.sh`,
`push-e2e-quarantine.sh`

**Today:** The only code that sees `BITBUCKET_AUTOFIX_TOKEN`. Format/Lint in
`plan` mode comments the verified diff; in `apply` mode it opens a PR into
`CHANGE_BRANCH`, never main or master. E2E quarantine in `plan` mode comments;
in `apply` mode it commits onto the `CHANGE_BRANCH` tip with a
`Cursor-Autofix: e2e-flake` trailer — no force push, no sibling PR, staging
only the gated paths. Nothing ever auto-merges.

**Issues:** _to be filled during review._

**Open questions to seed the review:**

- `apply` mode pushes directly to the contributor's feature branch. Is that
  still the right default, or should everything land as a comment?
- Bitbucket workspace and slug are hardcoded defaults in every script.
- `comment-bitbucket-pr.sh` inlines the whole patch into a comment body with no
  size cap.
- The JSON body is built with `python3` or `jq`, whichever exists — two code
  paths for one job.

---

## Cross-cutting: the credential boundary

**Status:** Not yet reviewed

The central design idea, and the part most worth protecting in any rewrite:
Phase 1 produces a verified patch with no credentials in the environment; Phase
2 is the only thing holding a token, bound by Jenkins in a separate step. Worth
reviewing whether the boundary is still airtight given Phase E now runs
`push-e2e-quarantine.sh` on the Jenkins agent rather than inside the container.

## Cross-cutting: the mechanical gates

**Status:** Not yet reviewed

`gate_patch`, `gate_e2e_quarantine_patch`, `verify_cmd`, the `DENY_GLOBS` list,
and the loop guards. The principle — enforce in code, not in prose to a model —
should survive. Review targets: whether `DENY_GLOBS` is still complete, and
whether `is_bot_change` treating an unknown ref as bot is too aggressive now
that E2E quarantine pushes land on the feature branch.

## Cross-cutting: the local test harness

**Status:** Not yet reviewed
**Code:** `validate-gates.sh`

82 checks with no network access. 72 passing on `main`; 76 passing with PR #1
applied, the remaining 6 being the Phase C isolation dry-run group, which
cannot pass outside the monorepo because `isolate-e2e-failure.sh` has no
`AUTOFIX_ROOT` override. Worth
deciding whether the suite should be green standalone — a suite with permanent
expected failures trains people to ignore it.

## Parked: the Tier 1 Cursor agent

**Status:** Not yet reviewed
**Code:** `agent-fix.sh`, `PROMPT.md`, `cursor-cli-config.json`

In the tree but unused; `validate-gates.sh` actively asserts that `run.sh` does
not reference it. Decide explicitly: revive, or delete. Dead code that the test
suite pins in place is the worst of both.

---

## Known loose ends

Small, already-identified, not yet scheduled:

- `testdata/e2e-failure.env.sample` still carries the pre-de-branding path
  `src/e2e/alarm-central/local/alarms.cy.ts`; the branding pass missed it. It
  is self-consistent with the dry-run assertions today, so changing it means
  updating both.
- The `ENABLE_AI_AUTOFIX` parameter description in the `Jenkinsfile` says "On
  format/lint/unit/build failure", but `ELIGIBLE_STAGES` and the `Jenkinsfile`'s
  own eligibility list are both limited to Check Format and Lint. Stale
  relative to the Phase A scope decision.
- The `Jenkinsfile` loads `ci/pipeline-helpers.groovy`, but in this repo the
  file sits at the root. Confirm the real location in the monorepo.

## Decision log

| Date       | Phase | Decision                                                                 |
| ---------- | ----- | ------------------------------------------------------------------------ |
| 2026-09-28 | B     | Fix POSIX portability + fixture drift as an immediate patch (PR #1).      |
| 2026-09-28 | B     | Direction: `after:spec` structured JSON, log parser retained as fallback. Not yet committed — needs a spike against the real monorepo. |
| 2026-09-28 | 0     | Finding: the Format/Lint capture is never read — `run.sh` only tests that the file exists. Direction: drop the capture where unconsumed, delete the gate, relocate the E2E capture outside the repo root. Coupled to the parked-agent decision. |
| 2026-09-28 | A     | Action list A1–A11 agreed. First slice: A1, A2, A3, A9. A4 (partial fixes) is the largest usefulness win. A6/A7 (direct push vs sibling PR, and the loop-guard trailer) move together or not at all. |
