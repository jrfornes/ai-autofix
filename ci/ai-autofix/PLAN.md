# CI auto-fix — implementation plan

`REDESIGN.md` records what we intend to change and why, phase by phase. This
file is the order of operations, and more importantly it marks the points where
we are **not allowed to proceed on an assumption** — where the next step is a
spike, an experiment, or a decision that must wait for evidence.

Action IDs (`C-1`, `E-2`, `P0-2`, `A11`, …) refer to `REDESIGN.md`.

## Labels used below

- **SPIKE Sn** — a time-boxed investigation against the real monorepo, the real
  agent, or archived build artifacts. Its output is an answer written back into
  `REDESIGN.md`, not code we keep.
- **EXPERIMENT En** — two or more variants run concurrently on real failures and
  compared. Always in `plan` mode; nothing is pushed while an experiment runs.
- **GATE Dn** — a decision that must not be taken before named evidence exists.
  Each gate states the evidence it consumes, the options, and what each outcome
  implies.

Two rules for the gates, both of which exist to stop this system talking itself
into shipping:

1. **Thresholds are fixed at D1, before any data is collected.** A precision bar
   chosen after seeing the numbers is not a bar.
2. **Sizing is in events, never in calendar time** — E2E failures, proposals,
   specs, consecutive agreements. The failure rate is itself unknown until S7,
   so any duration we wrote down now would be invented.

---

## Stage 0 — Stop the bleeding

No unknowns, no dependencies, nothing to decide. Ship independently of
everything below.

1. **`Jenkinsfile:167`** → `params.SKIP_E2E_FLAKY_TESTS == null ? true :
   params.SKIP_E2E_FLAKY_TESTS`. Until this lands, `@flaky` removes a test from
   CI entirely rather than moving it to the tolerant stage, whichever way the
   parameter is set.
2. **Action C-1** — `AUTOFIX_ROOT` override in `isolate-e2e-failure.sh`, and move
   the dry-run branch above the spec-existence guard. Harness goes 76/82 → 82/82.
3. **Wire `validate-gates.sh` into CI** as its own stage. The only mechanical
   check in the system is currently unchecked.

**Exit:** the tolerant flaky stage is switchable, the harness is green, and it
is gated.

Switching that stage on for the first time will run tests that have not run
since they were tagged, which is **SPIKE S1**. Land the fix, then spike, then
decide whether to turn it on.

---

## Stage 1 — Retire Format/Lint

Mechanical, and behaviour-neutral **only if** Format/Lint autofix is genuinely
unused in production. That is a precondition, not an assumption:

> **SPIKE S0 (precondition).** Read the real job configuration: is
> `ENABLE_AI_AUTOFIX` ever `true`, and is `AI_AUTOFIX_MODE` ever `apply`? If it
> is in use by anyone, this stage needs an announcement and a deprecation
> window rather than a deletion.

Then execute the removal inventory in `REDESIGN.md`: six files deleted, the
`lib.sh` cull, the corresponding harness cull, and the `README.md` rewrite.

**Do not** fix the retiring `DENY_GLOBS` / `gate_patch` holes. They are real and
they die with this code.

Runs in parallel with Stage 2 — the spikes are read-only and touch nothing this
stage deletes.

---

## Stage 2 — Spikes

All read-only or throwaway. None of them change production behaviour, and they
can run concurrently.

**SPIKE S1 — what is already quarantined, and does it still work?**
Count `@flaky` tests per project; run the tolerant stage once. If the set is
large and mostly red, the problem is not detection, and Stage 5 (`apply`) is the
wrong next move — fix the suite first. Feeds D1 and the thresholds in Stage 3.

**SPIKE S2 — agent toolchain.** Which `awk` and `grep` are on the `node_ui`
agent. The parser runs in a bare `sh` step, not inside the container, so this is
the dialect that decides whether Phase B works at all. A one-liner in a scratch
job.

**SPIKE S3 — what `ci/nx-e2e-affected.sh` actually does.** Browser, base URL,
serve target, fixture seeding, retry configuration, parallelism. Two
consequences: it tells us what Phase C must inherit rather than hardcode
(action C-2), and the retry answer decides whether Cypress is *already*
reporting flakiness, which would make Phase C's re-run optional rather than
central.

