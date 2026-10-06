# CI auto-fix

Automatically proposes a fix when Check Format or Lint fails, then either
comments the fix on the PR (default) or opens a PR into the feature branch.

**Phase A:** Format/Lint via deterministic fixers only (`nx format:write` /
`lint --fix`). No Cursor agent on the live Jenkins path. Unit Tests, Build,
and E2E are not autofixed. `agent-fix.sh` / `PROMPT.md` / `cursor-cli-config.json`
remain in tree but are parked unused.

**Phase B:** On `E2E Tests` failure only, always capture stdout (2 MiB), parse
with `parse-e2e-failure.sh`, and archive `ci-output.txt` + `e2e-failure.env`
(`E2E_PROJECT` / `E2E_SPEC` / `E2E_TITLE`) when unambiguous. Not autofix-eligible.

**Phase C:** When `e2e-failure.env` exists, re-run that one test via
`isolate-e2e-failure.sh` (`nx --spec` + escaped `--env.grep` + `-@flaky`) and
archive `e2e-isolation.env`. Verdict is `pass` only when exactly one test
executed (Passing + Failing from the Cypress results table) and it passed;
zero is `no_match`, more than one is `multi_match`. The file also records the
evidence: browser, counts, duration and exact argv. Kill switch:
`SKIP_E2E_ISOLATION`. Still not autofix-eligible; no push.

**Phase D:** On isolation `pass`, `tag-e2e-flaky.sh` / `.mjs` adds `@flaky` to the
matching leaf `it`, gates the single-file diff (`gate_e2e_quarantine_patch`), and
archives `e2e-quarantine.patch` + `e2e-quarantine.env`. Kill switch:
`SKIP_E2E_QUARANTINE`. No remote push until Phase E.

**Phase E:** When quarantine artifacts exist and `ENABLE_AI_AUTOFIX` is on:
`plan` comments the diff; `apply` commits on `CHANGE_BRANCH` tip via
`push-e2e-quarantine.sh` (trailer `Cursor-Autofix: e2e-flake`, no force, no
sibling PR). Format/Lint still uses `publish.sh` + `open-bitbucket-pr.sh`.

## Design in one line

Phase 1 produces a **verified patch**. Jenkins owns git, Bitbucket, and every
credential. No model runs on the live path in Phase A.

## Two phases, one credential boundary

```
stage fails
   │
   ▼
PHASE 1  run.sh          ← NO Bitbucket token, NO Cursor key, no git remote
   ├─ gates (eligible stage, loop guard, …)
   ├─ restore to HEAD     (drop Compile/postinstall noise; then require clean)
   ├─ Tier 0: deterministic fix   (nx format:write / lint --fix)
   ├─ path gate                   (reject edits to tests/config/CI/lockfiles)
   ├─ verify                      (re-run the REAL stage check on a clean tree)
   └─ emit artifact: autofix.patch + autofix.env
   │
   ▼
PHASE 2  publish.sh      ← Bitbucket token only (Format/Lint)
   ├─ plan  → comment the verified diff on the PR
   └─ apply → open a PR into CHANGE_BRANCH (never main/master)

E2E B→D (always on E2E failure) then Phase E publish when ENABLE_AI_AUTOFIX:
   plan  → comment-bitbucket-pr.sh e2e-quarantine.patch
   apply → push-e2e-quarantine.sh (CHANGE_BRANCH tip, Cursor-Autofix: e2e-flake)
```

The phases are separate Jenkins steps. Only the publish step gets the
Bitbucket credential (see `Jenkinsfile`).

## Why deterministic only (Phase A)

Most "Check Format" and a large share of "Lint" failures are fixable with a pure
formatter/linter command — reproducible, free, and with zero injection surface.
That is the entire live autofix surface for Phase A.

## What is enforced mechanically

Enforcement is in `lib.sh` (not prose to a model):

- **Path gate** (`gate_patch`): the patch is discarded if it touches tests,
  lint/format/build config, CI, `.cursor/**`, or lockfiles, or renames files —
  i.e. it cannot pass a check by weakening or deleting it.
- **Quarantine gate** (`gate_e2e_quarantine_patch`): Phase D/E — single
  expected `*.cy.ts`/`*.cy.js` path; signature/`@flaky` edits only.
- **Clean-tree verification** (`verify_cmd`): CI applies the patch to a pristine
  tree and re-runs the actual stage. Only a real green counts (Format/Lint).
- **Scoped commit**: `open-bitbucket-pr.sh` and `push-e2e-quarantine.sh` stage
  only the gated paths, never `git add -A`.
- **Loop guard**: Format/Lint skips on `cursor/ci-autofix-*` or trailer
  `Cursor-Autofix: true` only — not `e2e-flake` / subject `[cursor-autofix]` alone.

## Recommended rollout

Start in `plan` mode (comment only). Switch to `apply` once Format/Lint diffs
and E2E quarantine comments look trustworthy on real PRs.

## Configuration

Environment (set by Jenkins):

| Var                       | Meaning                                                    |
| ------------------------- | ---------------------------------------------------------- |
| `FAILED_STAGE`            | Check Format, Lint, or E2E Tests (publish routing)         |
| `CHANGE_TARGET`           | Base branch for `nx affected`                              |
| `CHANGE_BRANCH`           | PR source branch / PR destination for autofix (never main) |
| `CHANGE_ID`               | PR id (for comments and branch naming)                     |
| `AI_AUTOFIX_MODE`         | `plan` \| `apply` \| `off`                                 |
| `AI_AUTOFIX_ARTIFACT_DIR` | Format/Lint patch dir — **must be outside the repo**       |
| `BITBUCKET_AUTOFIX_TOKEN` | Publish only; scope to push + comment + create-PR          |

The Bitbucket token should be least-privilege: branch push + PR create/comment,
**no merge**.

## Local checks

`./validate-gates.sh` exercises the gates and helpers with no Bitbucket
network access, including E2E parser fixtures under `testdata/e2e-fail-*.txt`,
Phase C isolation dry-run / error-path checks and verdicts from canned
Cypress output via a fake `npx` (no real Cypress), an end-to-end parse →
isolate → tag → gate run with a hostile title that every emitted `.env` must
round-trip byte-for-byte, Phase D
quarantine tag shapes + content-gate rejects under `testdata/quarantine/`, and
Phase E loop-guard / refuse-main checks for `push-e2e-quarantine.sh`.

CI runs it in the `Validate Quarantine Gates` stage, inside the CI image. That
image's `awk` is the only one the system depends on — the parser runs in the
container and nothing on the agent uses `awk` — so the suite runs once, and
prints which `awk` it ran under.
