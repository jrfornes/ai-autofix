#!/usr/bin/env bash
# Shared helpers for the CI auto-fix agent.
# Sourced by run.sh, agent-fix.sh, publish.sh, the *-bitbucket-pr.sh scripts and
# the E2E chain (parse, isolate, tag, push).
# Sourcing has no side effects beyond defining functions and config arrays.

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
log() { echo "[ai-autofix] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# e2e layout
# ---------------------------------------------------------------------------
# The only place the monorepo layout is assumed: e2e projects live at
# <E2E_PROJECTS_DIR>/<project>/, and E2E_SPEC is relative to the project
# (what `nx run <project>:e2e --spec` takes).
E2E_PROJECTS_DIR="apps"

e2e_spec_path() { printf '%s/%s/%s\n' "$E2E_PROJECTS_DIR" "$1" "$2"; }

# ---------------------------------------------------------------------------
# stage configuration
# ---------------------------------------------------------------------------
# Only these Jenkins stages are eligible for autofix (Phase A: format/lint only).
ELIGIBLE_STAGES=("Check Format" "Lint")

is_eligible_stage() {
  local want="$1" s
  for s in "${ELIGIBLE_STAGES[@]}"; do [[ "$s" == "$want" ]] && return 0; done
  return 1
}

# Reproduce a stage's check. Exits non-zero when broken, zero when fixed.
# Requires CHANGE_TARGET. This is the authoritative gate, run by CI on a clean
# tree — never trust a fixer claim that it fixed anything.
verify_cmd() {
  case "$1" in
    "Check Format") npx nx format:check --base "origin/${CHANGE_TARGET}" --head HEAD ;;
    "Lint")         npx nx affected --target=lint --base "origin/${CHANGE_TARGET}" ;;
    *)              return 2 ;;
  esac
}

# A pure, deterministic autofixer for a stage (no LLM, no injection surface),
# or non-zero if the stage has no safe deterministic fix.
deterministic_fix() {
  case "$1" in
    "Check Format") npx nx format:write --base "origin/${CHANGE_TARGET}" ;;
    "Lint")         npx nx affected --target=lint --fix --base "origin/${CHANGE_TARGET}" ;;
    *)              return 3 ;;
  esac
}

has_deterministic_fix() {
  case "$1" in "Check Format"|"Lint") return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# loop prevention
# ---------------------------------------------------------------------------
autofix_branch_prefix="cursor/ci-autofix-"

# True if this change was itself produced by a prior Format/Lint autofix.
# Derives the branch from CI env ONLY. `git rev-parse HEAD` returns the literal
# string "HEAD" on the detached checkouts Jenkins uses for PR builds, so it is
# useless as a branch signal. Unknown ref => treat as bot (fail safe).
# Does NOT treat Cursor-Autofix: e2e-flake (or [cursor-autofix] in subject alone)
# as bot — quarantine pushes land on the feature branch and must not disable
# Format/Lint autofix on the next build.
is_bot_change() {
  local branch="${CHANGE_BRANCH:-${BRANCH_NAME:-}}"
  if [[ -z "$branch" ]]; then
    log "loop-guard: no CHANGE_BRANCH/BRANCH_NAME; treating as bot"
    return 0
  fi
  [[ "$branch" == ${autofix_branch_prefix}* ]] && return 0
  git log -1 --pretty=%B 2>/dev/null | grep -qx 'Cursor-Autofix: true' && return 0
  return 1
}

# True if HEAD was produced by Phase E e2e quarantine push.
# Optional ref (default HEAD): publish checks the fetched tip, not the checkout.
is_e2e_flake_head() {
  git log -1 --pretty=%B "${1:-HEAD}" 2>/dev/null | grep -qx 'Cursor-Autofix: e2e-flake'
}

# ---------------------------------------------------------------------------
# bitbucket (publish only)
# ---------------------------------------------------------------------------
# The token must never reach argv (readable by every user on the agent via ps)
# or a remote URL (git echoes URLs on failure, into a public build log).

# "<workspace>/<slug>" from BITBUCKET_WORKSPACE + BITBUCKET_REPO_SLUG, else from
# origin's URL. No hardcoded default: a wrong one posts to another repository.
bitbucket_repo() {
  local ws="${BITBUCKET_WORKSPACE:-}" slug="${BITBUCKET_REPO_SLUG:-}" url
  if [[ -n "$ws" && -n "$slug" ]]; then
    printf '%s/%s\n' "$ws" "$slug"; return 0
  fi
  if [[ -n "$ws" || -n "$slug" ]]; then
    log "set both BITBUCKET_WORKSPACE and BITBUCKET_REPO_SLUG, or neither"; return 1
  fi
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$url" =~ bitbucket\.org[:/]([^/]+)/([^/]+)/?$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"; return 0
  fi
  log "cannot derive Bitbucket repo from origin '${url}'; set BITBUCKET_WORKSPACE and BITBUCKET_REPO_SLUG"
  return 1
}

