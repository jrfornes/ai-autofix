# CI auto-fix — implementation plan

Order of operations for `REDESIGN.md`; action IDs refer to it.

**SPIKE** — investigation; output is an answer, not code. **EXPERIMENT** —
variants compared on real failures, `plan` mode only. **GATE** — decision that
waits for named evidence.

Thresholds are fixed at D1, before data exists. Sizing is in events, not
calendar time.

## Stages

| # | Work | Gate |
| - | ---- | ---- |
| 0 | `Jenkinsfile:167` null-safe; C-1; harness into CI | — |
| 1 | Delete Format/Lint per the removal inventory | S0 first |
| 2 | Spikes | D1 |
| 3 | C-2…C-6, E-1, E-3…E-6, E-8, `%q` check, A11; then shadow-run + E1 | D2, D3 |
| 4 | Gate budget + title check; quarantine budget; report-only un-quarantine | D4 |
| 5 | `after:spec` JSON, collector tiebreak, artifact location (P0-2), C-7, `jq` over `source`; E2 | D5 |
| 6 | Enable apply — canary one project, then widen; E-7; rename | D2 + Stage 4 |

Stage 0 ships alone, no unknowns — done 2026-10-06 (see the `REDESIGN.md`
decision log). Stage 1 runs parallel with Stage 2. Stage 5
precedes Stage 3 if S7 shows the parser unreliable.

## Spikes

| ID | Question | Decides |
| -- | -------- | ------- |
| S0 | Is Format/Lint autofix used by anyone? | delete vs deprecate |
| S1 | How many `@flaky` today; does the tolerant stage pass? | Stage 4 thresholds; whether detection is the problem at all |
| ~~S2~~ | ~~Agent's `awk`/`grep`~~ — moot since 2026-10-06: the parser runs in the CI image | — |
| S3 | `nx-e2e-affected.sh`: browser, retries, serve, parallelism | C-2; whether retries make Phase C optional |
| S4 | `@cypress/grep` at the pinned version: `;`, leading `-`, substring vs regex | C-5 extend vs refuse |
| S5 | Spec corpus: template titles, `;`/`-` titles, duplicates | how often the tagger aborts |
| S6 | Shared Nx preset or N configs; does `after:spec` give path + state + attempts | Stage 5 feasibility |
| S7 | Replay archived `ci-output.txt` through today's parser | failure rate, parse rate, reoffence rate — sizes everything |

S7 is the cheapest and the most load-bearing.

## Experiments

**E1 — isolation strategy.** Per failure run (A) grep-ed test ×1, (B) whole spec
×1, (C) grep-ed test ×3. Record all verdicts, comment the primary. Cost is the
S7 rate × the 20-minute timeout per strategy. Needs ground-truth capture — what
the author concluded the failure was — or it is unfalsifiable; that capture is
part of the deliverable.

**E2 — dual-run consistency.** `after:spec` JSON versus the parser on every
failure: assert equal, alert on divergence.

## Gates

| ID | Consumes | Decides |
| -- | -------- | ------- |
| D1 | S0–S7 | automate at all; structured-output route; is Phase C central; parser kept as fallback; **and fix the D2/D3 thresholds** |
| D2 | E1 + shadow record | enable apply. Preconditions Stage 0 and Stage 4, which no precision number substitutes for. Below the bar, `plan` forever is a valid end state |
| D3 | E1 | strategy and `ATTEMPTS`; a retry signal wins ties on cost |
| D4 | S1, S5 | expiry tags vs report-only |
| D5 | E2 | demote the parser after M consecutive agreements, M fixed before E2 starts |

## Stop if

- **S7** — failures are rare, or rarely repeat. Reporting problem, not automation.
- **S1** — the `@flaky` set is already large and rotting. Fix the suite first.
- **D2** — precision below the bar. Ship `plan` permanently.
- **S6** — `after:spec` needs N hand-edited configs. Keep the parser, accept the
  known cost.
