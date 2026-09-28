# CI auto-fix — redesign working document

Living document for reviewing the existing implementation phase by phase and
planning the next one. We work in this repo; `README.md` describes the system
**as built**, this file describes what we intend to change and why.

## Scope

**2026-09-28 — pivot: E2E only.** Autofix for Check Format and Lint is being
dropped. The remaining system does one thing: when an E2E test fails, decide
whether it is flaky and, if so, quarantine it.

This is a larger change than it sounds, because Format/Lint was roughly half
the codebase and *all* of the safety story. See "What the pivot changes" below
before planning any work.

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

## Phase map (post-pivot)

The system is a chain. Each link is gated on the previous one producing an
artifact, so any link that fails quietly disables everything downstream.

| Phase | Name                | Trigger                         | Produces                                |
| ----- | ------------------- | ------------------------------- | --------------------------------------- |
| 0     | Capture             | E2E Tests stage                 | `ci-output.txt`, `FAILED_STAGE`         |
| ~~A~~ | ~~Format/Lint fix~~ | —                               | **retired by the pivot**                |
| B     | E2E identity        | E2E Tests failure               | `e2e-failure.env`                       |
| C     | E2E isolation       | `e2e-failure.env` exists        | `e2e-isolation.env`                     |
| D     | Quarantine patch    | isolation verdict is `pass`     | `e2e-quarantine.patch` + `.env`         |
| E     | Publish             | artifacts + feature flag on     | PR comment, or commit on feature branch |

Letters B–E are kept rather than renumbered, so the document, `README.md` and
the commit history stay legible against each other.

---

## What the pivot changes

### The safety story has to be rebuilt

This is the most important consequence and it is easy to miss. Format/Lint was
the only part of the system that could **prove** its output correct: apply the
patch to a pristine tree, re-run the real stage check, and accept only a
genuine green. `verify_cmd` was that proof.

Quarantine can never do this. A test passing in isolation is *evidence* that it
is flaky, not proof — the same observation is equally consistent with an
order-dependent test, a resource-contention failure, or a genuine bug that
happens not to reproduce alone. Once Format/Lint is gone, **every output of
this system is a judgement call.**

So the quality bar moves. It is no longer "was it verified" but "is the
evidence strong enough, and does the human reading the PR understand exactly
what we did and did not establish." Three questions that were peripheral
become central:

- `ATTEMPTS=1` in Phase C. One green re-run is thin evidence, and it is now
  the *only* evidence behind the only thing the system does.
- Nothing ever removes `@flaky`. When quarantine was one feature among
  several, one-way decay was a wart; now it is the system's main long-term
  risk.
- A genuinely order-dependent test passes in isolation and gets quarantined as
  flaky. That misclassification is now the primary correctness risk.

### Removal inventory

Deleted outright:

| File                     | Why                                         |
| ------------------------ | ------------------------------------------- |
| `run.sh`                 | Format/Lint phase 1                         |
| `publish.sh`             | Format/Lint phase 2 router                  |
| `open-bitbucket-pr.sh`   | Format/Lint apply (sibling PR)              |
| `agent-fix.sh`           | Tier 1 agent — no host phase remains        |
| `PROMPT.md`              | same                                        |
| `cursor-cli-config.json` | same                                        |

Kept: `parse-e2e-failure.sh`, `isolate-e2e-failure.sh`, `tag-e2e-flaky.sh`,
`tag-e2e-flaky.mjs`, `push-e2e-quarantine.sh`, and `comment-bitbucket-pr.sh` —
the last one is shared, since Phase E `plan` mode calls it directly from the
`Jenkinsfile` rather than through `publish.sh`. Its Format/Lint branch can be
collapsed to the e2e-flake wording.

`lib.sh` loses more than half its body. Confirmed by usage search: outside
`validate-gates.sh`, every one of the following is referenced only by `run.sh`
or `open-bitbucket-pr.sh`.

- `ELIGIBLE_STAGES`, `is_eligible_stage`
- `verify_cmd`, `deterministic_fix`, `has_deterministic_fix`
- `DENY_GLOBS`, `is_denied_path`, `gate_patch`
- `tree_is_clean`, `restore_tree`
- `autofix_branch_prefix`, `is_bot_change`

Survivors: `log` / `die`, `patch_paths` (used internally by the quarantine
gate), `gate_e2e_quarantine_patch`, `is_e2e_flake_head`.