**SPIKE S4 — `@cypress/grep` semantics at the pinned version.** Confirm on a
two-test scratch spec: is the title filter substring or regex, does `;` split
into alternative filters, does a leading `-` invert. Decides whether
`escape_grep` is extended (action C-5) or whether we refuse such titles outright.

**SPIKE S5 — the spec corpus.** Count template-literal titles, titles containing
`;`, titles starting with `-`, and duplicate titles within a spec. Pure
measurement with `rg`. Tells us how often the tagger's abort paths are reached —
whether they are rare edge cases or a routine dead end that makes the whole
feature narrow.

**SPIKE S6 — Cypress config topology.** Is there a shared Nx e2e preset or N
copies of `cypress.config.ts`? Then, on one project in a throwaway branch,
confirm `after:spec` delivers `spec.relative` plus `results.tests[].title`,
`state` and `attempts[]`, and that it still fires with `results.error` on a
compile break. This is the spike that decides Stage 4 is possible at all.

**SPIKE S7 — retrospective replay.** Take archived `ci-output.txt` artifacts from
past E2E failures and run today's `parse-e2e-failure.sh` over them. Zero risk,
and it is the single highest-value spike here because it produces the three
numbers everything else is sized against: how often E2E fails, what fraction
parses cleanly, and how often the same test reoffends.

### GATE D1 — is this worth building, and on what foundation?

Consumes S0–S7. Four decisions, all of which are currently guesses:

| Decision | Evidence | If yes | If no |
| --- | --- | --- | --- |
| Automate at all? | S7 failure + reoffence rate, S1 | continue | ship the tolerant stage plus reporting, stop |
| Structured output route | S6 | `after:spec` (Stage 4) | keep the parser primary, cut Stage 4 |
| Is Phase C central? | S3 retries | keep, and run E1 | retry signal leads, Phase C becomes confirmation |
| Parser stays as fallback? | S6 + Phase B timing analysis | keep for killed runs | delete once JSON is primary |

**Also fixed here, before any data exists:** the D2 precision threshold and its
minimum sample, and the D3 comparison rule. Write both into the decision log at
this gate.

One ordering branch to be aware of: if S7 shows the parser fails on a large
share of real failures, Stage 4 moves *ahead* of Stage 3 — there is no point
measuring the quality of decisions made from an identity we cannot extract.

---

## Stage 3 — Make the evidence honest, then shadow-run it

Everything here runs in `plan` mode. The system comments and never pushes.

**Build:**

- Phase C: C-2 (inherit browser), C-3 (verdict records matched count, browser,
  attempts, duration, argv), C-4 (refuse `pass` when more than one test matched),
  C-5 (grep escaping per S4), C-6 (centralise the `apps/<project>/` assumption).
- Phase E: E-1 (token out of process arguments), E-3 (loop guard against the
  fetched tip), E-4 (authenticated fetch), E-5 (require workspace/slug), E-6
  (hygiene, single JSON builder, size cap), E-8 (comment when we deliberately do
  nothing).
- Cross-cutting: the `printf %q` round-trip check, and `A11` — the end-to-end
  parse → isolate → tag → gate fixture run, which Stage 0's C-1 makes possible
  without Cypress.

**EXPERIMENT E1 — isolation strategy.** On every parsed failure, run more than
one strategy and record all verdicts in the artifact while the comment shows
only the primary:

- **A.** grep-ed single test, one attempt — today's behaviour.
- **B.** the whole spec, once — preserves within-spec ordering, so it
  distinguishes an order-dependent test from a genuine flake.
- **C.** grep-ed single test, three attempts — the N-of-M question.

Cost is bounded by the failure rate from S7 and by the existing 20-minute
timeout per strategy; compute the worst-case agent time before enabling, and cap
concurrency if it exceeds the post-failure budget.

> **E1 needs ground truth, and that is part of the deliverable.** Comparing
> strategies against each other only tells us when they disagree, not which is
> right. What was the test actually doing — a flake, an order dependency, or a
> real bug? The cheapest capture is a convention on the PR comment (a reply or a
> label the author sets when they resolve the failure). Without it this
> experiment is unfalsifiable and should not be started.

### GATE D2 — is the evidence strong enough to act on?

Consumes E1 plus the shadow-mode record, against the threshold fixed at D1. The
question is precision: of the tests it proposed quarantining, how many were
genuinely flaky. Below the bar, the system stays in `plan` mode permanently and
that is a legitimate end state — a comment that says "this looks like a flake,
here is the evidence" is useful on its own.