# Tokens are URL-safe; anything else would also break the curl config quoting.
bitbucket_token_ok() {
  [[ "${BITBUCKET_AUTOFIX_TOKEN:-}" =~ ^[A-Za-z0-9._~+/=-]+$ ]] \
    || { log "BITBUCKET_AUTOFIX_TOKEN missing or has unexpected characters"; return 1; }
}

# git with the token as an Authorization header supplied via GIT_CONFIG_*
# (git >= 2.31). Older git ignores those silently, so probe first.
bitbucket_git() {
  bitbucket_token_ok || return 1
  if [[ "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=autofix.probe GIT_CONFIG_VALUE_0=ok \
        git config --get autofix.probe 2>/dev/null)" != "ok" ]]; then
    log "git $(git --version) ignores GIT_CONFIG_COUNT (needs >= 2.31); refusing to put the token in argv"
    return 1
  fi
  local basic
  basic="$(printf 'x-token-auth:%s' "$BITBUCKET_AUTOFIX_TOKEN" | base64 | tr -d '\n')"
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.https://bitbucket.org/.extraHeader" \
  GIT_CONFIG_VALUE_0="Authorization: Basic ${basic}" \
  GIT_TERMINAL_PROMPT=0 \
    git "$@"
}

# POST a JSON file; token goes to curl as a config on stdin. Prints HTTP code.
bitbucket_api_post() {
  local url="$1" json="$2" response="$3"
  bitbucket_token_ok || return 1
  printf 'header = "Authorization: Bearer %s"\n' "$BITBUCKET_AUTOFIX_TOKEN" \
    | curl -sS -K - -o "$response" -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' --data-binary @"$json" "$url"
}

# ---------------------------------------------------------------------------
# path gate  (mechanical enforcement of "minimal, in-scope" — not prose)
# ---------------------------------------------------------------------------
# Files the fix must never touch. In [[ $p == $glob ]], '*' crosses '/', so a
# single '*' already spans directories. Weakening a check to make it pass
# (editing lint/format/build config, deleting the failing test, churning the
# lockfile) is exactly what this list blocks.
DENY_GLOBS=(
  'ci/*' 'Jenkinsfile' '*/Jenkinsfile'
  '.cursor/*' '*/.cursor/*'
  '*.spec.ts' '*.spec.tsx' '*.test.ts' '*.test.tsx'
  '*.e2e.ts' '*.e2e.tsx' '*.cy.ts' '*.cy.tsx' '*/e2e/*'
  '.eslintrc' '.eslintrc.*' '*/.eslintrc' '*/.eslintrc.*'
  'eslint.config.*' '*/eslint.config.*'
  '.prettierrc' '.prettierrc.*' '*/.prettierrc' '*/.prettierrc.*'
  '.prettierignore' '*/.prettierignore'
  'nx.json'
  'tsconfig.json' 'tsconfig.*.json' '*/tsconfig.json' '*/tsconfig.*.json'
  'package-lock.json' 'yarn.lock' 'pnpm-lock.yaml' '*/package-lock.json'
)

is_denied_path() {
  local p="$1" g
  for g in "${DENY_GLOBS[@]}"; do
    # shellcheck disable=SC2053  # unquoted $g intentional: glob match
    [[ "$p" == $g ]] && return 0
  done
  return 1
}

# Print every file a patch touches (both sides of each diff header), deduped.
# Pure bash: push-e2e-quarantine.sh calls this on the Jenkins agent, whose awk
# is not the pinned one in the CI image.
patch_paths() {
  local line a b _
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "diff --git "* ]] || continue
    read -r _ _ a b _ <<<"$line"
    a="${a#a/}"; b="${b#b/}"
    if [[ -n "$a" ]]; then printf '%s\n' "$a"; fi
    if [[ -n "$b" ]]; then printf '%s\n' "$b"; fi
  done <"$1" | sort -u
}

# Reject a patch that renames/copies files or touches any protected path.
gate_patch() {
  local patch="$1" bad=0 p
  [[ -s "$patch" ]] || { log "gate: empty patch"; return 1; }
  if grep -qE '^(rename|copy) (from|to) ' "$patch"; then
    log "GATE FAIL: patch renames/copies files (not allowed for autofix)"
    return 1
  fi
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == "/dev/null" ]] && continue
    if is_denied_path "$p"; then
      log "GATE FAIL: protected path in patch: $p"
      bad=1
    fi
  done < <(patch_paths "$patch")
  [[ "$bad" -eq 0 ]]
}