Worth noting that `DENY_GLOBS` does not merely become unused — it becomes
*inverted*. It exists to stop a Format/Lint fix touching `*.cy.ts` and
`*/e2e/*`. The only patch the system still produces is a deliberate `.cy.ts`
edit, policed by `gate_e2e_quarantine_patch` instead.

### The loop guard simplifies itself

Action A7 from the old Phase A review resolves for free. With one publish path
there is only one trailer: `Cursor-Autofix: e2e-flake` and
`is_e2e_flake_head`. The `Cursor-Autofix: true` trailer, `is_bot_change`, and
the `cursor/ci-autofix-*` branch convention all disappear along with the
sibling-PR model that needed them.

### The Jenkinsfile shrinks

The whole Format/Lint tail of `post { failure { ... } }` goes: the eligibility
list, the `DOCKER_IMAGE` guard for that path, `AI_AUTOFIX_ARTIFACT_DIR` and its
cleanup, and both credentialed `docker.image(...).inside` blocks. `runCaptured`
is left instrumenting one stage, which folds into the Phase 0 work below.

### The credential scope narrows

`BITBUCKET_AUTOFIX_TOKEN` no longer needs create-PR. Comment plus branch push
is sufficient, which is a real least-privilege improvement worth taking while
we are here.

### Naming is now actively misleading

There is no AI anywhere on the live path and, post-pivot, no "autofix" either —
the system quarantines flaky tests. `ENABLE_AI_AUTOFIX`, `AI_AUTOFIX_MODE`, the
`ci/ai-autofix/` directory and the `Cursor-Autofix` trailer all describe
something the system no longer is. Renaming is cheap for the parameters,
moderate for the directory (touches the `Jenkinsfile` and every `source` path),
and not worth it for the trailer, which already exists in commit history.

### Carried over from the retired Phase A action list

Three items were not really about Format/Lint and still apply:

- **A9 — always leave a trace.** A no-op today is an `echo` into the Jenkins
  console that nobody reads. Now scoped to Phase E.
- **A10 — capture cleanup.** See Phase 0.
- **A11 — happy-path test.** Now means an end-to-end
  parse → isolate → tag → gate fixture run.

The rest (A1, A2, A4, A5, A6, A8) retire with Format/Lint. A3 — build patches
from tracked changes only — is already satisfied on this path, since Phase D
uses `git diff -- "$SPEC_PATH"` rather than `git add -A`.

---

## Phase 0 — Capture

**Status:** In review — Format/Lint scope closed by the pivot, E2E capture open
**Code:** `pipeline-helpers.groovy` (`runCaptured`), `Jenkinsfile` stage blocks

**Today:** Each instrumented stage runs inside the CI Docker image with stdout
and stderr tee'd to a temp file, then truncated into `ci-output.txt` with
`tail -c <captureBytes>` — 200 KiB for most stages, 2 MiB for E2E. The real
exit status is preserved through `PIPESTATUS[0]`, and the `catch` block records
`FAILED_STAGE` before rethrowing.

The capture is a **tail**, which is the correct choice for a Cypress log, since
the end-of-run summary is exactly what the parser needs. Any redesign that
starts reading from the top of the log inherits a truncation hazard that does
not exist today.

### Findings

**The capture was only ever consumed by one stage.** `runCaptured` instruments
five — Check Format, Lint, Unit Tests, E2E Tests, Build — and only E2E's text
is read. On the Format/Lint path `run.sh:34` tested that `ci-output.txt`
*existed* and never opened it, so up to 200 KiB was produced purely to satisfy
a gate token. The pivot removes that consumer entirely, which makes the
cleanup unambiguous: **capture on E2E Tests only.**

**The location costs more than the bytes.** Because the file is written to the
repo root, exclusions exist in `_E2E_ARTIFACT_RE`, in `restore_tree`, in two
`grep -vE` filters in `run.sh`, and in a `:(exclude)` pathspec. Deleting
`run.sh` removes three of those; moving the capture outside the working tree
removes the rest.

**Two footguns in `runCaptured`:**

- The shell script is assembled by Groovy string concatenation
  (`''' + command + '''`). A command containing a quote would behave
  surprisingly; one containing `'''` would break the build. Latent, not active.
- `tail -c` cuts on a byte boundary, so it can split a line and mangle UTF-8 at
  the head of the file. Harmless for the E2E parser only because that parser
  reads from the end — luck, not design. `tail -n` would be line-safe.

