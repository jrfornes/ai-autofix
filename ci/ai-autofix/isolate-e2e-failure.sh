#!/usr/bin/env bash
# Re-run one failed E2E via nx --spec + @cypress/grep. Always writes a verdict.
# Soft-fail in Jenkins — callers ignore this exit status for build result.
set -euo pipefail

ROOT="${AUTOFIX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
IN="${1:-e2e-failure.env}"
OUT="${2:-e2e-isolation.env}"
ATTEMPTS=1

log() { echo "[isolate-e2e] $*" >&2; }

write_verdict() {
  local result="$1" exit_code="$2"
  {
    echo "E2E_PROJECT=$(printf '%q' "${E2E_PROJECT:-}")"
    echo "E2E_SPEC=$(printf '%q' "${E2E_SPEC:-}")"
    echo "E2E_TITLE=$(printf '%q' "${E2E_TITLE:-}")"
    echo "ISOLATION_RESULT=$(printf '%q' "$result")"
    echo "ISOLATION_EXIT=$(printf '%q' "$exit_code")"
    echo "ISOLATION_ATTEMPTS=$(printf '%q' "$ATTEMPTS")"
  } >"$OUT"
  log "project=${E2E_PROJECT:-} spec=${E2E_SPEC:-} title=${E2E_TITLE:-} result=${result}"
}

# Escape title for @cypress/grep (treated as a JS RegExp).
escape_grep() {
  printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'
}

tests_ran_ge_1() {
  local log_file="$1"
  local count
  count="$(
    grep -Eo 'Tests:[[:space:]]+[0-9]+' "$log_file" 2>/dev/null \
      | tail -1 \
      | grep -Eo '[0-9]+$' \
      || true
  )"
  [[ -n "$count" && "$count" -gt 0 ]]
}

finish_error() {
  local code="${1:-1}"
  write_verdict error "$code"
  exit "$code"
}

cd "$ROOT"

if [[ "${SKIP_E2E_ISOLATION:-}" == "true" ]]; then
  write_verdict skipped 0
  exit 0
fi

if [[ "${ISOLATE_E2E_NO_DOCKER:-}" == "1" ]]; then
  if [[ -f "$IN" ]]; then
    unset E2E_PROJECT E2E_SPEC E2E_TITLE
    # shellcheck disable=SC1090
    set -a && source "$IN" && set +a
  fi
  finish_error 1
fi

[[ -f "$IN" ]] || finish_error 1

# Fail closed on ambient CI/env leakage: only keys from the input file count.
unset E2E_PROJECT E2E_SPEC E2E_TITLE
# shellcheck disable=SC1090
set -a && source "$IN" && set +a

if [[ -z "${E2E_PROJECT:-}" || -z "${E2E_SPEC:-}" || -z "${E2E_TITLE:-}" ]]; then
  finish_error 1
fi

GREP_PATTERN="$(escape_grep "$E2E_TITLE")"

NX_ARGV=(
  npx nx run "${E2E_PROJECT}:e2e"
  --browser=chromium
  "--spec=${E2E_SPEC}"
  "--env.grep=${GREP_PATTERN}"
  --env.grepTags=-@flaky
)

if [[ "${ISOLATE_E2E_DRY_RUN:-}" == "1" ]]; then
  printf '[isolate-e2e] dry-run argv:' >&2
  printf ' %q' "${NX_ARGV[@]}" >&2
  printf '\n' >&2
  write_verdict dry-run 0
  exit 0
fi

SPEC_PATH="apps/${E2E_PROJECT}/${E2E_SPEC}"
[[ -f "$SPEC_PATH" ]] || finish_error 1

export CI=true
export NX_DAEMON=false
export TZ="${TZ:-UTC}"

ISO_LOG="$(mktemp)"
trap 'rm -f "$ISO_LOG"' EXIT

TIMEOUT="${ISOLATE_E2E_TIMEOUT:-20m}"
nx_exit=0
if command -v timeout >/dev/null 2>&1; then
  set +e
  timeout "$TIMEOUT" "${NX_ARGV[@]}" 2>&1 | tee "$ISO_LOG"
  nx_exit=${PIPESTATUS[0]}
  set -e
else
  set +e
  "${NX_ARGV[@]}" 2>&1 | tee "$ISO_LOG"
  nx_exit=${PIPESTATUS[0]}
  set -e
fi

# GNU timeout → 124; some busybox builds use 143 after SIGTERM.
if [[ "$nx_exit" -eq 124 || "$nx_exit" -eq 143 ]]; then
  write_verdict error "$nx_exit"
  exit "$nx_exit"
fi

if ! tests_ran_ge_1 "$ISO_LOG"; then
  write_verdict no_match "$nx_exit"
  exit 1
fi

if [[ "$nx_exit" -eq 0 ]]; then
  write_verdict pass 0
  exit 0
fi

write_verdict fail "$nx_exit"
exit "$nx_exit"
