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

Three rules, the first two from the Phase B review and the third from the
C/D/E pass:

1. **Prefer a loud failure to a clever one.** Most of what we found in Phase B
   was not "wrong output" but "no output, logged as ambiguity." Silent
   degradation is the dominant failure mode in this codebase.
2. **Record what we could not verify.** This repo is an extract — there is no
   `apps/` tree, no `ci/Dockerfile`, no `ci/nx-e2e-affected.sh`. Anything that
   depends on the real monorepo gets written down as an open question rather
   than assumed.
3. **Quote at every boundary, and gate the quoting.** Test titles are written by
   PR authors, scraped out of a log, and eventually sourced into a shell that
   holds the Bitbucket token. That chain is safe today only because every
   producer writes `printf %q`, and nothing enforces it. Same principle as the
   path gate: if it matters, it is a check, not a convention.

**Scope of the 2026-09-30 pass.** Phases C, D, E and the three cross-cutting
concerns, reviewed against the post-pivot system only — findings that die with
Format/Lint are noted as such and not pursued, so nobody spends effort fixing
code that is about to be deleted. Method was reading the code and exercising
`lib.sh`, the gates and the fixtures locally on a `mawk 1.3.4` box. Nothing was
run against the real monorepo or a real Jenkins agent, so every finding is
either demonstrated locally (and says so) or marked as needing confirmation.
With this pass every phase has been through review at least once.

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

**Status:** In review — capture location still coupled to the Phase B decision
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
  fallback, or does it go too? These decisions are coupled. The 2026-09-30 pass
  narrows it rather than settling it: the hard-kill case in Phase B's timing
  analysis is a real E2E failure mode, and Phase C's own `timeout` is one of its
  causes, so something has to survive a killed run. Keeping the tail as the
  fallback is the cheap answer; the alternative is accepting that a timed-out
  E2E run produces no verdict at all, which may be perfectly acceptable since a
  20-minute hang is not a flake.
- P0-2 and Phase B's results directory want the same decision about where
  artifacts live. One consideration for it: the parser runs on the agent while
  Cypress writes inside the container, so the location has to be reachable and
  writable from both, which the workspace currently is and a path outside the
  repo may not be.

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

- ~~Which `awk` is on the **Jenkins agent**?~~ Closed 2026-10-06: the parser
  now runs inside the CI image, so the agent's awk no longer matters. See the
  harness section.
- Are Cypress retries enabled on PR runs? Gates the opportunity above.
- Does the spec path survive into JUnit XML with our reporter version?
- Is there a shared Nx e2e preset, or is `cypress.config.ts` duplicated per
  project?

---

## Phase C — E2E isolation re-run

**Status:** Reviewed — actions recorded, N-of-M still open
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

### Findings

**The re-run is not the same run.** This is the finding that matters most, and
it is not about `ATTEMPTS`. The failing stage executes
`./ci/nx-e2e-affected.sh "${CHANGE_TARGET}" "-@flaky"`; isolation executes
`npx nx run <project>:e2e --browser=chromium --spec=... --env.grep=...`
directly. Two differences fall out of that, and both bias the verdict toward
`pass`:

- **Browser.** `--browser=chromium` is hardcoded here. What the real suite uses
  is invisible from this extract (`ci/nx-e2e-affected.sh` is not in the repo).
  If they differ, a `pass` verdict means "the test passes in a different
  browser," which is not evidence of flakiness at all.
- **Everything that wrapper does.** Any base URL, serve target, fixture seeding,
  retry setting or parallelism configured inside `nx-e2e-affected.sh` is skipped.
  `NX_PARALLEL_E2E=2` is set at pipeline level and not reproduced here, which is
  arguably correct for isolation, but it is an accident rather than a decision.

A test that fails under contention and passes alone is exactly what we want to
detect; a test that fails in Electron and passes in Chromium is a false
quarantine. Today we cannot tell those apart, and the verdict file does not
record enough to let a human tell either. **Confirm the real browser and
wrapper behaviour before enabling `apply`.**