Two preconditions that no precision number can substitute for. They gate acting
on a "yes" rather than the measurement itself: the tolerant flaky stage genuinely
runs (Stage 0), and the decay is bounded (Stage 4).

### GATE D3 — which isolation strategy ships?

Consumes E1. Picks among A/B/C and sets `ATTEMPTS` from measured agreement with
ground truth, not from taste. Expect the answer to be a combination — for
instance, spec-level first, grep-level only to confirm. If S3 found retries
enabled, the retry signal competes here too, and it wins on cost if it is close
on accuracy, because it is free.

---

## Stage 4 — Bound the decay

Must land before `apply` is enabled, regardless of D2's numbers.

- Gate tightening: one tagged test per patch, and check the title against the
  verdict rather than only the path.
- Quarantine budget with escalation: refuse and comment past a threshold per
  spec and per project. Thresholds come from S1 and S7, not from a round number.
- Un-quarantine: the report-only job — run the `@flaky` set N times, list what
  has passed every time, let a human remove the tag.

### GATE D4 — expiry tags, or report-only?

Consumes S1 (how large the tagged set already is) and S5 (whether a second tag
vocabulary would collide with existing grep filters). Report-only is the
recommendation on file; expiry tags become attractive if the tagged set is large
enough that nobody will read a report.

---

## Stage 5 — Structured output

Conditional on D1 choosing `after:spec`. May move ahead of Stage 3 — see the
ordering branch at D1.

- `after:spec` writes one JSON file per spec; a collector picks the failure with
  an explicit, deterministic tiebreak, which replaces "first failure in log
  order" (meaningless once specs finish out of order under `NX_PARALLEL_E2E=2`).
- Artifact location, resolving `P0-2` and the Phase 0 capture question together.
  Constraint from this review: Cypress writes inside the container, the parser
  runs on the agent, so the location must be reachable and writable from both.
- Phase C consumes the JSON (`C-7`), replacing the `Tests: N` log scrape.
- Consumers move from `source` to `jq`, which retires the credential-boundary
  assumption instead of merely checking it.

**EXPERIMENT E2 — dual-run consistency.** Compute the identity both ways —
`after:spec` JSON and the existing parser — for every failure, assert they agree,
and alert on divergence. This is the safe migration shape: the new path proves
itself against the old one on real traffic before anything depends on it.

### GATE D5 — demote the parser to fallback

Consumes E2. Requires M consecutive agreements, with M fixed before E2 starts.
Divergence keeps the parser primary and becomes a bug report against the
collector, not a reason to pick a winner by hand.

---

## Stage 6 — Enable apply

Only after D2 passed and Stage 4 shipped.

- Canary on one e2e project (or one team's PRs), comparing the accepted and
  reverted rate against the shadow-mode baseline from Stage 3. Widen only if the
  canary matches the baseline.
- Narrow the token to comment + push, dropping create-PR (`E-7`).
- Renaming last: `ENABLE_AI_AUTOFIX`, `AI_AUTOFIX_MODE`, `ci/ai-autofix/`. Purely
  cosmetic, maximum churn, zero risk to defer — and by this point we will know
  what the thing should actually be called.

---

## What would make us stop

Worth writing down now, while stopping is still cheap:

- **S7** shows E2E failures are rare, or rarely the same test twice. Then this is
  a reporting problem, not an automation problem.
- **S1** shows the `@flaky` set is already large and rotting. Automating more
  quarantine accelerates a failure we already have.
- **D2** precision lands below the bar fixed at D1. Ship `plan` mode
  permanently; it is genuinely useful and carries no risk.
- **S6** shows `after:spec` cannot produce a spec path per project without
  editing N configs by hand. Then the parser stays, and the portability class of
  bug stays with it — a known cost rather than an ambush.

---

## Dependencies

| Stage | Blocked by | Blocks |
| ----- | ---------- | ------ |
| 0 Stop the bleeding | — | 3 (A11 fixture), 6 |
| 1 Retire Format/Lint | S0 | — |
| 2 Spikes | — | D1, and therefore 3, 4, 5 |
| 3 Evidence + shadow | 0, D1 | D2, D3 |
| 4 Bound the decay | S1, S7 | 6 |
| 5 Structured output | D1 (may precede 3) | D5 |
| 6 Enable apply | D2, 4 | — |
