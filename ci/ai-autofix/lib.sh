#!/usr/bin/env bash
# Shared helpers for the E2E flaky-test quarantine chain.
# Sourced by parse, isolate, tag, push-e2e-quarantine and comment-bitbucket-pr.
# Sourcing has no side effects beyond defining functions and constants.

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
# loop prevention
# ---------------------------------------------------------------------------
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
# quarantine gate
# ---------------------------------------------------------------------------
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