# Quarantine-only gate: exactly one expected *.cy.ts/*.cy.js path; signature-only
# hunks that introduce @flaky (no body/assertion/import/.skip churn).
gate_e2e_quarantine_patch() {
  local patch="$1" expected="$2"
  local paths path_count p line body has_flaky=0

  [[ -s "$patch" ]] || { log "quarantine gate: empty patch"; return 1; }
  [[ -n "$expected" ]] || { log "quarantine gate: missing expected path"; return 1; }

  case "$expected" in
    *.cy.ts|*.cy.js) ;;
    *)
      log "GATE FAIL: expected path is not *.cy.ts/*.cy.js: $expected"
      return 1
      ;;
  esac

  if grep -qE '^(rename|copy) (from|to) |^deleted file mode |^new file mode ' "$patch"; then
    log "GATE FAIL: quarantine patch renames/copies/adds/deletes files"
    return 1
  fi

  paths="$(patch_paths "$patch")"
  path_count=0
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == "/dev/null" ]] && continue
    path_count=$((path_count + 1))
    if [[ "$p" != "$expected" ]]; then
      log "GATE FAIL: unexpected path in quarantine patch: $p (want $expected)"
      return 1
    fi
  done <<<"$paths"

  if [[ "$path_count" -ne 1 ]]; then
    log "GATE FAIL: quarantine patch must touch exactly one file (got $path_count)"
    return 1
  fi

  while IFS= read -r line; do
    [[ "$line" == +++* || "$line" == ---* ]] && continue
    [[ "$line" == +* || "$line" == -* ]] || continue
    body="${line:1}"

    if printf '%s' "$body" | grep -qE \
      'import[[:space:]]|(^|[[:space:]])cy\.|\.should\(|(^|[[:space:]])expect\(|(^|[^[:alnum:]_])it\.skip([^[:alnum:]_]|$)|(^|[^[:alnum:]_])describe[[:space:]]*\(|(^|[^[:alnum:]_])beforeEach[[:space:]]*\(|(^|[^[:alnum:]_])afterEach[[:space:]]*\('; then
      log "GATE FAIL: quarantine patch changes non-signature content: $body"
      return 1
    fi

    if [[ "$line" == +* ]] && printf '%s' "$body" | grep -qE '(^|[^[:alnum:]_])it\.only([^[:alnum:]_]|$)'; then
      log "GATE FAIL: quarantine patch must not leave it.only"
      return 1
    fi

    if ! printf '%s' "$body" | grep -qE \
      '(^|[^[:alnum:]_])it(\.only)?[[:space:]]*\(|tags:|@flaky'; then
      log "GATE FAIL: changed line is not an it() signature/tags edit: $body"
      return 1
    fi

    if [[ "$line" == +* ]] && printf '%s' "$body" | grep -qF '@flaky'; then
      has_flaky=1
    fi
  done < <(grep -E '^[+-]' "$patch" || true)

  if [[ "$has_flaky" -ne 1 ]]; then
    log "GATE FAIL: quarantine patch does not introduce @flaky"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# working-tree hygiene
# ---------------------------------------------------------------------------
# "Clean" ignores ci-output.txt: Jenkins writes it into the repo root as an
# untracked file on every run, so it must not count as a dirty tree.
# Workspace-root E2E capture/isolation/quarantine artifacts (and ci-output.txt)
# must survive restore/clean — Jenkins archives them after the failure post.
_E2E_ARTIFACT_RE='[[:space:]](ci-output\.txt|e2e-failure\.env|e2e-isolation\.env|e2e-quarantine\.(patch|env))$'

tree_is_clean() {
  local dirty
  dirty="$(git status --porcelain 2>/dev/null | grep -vE "$_E2E_ARTIFACT_RE" || true)"
  [[ -z "$dirty" ]]
}

# Restore the tree to a known-good SHA. Uses -fd (NOT -fdx): -x would delete
# ignored files such as node_modules, which is catastrophic in CI. ci-output.txt
# and e2e-*.env / e2e-quarantine.* are preserved for Jenkins archive.
# run.sh also calls this once at phase-1 start so Compile/postinstall noise
# (untracked caches, etc.) is not swept into the autofix patch.
restore_tree() {
  local sha="$1"
  git reset --hard "$sha" >/dev/null 2>&1 || true
  git clean -fdq \
    -e ci-output.txt \
    -e e2e-failure.env \
    -e e2e-isolation.env \
    -e e2e-quarantine.patch \
    -e e2e-quarantine.env \
    >/dev/null 2>&1 || true
}
