# CI E2E flaky-test quarantine

When the `E2E Tests` stage fails on a PR, decide whether the failing test is
flaky and, if the evidence supports it, propose quarantining it as `@flaky` —
as a PR comment (`plan`, the default) or a commit on the feature branch
(`apply`). Nothing ever auto-merges. There is no AI on the live path; the
directory and parameter names predate the 2026-09-28 pivot (see
`REDESIGN.md`).

A quarantined test still runs in the tolerant `E2E Tests - Flaky` stage when
`SKIP_E2E_FLAKY_TESTS` is unticked; it is off by default.

**Every output is a judgement, not a proof.** A test that passes when re-run
alone is consistent with flakiness, but equally with order dependence,
resource contention, or a real bug that does not reproduce in isolation. The
system records what it re-ran so a human can judge.

## The chain

Each phase is gated on the previous one producing its artifact, so any phase
that cannot decide stops everything downstream.

| Phase | Script                     | Runs in  | Produces                                  |
| ----- | -------------------------- | -------- | ----------------------------------------- |
| 0     | `runCaptured` (Jenkinsfile) | CI image | `ci-output.txt` (2 MiB tail), `FAILED_STAGE` |
| B     | `parse-e2e-failure.sh`     | CI image | `e2e-failure.env`                         |
| C     | `isolate-e2e-failure.sh`   | CI image | `e2e-isolation.env`                       |
| D     | `tag-e2e-flaky.sh` / `.mjs` | CI image | `e2e-quarantine.patch` + `.env`           |
| E     | `comment-bitbucket-pr.sh` / `push-e2e-quarantine.sh` | agent | PR comment or commit |

- **B — identity.** Scrapes the Cypress/Nx log for `E2E_PROJECT`, `E2E_SPEC`
  and `E2E_TITLE`. First failure wins. Anything ambiguous exits 1 with no file.
- **C — isolation.** Re-runs that one test with `nx run <project>:e2e --spec`,
  an escaped `--env.grep` and `--env.grepTags=-@flaky`. The verdict is `pass`
  only when exactly one test executed (Passing + Failing from the Cypress
  results table) and passed; zero is `no_match`, more than one is
  `multi_match`; also `fail`, `error`, `skipped`, `dry-run`. The verdict file
  records the evidence: browser, counts, duration and exact argv. Kill switch
  `SKIP_E2E_ISOLATION`.
- **D — quarantine patch.** On `pass`, adds `tags: ['@flaky']` to the matching
  leaf `it()`, aborting on template-literal titles, duplicates, or an existing
  `@flaky`. The single-file diff must clear `gate_e2e_quarantine_patch`. Kill
  switch `SKIP_E2E_QUARANTINE`.
- **E — publish**, only when `ENABLE_AI_AUTOFIX` is on and
  `AI_AUTOFIX_MODE` is not `off`. `plan` comments the diff with the evidence;
  `apply` re-gates it, commits it onto the `CHANGE_BRANCH` tip with trailer
  `Cursor-Autofix: e2e-flake`, and pushes — never force, never main/master,
  staging only the gated path, skipping if the tip already carries the trailer.

## Credential boundary

Phases 0–D run in the CI image with no token. Phase E is the only credentialed
step and runs on the agent, never in the container. Every value the chain
emits is written with `printf %q`, because Phase E `source`s
`e2e-quarantine.env` in the shell that holds the token and `E2E_TITLE` is
PR-author controlled; the harness enforces this with a hostile-title round
trip.

The token is never put in argv or a URL: `curl` reads it from a config on
stdin, and `git` gets it as an HTTP header through `GIT_CONFIG_*` (git ≥ 2.31;
older git is refused rather than worked around). It should be least-privilege:
PR comment + branch push, **no merge**.

## What is enforced mechanically

`gate_e2e_quarantine_patch` in `lib.sh` — run in Phase D and again at publish:

- exactly one path, equal to the one the verdict named, ending `.cy.ts` /
  `.cy.js`; no renames, copies, additions or deletions;
- every changed line is an `it()` signature, a `tags:` line, or `@flaky`, and
  none touches `cy.`, `should(`, `expect(`, `import`, `describe(`, hooks or
  `it.skip`;
- the patch must introduce `@flaky` and must not leave `it.only`.

## Configuration

| Var                       | Meaning                                                     |
| ------------------------- | ----------------------------------------------------------- |
| `ENABLE_AI_AUTOFIX`       | Jenkins parameter; enables Phase E                          |
| `AI_AUTOFIX_MODE`         | `plan` \| `apply` \| `off`                                  |
| `SKIP_E2E_ISOLATION`      | Phase C kill switch (writes a `skipped` verdict)            |
| `SKIP_E2E_QUARANTINE`     | Phase D kill switch                                         |
| `CHANGE_BRANCH`           | PR source branch; `apply` destination (never main/master)   |
| `CHANGE_ID`               | PR id for comments                                          |
| `BITBUCKET_AUTOFIX_TOKEN` | Phase E only                                                |
| `BITBUCKET_WORKSPACE` / `BITBUCKET_REPO_SLUG` | Optional, set both or neither; otherwise derived from `origin`'s bitbucket.org URL. No default |

PR comments need `jq` on the agent.

## Local checks

`./validate-gates.sh` runs with no Bitbucket network and no Cypress: parser
fixtures under `testdata/e2e-fail-*.txt`; isolation verdicts from canned
Cypress output via a fake `npx`; tagger shapes and gate rejects under
`testdata/quarantine/`; the comment and push paths against a fake `curl` and a
local bare remote, asserting the token never reaches argv; and an end-to-end
parse → isolate → tag → gate run with a hostile title that every emitted
`.env` must round-trip byte-for-byte.

CI runs it in the `Validate Quarantine Gates` stage, inside the CI image. That
image's `awk` is the only one the system depends on — the parser runs in the
container and nothing on the agent uses `awk` — so the suite runs once, and
prints which `awk` it ran under.