Not a defect: `set -uo pipefail` without `-e` is deliberate and correct, since
the real status is recovered from `PIPESTATUS[0]`.

### Actions

- **P0-1.** Instrument only the E2E Tests stage; plain `sh` elsewhere.
- **P0-2.** Write the capture outside the working tree and delete the
  exclusion lists that exist only to tolerate it in the repo root.
- **P0-3.** Switch to a line-safe tail, or document why byte truncation is
  acceptable.
- **P0-4.** Reconsider whether `runCaptured` still earns being a helper once it
  wraps a single stage.

### Still open

- If Phase B moves to `after:spec` JSON, does the text capture stay as the
  fallback, or does it go too? These decisions are coupled.

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

Post-pivot this matters more, not less: Phase B is now the front door to the
only feature the system has.

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
  coincidentally giving up. Post-pivot this distinction is worth real money,
  since quarantining a compile break would be actively harmful.

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
- **Artifact location.** The results directory has to land somewhere Jenkins
  archives from — see Phase 0 action P0-2, which should decide the location for
  both.
- **Fallback selection.** Needs a clear rule for when to trust JSON over the
  parser, and the two must not be able to disagree silently.

### Opportunity spotted

`results.tests[].attempts[]` tells us when a test failed and then passed on
retry. If retries are enabled on PR runs, **Cypress is already telling us a
test is flaky** — which is exactly what Phase C's isolation re-run exists to
discover. We may be able to skip that entire stage for tests that
self-identify, which would remove the most expensive step in the chain.

Post-pivot this is more attractive still: it is also *better evidence* than a
single isolated re-run, because a retry that flips within the same run
controls for environment differences that isolation does not.

### Open questions

- Which `awk` is in the real CI Docker image? Determines whether the `mawk` bug
  was actually firing in production or was latent.
- Are Cypress retries enabled on PR runs? Gates the opportunity above.
- Does the spec path survive into JUnit XML with our reporter version?
- Is there a shared Nx e2e preset, or is `cypress.config.ts` duplicated per
  project?

---

## Phase C — E2E isolation re-run

**Status:** Not yet reviewed — now the highest-value phase to review
**Code:** `isolate-e2e-failure.sh`

**Today:** Given `e2e-failure.env`, re-runs that single test via
`nx run <project>:e2e` with `--spec`, an escaped `--env.grep` on the title, and
`--env.grepTags=-@flaky`. Always writes a verdict file — `pass`, `fail`,
`no_match`, `error`, `skipped`, or `dry-run` — so downstream always has
something to read. Guards on the spec file existing, on `Tests: N` being at
least 1 so a grep that matched nothing is not read as a pass, and on timeout
exit codes 124 and 143. Kill switch `SKIP_E2E_ISOLATION`.

**Why this is now the priority:** with Format/Lint gone, this stage *is* the
evidence. Everything the system claims rests on the strength of what happens
here.

**Open questions to seed the review:**

- `ATTEMPTS=1` is hardcoded. One green re-run is thin evidence for the only
  decision the system makes. What is the right N-of-M, and what runtime is it
  worth?
- Title matching goes through a regex-escaped `--env.grep`, which is a
  substring match — two tests whose titles share a prefix could both run. The
  `Tests: N` check confirms *something* ran, not that the *right* thing ran.
  This is now the primary correctness risk in the system.
- A genuinely order-dependent test passes in isolation and gets quarantined as
  flaky. Can we distinguish? Running the whole spec rather than one grep-ed
  test would be one signal.
- Unlike `tag-e2e-flaky.sh`, this script does not honor an `AUTOFIX_ROOT`
  override, which is why six tests in `validate-gates.sh` cannot pass outside
  the monorepo.
- Should the isolation verdict record *why* we believe a flake, in a form the
  PR comment can quote?

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

**Open questions to seed the review:**

- **Nothing ever removes `@flaky`.** Quarantine is one-way, so coverage decays
  silently. Post-pivot this is the system's main long-term risk: unchecked, the
  only thing it does is progressively disable the test suite. A companion
  un-quarantine process may be a requirement rather than a nice-to-have.
- Is there a cap? Quarantining the tenth test in a spec should probably
  escalate to a human rather than proceed.
- Template-literal titles abort. How common are they in the real specs?
- The tagger is bespoke parsing logic. Would a real TS AST (ts-morph,
  jscodeshift) be more robust, or is that overkill for a signature edit?