**`--env.grep` is a substring match, but the tagger is exact — so the risk is
inflated evidence, not a mis-tag.** Two tests whose titles share a prefix can
both run, and `Tests: N >= 1` cannot tell the difference. The blast radius is
smaller than it first looks, because `tag-e2e-flaky.mjs` matches the title
exactly and aborts on duplicates, so Phase D will not tag the wrong test. What
we get instead is a `pass` verdict earned partly by a *different* test's green.
Recording the matched count in the verdict would close this: `Tests: 1` is the
only count that supports the claim we are making.

**`escape_grep` handles regex metacharacters but not `@cypress/grep`'s own
syntax.** It escapes `][(){}.^$*+?|\` for the JS `RegExp`, which is right as
far as it goes. Two title shapes bypass it, both needing a check against the
pinned version: a title containing `;`, which that plugin treats as a separator
between alternative title filters, and a title *starting* with `-`, which it
reads as an inverted filter. Either turns the grep into something other than
"run this one test," and the `Tests: N` guard would not necessarily notice.

**The verdict depends on log scraping, which Phase B is moving away from.**
`tests_ran_ge_1` greps `Tests:[[:space:]]+[0-9]+` out of the isolation log —
the same class of fragility as the parser, in the script that produces the
evidence. When `after:spec` JSON lands it should be consumed *here too*, which
turns "did something run" into "this exact test ran, and here is its state and
its `attempts[]`." That is a strictly better verdict from the same work.

**Layout is hardcoded in three places.** `SPEC_PATH="apps/${E2E_PROJECT}/..."`
here, the same expression in `tag-e2e-flaky.sh`, and `/apps/` inside
`normalize_spec`. Any e2e project outside `apps/` silently produces an `error`
verdict. Cheap to centralise while both scripts are being touched.

**`ATTEMPTS=1` is hardcoded but emitted as `ISOLATION_ATTEMPTS`**, which reads
like a configurable knob in the artifact and is not one. Either wire it up or
stop advertising it.

**The `timeout` guard is shallower than it looks.** `timeout 20m` wraps `npx`,
so on expiry the signal goes to the Node wrapper; Cypress and browser children
can outlive it. Verdict is correctly `error` (124/143 are both handled), but
orphaned processes on a long-lived agent are a plausible source of later,
unrelated E2E flakiness — which this system would then diagnose as flakiness.

**The dry-run ordering is why six checks cannot pass.** The spec-existence
guard runs *before* the `ISOLATE_E2E_DRY_RUN` branch, so outside the monorepo
the script errors out before it can print argv. Adding the `AUTOFIX_ROOT`
override that `tag-e2e-flaky.sh` already has is what makes the group pass;
locally reproduced — all six failures are this one group, and they all report
`result=error`.

Worth keeping: the always-write-a-verdict discipline, the `unset` of ambient
`E2E_*` before sourcing (fail-closed on env leakage), and `%q` on every value.

**Found while implementing C-4 (2026-10-06): `Tests: N >= 1` never meant "the
grep matched".** Unless `grepOmitFiltered` is set, `@cypress/grep` marks every
filtered-out test as Pending, and the Cypress results table's `Tests:` counts
Pending. A grep that matched nothing, in a spec with any other tests, therefore
produced `Tests: N>0`, exit 0 and a `pass` verdict — reproduced against the
previous script with a canned results table. Whether it bit in production
depends on the plugin config (S4). The fix counts executed tests
(Passing + Failing), which is correct under either setting.

### Actions

Status 2026-10-06: C-1, C-3, C-4 and C-6 done. C-2 waits on S3, C-5 on S4,
C-7 on Stage 5.

- **C-1.** Add an `AUTOFIX_ROOT` override and move the dry-run branch above the
  spec-existence guard. Makes `validate-gates.sh` green standalone.
- **C-2.** Confirm the real browser and inherit it rather than hardcoding
  `chromium`; record the browser in the verdict.
- **C-3.** Record *evidence* in the verdict, not just an outcome: matched test
  count, browser, attempts, duration, and the exact argv. Phase E needs this to
  write an honest comment.
- **C-4.** Reject a verdict of `pass` when more than one test matched.
- **C-5.** Check `;` and leading-`-` title handling against the pinned
  `@cypress/grep`, and extend `escape_grep` or reject such titles outright.
- **C-6.** Centralise the `apps/<project>/<spec>` layout assumption.
- **C-7.** Consume Phase B's `after:spec` JSON here once it exists, replacing
  `tests_ran_ge_1`.

### Still open

- **N-of-M.** Unresolved, and it is the central judgement call of the redesign.
  Two sub-questions worth separating: how many re-runs make a `pass` credible,
  and whether re-running the *whole spec* once is better evidence than
  re-running one grep-ed test N times. The second also partly addresses
  order-dependence, since a spec-level re-run preserves within-spec ordering.
  If Phase B's retry `attempts[]` signal is available, it may outrank both.
- Whether `SKIP_E2E_ISOLATION` should also suppress Phase D, rather than
  relying on the `skipped` verdict failing the `pass` check downstream. It
  works today; it is implicit.

---

## Phase D — Quarantine patch

**Status:** Reviewed — one blocking finding, un-quarantine mechanism open
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

### Findings

**Blocking: `@flaky` currently means "never runs again," not "runs in the
tolerant stage."** The design intent is that quarantined tests keep running in
`E2E Tests - Flaky`, where a failure logs and continues. In practice that stage
cannot run at all:

```
when { not { expression { return params.SKIP_E2E_FLAKY_TESTS ?: true } } }
```

`SKIP_E2E_FLAKY_TESTS` defaults to `true`, so the stage is off by default — and
because Groovy's `?:` returns its right operand for *any* falsy left operand,
setting the parameter to `false` yields `false ?: true` → `true`. The stage is
skipped whichever way the box is ticked. Unticking it is not an escape hatch;
it is a no-op. (`Jenkinsfile:167`. The same idiom appears at `:95`, `:148`,
`:221`, `:246` and `:277`, and is harmless at all of them because their
fallback is `false` — which is what a falsy parameter should yield anyway. Only
a `?: true` fallback can swallow a deliberate `false`. The null-safe form is
`params.X == null ? true : params.X`.)

So today quarantining a test deletes it from CI with no residual signal
anywhere. Every concern the pivot raises about one-way decay is not a future
risk but the current state, and the cause is one line of Groovy. **This should
be fixed before `apply` mode is enabled for anyone**, because the difference
between "we moved this test to a tolerant stage" and "we switched this test off"
is the difference between a defensible feature and an indefensible one.

**The gate does not bound how much it can quarantine.** Verified locally: a
single-file patch with three separate `it()` signature hunks, each adding
`@flaky`, passes `gate_e2e_quarantine_patch` cleanly. The tagger only ever tags
one test, so this is not reachable today — but post-pivot this gate is the only
mechanical check in the system, and it should constrain the output rather than
rely on the producer's good behaviour. Same for the title: the gate checks the
*path* against the verdict, never the title, so a patch tagging the wrong test
in the right file would pass. The tagger's exact-match-and-abort is what
actually prevents that.

**There is no cumulative budget.** Each build can quarantine one test; nothing
counts how many are already tagged in the spec, the project, or the PR. A
chronically unstable suite converges on fully disabled, one green build at a
time, and no single decision in that sequence ever looks wrong.

**The restore is silent on failure.** `git checkout -- "$SPEC_PATH"` is
`|| true` in both the error and success paths. If it ever fails the modified
spec stays in the workspace, and the symptom surfaces later and elsewhere as
Phase E's `patch no longer applies on origin/<branch>` — a confusing error that
points at the wrong script.

**The layout assumption repeats here** (`apps/${E2E_PROJECT}/${E2E_SPEC}`); see
action C-6.

**The tagger itself holds up well.** The string/template/comment skipping is
careful, the abort conditions are conservative in the right direction, and the
gate correctly rejects the dangerous shapes — a patch that deletes a test body
is refused because the body lines match the non-signature denylist. The
allowlist ("every changed line must be an `it()` signature, `tags:`, or
`@flaky`") is what makes it safe, and it is the part to preserve verbatim in any
rewrite.

### Options for the un-quarantine problem

Ordered by how much machinery they need, all compatible with each other:

1. **Expiry in the tag.** `tags: ['@flaky']` becomes `['@flaky-2026-10']` or a
   companion comment with a date, plus a scheduled job that reports (or
   un-tags) anything past its date. Cheap, but adds a second tag vocabulary the
   grep filters must understand.
2. **Report, don't decide.** A scheduled build that runs the `@flaky` set N
   times and opens a ticket listing tests that have passed every time for a
   month. Humans remove the tag. No new gating logic, no risk of the system
   silently re-enabling a broken test.
3. **Budget with escalation.** Refuse to quarantine when the spec or project is
   already over a threshold; comment on the PR instead. Bounds the decay
   without needing anything to remove tags.

Option 2 is the honest counterpart to this system's own design principle: a
machine that quarantines should not also be the machine that judges when to
stop. Option 3 is the cheapest thing that prevents unbounded decay and does not
depend on anyone acting on a report.

### Decision

- Fix `Jenkinsfile:167` and make the flaky stage genuinely runnable. Recorded as
  blocking for `apply` mode.
- Keep the bespoke tagger. A TS AST would be more robust in principle, but it
  needs a dependency available inside the CI image at post-failure time, and the
  gate already refuses everything the scanner could plausibly get wrong. Not
  worth the trade for a signature edit.
- Tighten the gate to one tagged test per patch, and check the title.
- Un-quarantine mechanism: **open**, but not optional. Recommendation is option
  3 now (bounded decay, no new vocabulary) and option 2 next.

### Still open

- How common are template-literal titles in the real specs? Determines whether
  the abort path is a rare edge case or a routine dead end. Needs the monorepo.
- Should a quarantine carry attribution — who, which build, which verdict — into
  the spec file as a comment, so the next reader of the test knows why it is
  tagged? The commit trailer has this, but nobody reads a commit trailer while
  looking at a test.

---

## Phase E — Publish

**Status:** Reviewed — actions recorded, apply-mode default open
**Code:** `push-e2e-quarantine.sh`, `comment-bitbucket-pr.sh`

**Today (post-pivot):** `plan` mode comments the gated diff on the PR; `apply`
mode commits it onto the `CHANGE_BRANCH` tip with a `Cursor-Autofix: e2e-flake`
trailer — no force push, no sibling PR, staging only the gated paths, refusing
main and master. Nothing ever auto-merges.

### Findings

**The token is on the command line in both publish paths.** `curl -H
"Authorization: Bearer ${TOKEN}"` and `git push
"https://x-token-auth:${TOKEN}@bitbucket.org/..."` both put the secret in
process arguments, readable via `ps` by anything else on that agent for the
duration of the call. The git form is the worse of the two: a push failure can
echo the remote URL into the build log, and Jenkins credential masking is the
only thing standing between that and a leaked token in a publicly readable
build page. Both have direct fixes — `curl --config` or a header file, and
`git -c http.extraHeader=...` with a credential helper or a URL without inline
credentials.

**Apply mode pushes silently.** In `apply` mode the contributor gets a commit
on their branch and no PR comment explaining it. The commit message carries the
reasoning, which nobody sees unless they look. This is the same gap as carried
action **A9** and, post-pivot, it is worse than a missing trace: the system is
now making a judgement call rather than applying a verified fix, so *every*
apply needs a visible, quotable justification on the PR. Apply should comment
**and** push, with the evidence from action C-3.

**The loop guard checks the wrong ref.** `is_e2e_flake_head` inspects the build's
local `HEAD` before the script fetches, but what matters is whether the tip it is
about to push onto already carries a quarantine commit. On a PR build `HEAD` is
whatever Jenkins checked out, which is not `origin/<CHANGE_BRANCH>` after the
fetch. The real protection against a repeated push is the `git diff --cached
--quiet` check plus the gate's "must introduce `@flaky`" rule — both sound, so
the guard is redundant rather than dangerous, but it does not do what its name
says. Move the check after the fetch and run it against `TIP`.

**`git fetch origin` may not be authenticated in the post block.** Jenkins binds
SCM credentials for `checkout scm`; a bare `git fetch origin` later in
`post { failure { ... } }` relies on the remote URL still being usable. If it is
not, the script dies with `fetch origin/<branch> failed` and the whole phase
disappears with a log line. The script already holds a token — fetching from the
same tokenized URL it pushes to would remove the dependency. Needs confirmation
against the real agent.

**De-branding missed the publish defaults.** `BITBUCKET_WORKSPACE` defaults to
`workassureonline` and `BITBUCKET_REPO_SLUG` to `acme-ui` in both scripts. One of
those looks like a real workspace name rather than a placeholder. Whatever the
outcome, defaults that point at a specific real repository are the wrong shape:
require them, or fail loudly.

**Smaller items, all in `comment-bitbucket-pr.sh`:**

- No size cap on the inlined patch. A quarantine diff is small, so this is
  latent rather than active, but an oversized body means an HTTP 4xx, a
  `catchError` FAILURE mark on an already-failed build, and no comment.
- `python3`-or-`jq` duplication for one JSON object; the repo has both in
  practice and the `jq` form is the simpler one. Worth collapsing since the file
  is being touched for the wording change anyway.
- `/tmp/bb-comment-response.json` is a fixed path, world-readable on a shared
  agent, and never cleaned up — unlike every other temp file in these scripts,
  which go through `mktemp` with a trap.
- The Format/Lint branch of the comment body retires with the pivot, leaving the
  `e2e-flake` wording as the only case.

**One thing the pivot quietly improves:** with `publish.sh` and
`open-bitbucket-pr.sh` gone, no credentialed step runs inside the CI container
any more — both remaining publish paths are plain `sh` on the agent. The
boundary becomes "container produces artifacts, agent publishes them," which is
easier to state and to check than what exists today.

### Actions

- **E-1.** Get the token out of process arguments in both paths.
- **E-2.** Apply mode comments as well as pushes, quoting the C-3 evidence and
  stating plainly what isolation does and does not prove.
- **E-3.** Move the loop-guard check after the fetch, against the fetched tip.
- **E-4.** Fetch via the tokenized URL, or confirm `origin` is authenticated in
  the post block.
- **E-5.** Require `BITBUCKET_WORKSPACE` / `BITBUCKET_REPO_SLUG` instead of
  defaulting them to a real repository.
- **E-6.** Single JSON builder, `mktemp` for the response file, size cap on the
  comment body, drop the Format/Lint wording branch.
- **E-7.** Narrow the token to comment + push, dropping create-PR.
- **E-8.** (A9) Comment when the system deliberately does nothing — an ambiguous
  parse, a `fail` verdict, a refused quarantine — so silence always has a
  stated reason.

### Still open

- **Should `apply` remain the intended end state?** It was defensible when the
  patch was machine-verified. Now that every output is a judgement call, "always
  comment, never push" is a coherent position, and the cost is one click per
  flake. The counter-argument is that a comment nobody actions leaves the PR red
  and trains people to ignore E2E failures. Worth deciding explicitly rather
  than inheriting.
- Whether E-8's no-op comments would be noise at the volume the real suite
  produces. Needs a rough failure rate from the monorepo.

---

## Cross-cutting: the credential boundary

**Status:** Reviewed — holds, with one unenforced assumption

The boundary survives the pivot and gets simpler: Phases B–D run with no token
in the environment, Phase E is the only credentialed step, and post-pivot no
credentialed step runs inside the container at all. Confirmed in the
`Jenkinsfile`: the single `withCredentials` block for this path wraps only the
publish `sh` step.

The part that deserves attention is the direction of data flow rather than the
placement of the credential. A test title is written by a PR author, scraped out
of a log by Phase B, passed through Phase C and D, written into
`e2e-quarantine.env`, and then **`source`d by a shell that holds the Bitbucket
token** (`Jenkinsfile:300-303`). That is a PR-author-controlled string reaching a
credentialed bash context. It is safe today, and specifically it is safe because
every producer writes values with `printf %q` — `parse-e2e-failure.sh`,
`isolate-e2e-failure.sh` and `tag-e2e-flaky.sh` all do, without exception.

Nothing enforces that. It is a convention held in three scripts, and the failure
mode if someone drops it is not a broken build but a shell injection into the
one step that holds the token. By this repo's own stated principle that belongs
in a check, which is rule 3 at the top of this document.

Two ways to close it, both cheap:

- A `validate-gates.sh` check that every emitted `.env` round-trips: write a
  hostile title through the real producers (`$(id)`, backticks, `;`, newline,
  quote) and assert the sourced value comes back byte-identical.
- Stop shell-sourcing structured data. If Phase B moves to JSON, the consumers
  can read it with `jq` and the whole class of concern disappears. This is a
  second, independent argument for the `after:spec` direction.

**Decision:** boundary confirmed sound; add the round-trip check, and prefer
JSON-plus-`jq` over `source` wherever Phase B's rewrite makes it available.
Keep the rule that the container never sees the token.

## Cross-cutting: the mechanical gates

**Status:** Reviewed — decisions recorded

Post-pivot, `gate_e2e_quarantine_patch` is the only mechanical check in the
system. Read with that weight, it holds up better than expected:

- The structural checks are right: rename, copy, add and delete file modes are
  all rejected, exactly one path, and that path must equal the one the verdict
  named and must be `*.cy.ts` / `*.cy.js`.
- The line-level logic is a denylist (no `cy.`, `should(`, `expect(`, `import`,
  `describe(`, `beforeEach(`, `afterEach(`, `it.skip`) *and* an allowlist (every
  changed line must be an `it()` signature, a `tags:` line, or `@flaky`). The
  allowlist is what makes it safe; the denylist alone would be porous. Verified
  locally that a patch deleting a test body is rejected.
- `must introduce @flaky` and `must not leave it.only` close the two obvious
  abuses.

Two gaps, both about bounding the output rather than blocking a category:

- **No budget.** Three separate `it()` hunks in one file pass (verified
  locally). Nothing today produces that, but the gate should not depend on that.
- **The title is never checked.** Only the path is matched against the verdict,
  so tagging a different test in the right file would pass the gate. The
  tagger's exact-match-and-abort is the only thing preventing it.

Two retirements worth stating so nobody "fixes" them: `DENY_GLOBS` /
`gate_patch` have real holes — `package.json`, `project.json`, `.editorconfig`,
`.eslintignore`, `prettier.config.*`, `jest.config.*`, `Jenkinsfile.*`,
`bitbucket-pipelines.yml` and `ci-output.txt` are all accepted (verified
locally, and a patch adding `ci-output.txt` as a new file passes `gate_patch`
outright) — but every one of those is on the Format/Lint path and dies with it.
**Do not spend effort there.** Likewise `is_bot_change`: the unknown-ref →
treat-as-bot behaviour was correct, and it retires with the sibling-PR model.

**Decision:** keep the gate's shape verbatim; add a one-test-per-patch budget
and a title check; let the Format/Lint gate gaps retire with the code.

## Cross-cutting: the local test harness

**Status:** Reviewed — decisions recorded
**Code:** `validate-gates.sh`

82 checks today; 76 passing, 6 failing, reproduced locally on this box. All six
are the Phase C isolation dry-run group and all report `result=error` for the
reason in action C-1. The pivot deletes roughly half the suite — stage
eligibility, the path gate, `gate_patch`, the `run.sh` skip gates, the
`open-bitbucket-pr.sh` guards, the `publish.sh` exec boundary, and the
`is_bot_change` cases. The parse, isolate and quarantine sections all survive.

**Nothing runs this suite.** The `Jenkinsfile` never invokes it, so the only
mechanical check in the system is itself unchecked, and the six known failures
have no mechanism that would ever complain about a seventh. The script is
already CI-shaped — no network, exits non-zero on failure — so wiring it in is
a step, not a project.

**A useful accident worth recording:** the suite ran green (76/6) here under
`mawk 1.3.4`, which is the dialect that caused the PR #1 bug, so the fix is
confirmed against the awk that broke it rather than just against `gawk`.

That also sharpens Phase B's open question. `parse-e2e-failure.sh` is invoked by
a bare `sh` step in the post block, **not** inside
`docker.image(...).inside` — unlike `isolate-e2e-failure.sh` and
`tag-e2e-flaky.sh`, which are. So the `awk` and `grep` that decide whether
parsing works are the **Jenkins agent's**, not the CI image's. The question to
answer is which awk is on the `node_ui` agent; the image's awk is irrelevant to
the parser and relevant only to the isolation script. Worth deciding, too,
whether that split is deliberate — the parser needs no container, but running
it outside means its toolchain is whatever the agent happens to have.

**Decision:**

- Make the suite green standalone via action C-1, then wire it into CI.
- ~~Run it under both `mawk` and `gawk` where both are available.~~ Superseded
  2026-10-06: the CI image is the single awk runtime instead. The parser runs
  in the image, `patch_paths` is pure bash (the publish re-gate is the one
  `lib.sh` caller on the agent), and the harness runs once in the image and
  prints which awk it used. Testing other dialects would test toolchains the
  system never uses; a change to the image's awk is caught by the next build.
- **A11** — add the end-to-end fixture run (parse → isolate → tag → gate) that
  still does not exist. With `AUTOFIX_ROOT` and the dry-run reordering in place
  this becomes possible without Cypress, and it is the check that would have
  caught the PR #1 breakage as a chain failure rather than as one dead script.

---

## What to do first

Every phase has now been reviewed, so the useful output of this document is an
order. Grouped by what each group buys, not by phase. `PLAN.md` expands this
into stages, and marks where the next step is a spike, an experiment, or a
decision that has to wait for evidence.

**1. Stop the bleeding (one Groovy line and one script flag; no open
questions).** `Jenkinsfile:167` so `@flaky` means "tolerated" rather than
"deleted"; action C-1 so the harness can go green; then wire the harness into
CI. None of these depend on any open question, and the first one is a
correctness fix to behaviour that exists in production today.

**2. Make the evidence honest before anyone enables `apply`.** Actions C-2, C-3
and C-4, then E-2. This is the group that replaces what `verify_cmd` used to
provide: a human reading the PR can see what was re-run, in which browser, how
many tests matched, and what that does not prove. Until this exists, `apply`
mode is a machine making an unexplained judgement call on someone else's branch.

**3. Bound the decay.** The Phase D gate budget and title check, plus a decision
on the un-quarantine mechanism. Cheapest sufficient version is option 3
(refuse and escalate past a threshold).

**4. Close the credential-boundary assumption.** The `%q` round-trip check. Small,
and it converts the one remaining unenforced safety property into a gate.

**5. Then the structural work.** The Phase B `after:spec` spike, which is the
only item here that needs the real monorepo, and which subsumes several actions
above (C-7, most of the Phase 0 capture question, and the `source`-versus-`jq`
half of the credential boundary). Doing it before groups 1–4 would mean
shipping the structural change on top of a system whose quarantine tag still
silently deletes tests.

Deliberately not on this list: everything on the Format/Lint path. The
`DENY_GLOBS` holes, the `gate_patch` new-file hole, the `ci-output.txt` leak
path, the sibling-PR branch-collision behaviour — all real, all retiring with
the pivot. They are recorded in the sections above only so that nobody
rediscovers them and treats them as work.

## Known loose ends

- ~~`testdata/e2e-failure.env.sample` still carries a pre-de-branding path.~~
  Not true — checked on 2026-09-30. The sample reads
  `src/e2e/module-a/local/products.cy.ts`, de-branded in `9365aa6`, which
  predates this document; it matches the dry-run assertions. Nothing to do.
- The `ENABLE_AI_AUTOFIX` parameter description in the `Jenkinsfile` says "On
  format/lint/unit/build failure" — wrong before the pivot, and now wrong in a
  second way. Fold into the renaming discussion above.
- The `Jenkinsfile` loads `ci/pipeline-helpers.groovy`, but in this repo the
  file sits at the root. Confirm the real location in the monorepo.
- `README.md` documents Phases A–E as built and will need rewriting once the
  pivot lands.
- ~~`Jenkinsfile:167` — `params.SKIP_E2E_FLAKY_TESTS ?: true` makes the
  `E2E Tests - Flaky` stage unrunnable regardless of the parameter.~~ Fixed in
  Stage 0 with a null-safe check. The default is still `true`, so the flaky
  stage runs only when someone unticks the box. Decided 2026-10-06: the default
  stays `true`.
- ~~Nothing runs `validate-gates.sh` in CI.~~ Stage 0 adds the
  `Validate Quarantine Gates` stage, inside the CI image, blocking. Since
  2026-10-06 the parser runs in the image too, so the harness checks the awk the
  parser actually uses.
- The CI image's awk is not pinned explicitly. `ci/Dockerfile` is not in this
  extract; pin it there, or accept the base image's (`mawk` on Debian/Ubuntu,
  which the parser supports). The harness log line shows which one is live.

## Decision log

| Date       | Phase | Decision                                                                 |
| ---------- | ----- | ------------------------------------------------------------------------ |
| 2026-09-28 | B     | Fix POSIX portability + fixture drift as an immediate patch (PR #1).      |
| 2026-09-28 | B     | Direction: `after:spec` structured JSON, log parser retained as fallback. Not yet committed — needs a spike against the real monorepo. |
| 2026-09-28 | 0     | Finding: the Format/Lint capture is never read — `run.sh` only tests that the file exists. Direction: drop the capture where unconsumed, delete the gate, relocate the E2E capture outside the repo root. |
| 2026-09-28 | A     | Action list A1–A11 recorded, then superseded by the pivot. A9, A10, A11 carried over; the rest retired. |
| 2026-09-28 | all   | **Pivot: drop Format/Lint autofix, E2E only.** Retires Phase A, deletes six files, halves `lib.sh` and the test suite, and removes the system's only mechanism for proving its own output correct. Review priority moves to Phase C. |
| 2026-09-30 | D     | **Blocking finding: `@flaky` currently disables a test outright.** `Jenkinsfile:167` (`params.SKIP_E2E_FLAKY_TESTS ?: true`) makes the tolerant flaky stage unrunnable whichever way the parameter is set. Fix before `apply` mode is enabled for anyone. |
| 2026-09-30 | C     | Isolation does not reproduce the failing run: `--browser=chromium` is hardcoded and `ci/nx-e2e-affected.sh` is bypassed. Confirm the real browser before trusting a `pass` verdict. |
| 2026-09-30 | C     | The verdict must record evidence (matched count, browser, attempts, argv), not just an outcome — this is the replacement for the lost `verify_cmd` proof. N-of-M and spec-level-versus-grep re-run remain open. |
| 2026-09-30 | D     | Keep the bespoke tagger; a TS AST is not worth a CI-image dependency for a signature edit. Add a one-test-per-patch budget and a title check to the gate. Un-quarantine mechanism open, not optional. |
| 2026-09-30 | E     | Token must leave process arguments in both publish paths; `apply` must comment as well as push. Whether `apply` stays the intended end state is open now that no output is machine-verified. |
| 2026-09-30 | x-cut | Credential boundary confirmed sound and simplified by the pivot (no credentialed step inside the container). Its one unenforced assumption — `printf %q` on every emitted value — becomes a `validate-gates.sh` round-trip check. |
| 2026-09-30 | x-cut | Harness: 76/6 reproduced under `mawk 1.3.4`; the six failures are all action C-1. Make it green, run it under both awk dialects, wire it into CI, and add the A11 end-to-end fixture run. |
| 2026-09-30 | B     | Correction: the parser runs on the Jenkins agent, not inside the CI image, so the agent's `awk`/`grep` are what matter. Replaces the original open question. |
| 2026-10-06 | 0/C/D | **Stage 0 landed.** `Jenkinsfile:167` null-safe (default unchanged); C-1 (`AUTOFIX_ROOT` + dry-run before the spec guard) takes the harness to 84/0 under `mawk` and `gawk`; `validate-gates-all-awk.sh` runs it per dialect in a new CI stage inside the image. Reintroducing the PR #1 `{2,}` regex fails under `mawk` only, confirming the dialect shim bites. |
| 2026-10-06 | 0/D   | Answers after Stage 0: `SKIP_E2E_FLAKY_TESTS` default stays `true`; the harness runs inside the CI image and blocks the build on failure. |
| 2026-10-06 | B/x-cut | **Single awk runtime: the CI image.** The parser moves into the container; `patch_paths` drops awk so nothing on the agent needs it; `validate-gates-all-awk.sh` is deleted and the harness runs once, logging its awk. Closes the agent-awk open question and makes spike S2 moot. |
| 2026-10-06 | C     | C-3/C-4/C-6 landed. Verdict counts executed tests (Passing + Failing), not `Tests:` — the old guard passed a grep that matched nothing whenever filtered tests were reported Pending. New `multi_match` verdict; evidence (browser, counts, duration, argv) recorded and carried into `e2e-quarantine.env`. Layout lives in `lib.sh` (`E2E_PROJECTS_DIR`, `e2e_spec_path`). |
| 2026-10-06 | x-cut | A11 and the `%q` round-trip check landed as one harness section: a hostile title runs through the real parse → isolate → tag → gate chain and must source back byte-identical from every `.env`. Verified to fail when `%q` is dropped from any single producer. |