---

## Phase E — Publish

**Status:** Not yet reviewed
**Code:** `push-e2e-quarantine.sh`, `comment-bitbucket-pr.sh`

**Today (post-pivot):** `plan` mode comments the gated diff on the PR; `apply`
mode commits it onto the `CHANGE_BRANCH` tip with a `Cursor-Autofix: e2e-flake`
trailer — no force push, no sibling PR, staging only the gated paths, refusing
main and master. Nothing ever auto-merges.

**Open questions to seed the review:**

- The comment should now carry the *evidence*, not just the diff: what was
  re-run, how many times, and explicitly what that does and does not prove.
  This is the main mitigation for losing `verify_cmd`.
- **A9 — always leave a trace.** Today a no-op is an `echo` nobody reads. When
  the system does nothing, say so on the PR.
- Bitbucket workspace and slug are hardcoded defaults.
- `comment-bitbucket-pr.sh` inlines the whole patch with no size cap, and
  builds JSON with `python3` or `jq`, whichever exists — two code paths for one
  job, now worth collapsing since the file is being touched anyway.
- Narrow the token to comment + push, dropping create-PR.

---

## Cross-cutting: the credential boundary

**Status:** Not yet reviewed

The original design kept patch production credential-free and confined the
token to a separate publish step. Post-pivot, review whether the boundary still
holds: Phase E runs `push-e2e-quarantine.sh` directly on the Jenkins agent
rather than inside the container, and Phases B–D no longer sit behind the
`run.sh` entry point that made the separation obvious.

## Cross-cutting: the mechanical gates

**Status:** Not yet reviewed

The principle — enforce in code, not in prose to a model — should survive.
Post-pivot only `gate_e2e_quarantine_patch` remains, which makes it the single
mechanical check in the entire system. Worth re-reading with that weight in
mind: it is now load-bearing alone.

## Cross-cutting: the local test harness

**Status:** Not yet reviewed
**Code:** `validate-gates.sh`

82 checks today; 72 passing on `main`, 76 with PR #1 applied. The pivot deletes
roughly half of them — stage eligibility, the path gate, `gate_patch`, the
`run.sh` skip gates, the `open-bitbucket-pr.sh` guards, the `publish.sh` exec
boundary, and the `is_bot_change` cases. The parse, isolate and quarantine
sections all survive.

Two things to decide while it is being cut down:

- The six permanently-failing isolation dry-run checks, which cannot pass
  outside the monorepo because `isolate-e2e-failure.sh` has no `AUTOFIX_ROOT`
  override. A suite with expected failures trains people to ignore it.
- **A11** — there is still no end-to-end fixture run of
  parse → isolate → tag → gate.

---

## Known loose ends

- `testdata/e2e-failure.env.sample` still carries the pre-de-branding path
  `src/e2e/alarm-central/local/alarms.cy.ts`; the branding pass missed it. It
  is self-consistent with the dry-run assertions today, so changing it means
  updating both.
- The `ENABLE_AI_AUTOFIX` parameter description in the `Jenkinsfile` says "On
  format/lint/unit/build failure" — wrong before the pivot, and now wrong in a
  second way. Fold into the renaming discussion above.
- The `Jenkinsfile` loads `ci/pipeline-helpers.groovy`, but in this repo the
  file sits at the root. Confirm the real location in the monorepo.
- `README.md` documents Phases A–E as built and will need rewriting once the
  pivot lands.

## Decision log

| Date       | Phase | Decision                                                                 |
| ---------- | ----- | ------------------------------------------------------------------------ |
| 2026-09-28 | B     | Fix POSIX portability + fixture drift as an immediate patch (PR #1).      |
| 2026-09-28 | B     | Direction: `after:spec` structured JSON, log parser retained as fallback. Not yet committed — needs a spike against the real monorepo. |
| 2026-09-28 | 0     | Finding: the Format/Lint capture is never read — `run.sh` only tests that the file exists. Direction: drop the capture where unconsumed, delete the gate, relocate the E2E capture outside the repo root. |
| 2026-09-28 | A     | Action list A1–A11 recorded, then superseded by the pivot. A9, A10, A11 carried over; the rest retired. |
| 2026-09-28 | all   | **Pivot: drop Format/Lint autofix, E2E only.** Retires Phase A, deletes six files, halves `lib.sh` and the test suite, and removes the system's only mechanism for proving its own output correct. Review priority moves to Phase C. |
