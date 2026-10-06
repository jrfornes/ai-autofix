#!/usr/bin/env bash
# Re-run one failed E2E via nx --spec + @cypress/grep. Always writes a verdict,
# plus the evidence behind it (what ran, how many tests executed, how long).
# Soft-fail in Jenkins — callers ignore this exit status for build result.
set -euo pipefail

ROOT="${AUTOFIX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

IN="${1:-e2e-failure.env}"
OUT="${2:-e2e-isolation.env}"
ATTEMPTS=1
BROWSER=chromium

MATCHED="" PASSING="" FAILING="" PENDING="" DURATION_S="" ARGV_STR=""

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
    echo "ISOLATION_BROWSER=$(printf '%q' "$BROWSER")"
    echo "ISOLATION_MATCHED=$(printf '%q' "$MATCHED")"
    echo "ISOLATION_PASSING=$(printf '%q' "$PASSING")"
    echo "ISOLATION_FAILING=$(printf '%q' "$FAILING")"
    echo "ISOLATION_PENDING=$(printf '%q' "$PENDING")"
    echo "ISOLATION_DURATION_S=$(printf '%q' "$DURATION_S")"
    echo "ISOLATION_ARGV=$(printf '%q' "$ARGV_STR")"
  } >"$OUT"
  log "project=${E2E_PROJECT:-} spec=${E2E_SPEC:-} title=${E2E_TITLE:-} result=${result} matched=${MATCHED:-?}"
}

# Escape title for @cypress/grep (treated as a JS RegExp).
escape_grep() {
  printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'
}

# Last value of a Cypress results-box counter, e.g. "│ Passing:      1   │".
results_count() {
  grep -Eo "$1:[[:space:]]+[0-9]+" "$2" 2>/dev/null | tail -1 | grep -Eo '[0-9]+$' || true
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
  "--browser=${BROWSER}"
  "--spec=${E2E_SPEC}"
  "--env.grep=${GREP_PATTERN}"
  --env.grepTags=-@flaky
)
ARGV_STR="$(printf '%q ' "${NX_ARGV[@]}")"
ARGV_STR="${ARGV_STR% }"

if [[ "${ISOLATE_E2E_DRY_RUN:-}" == "1" ]]; then
  printf '[isolate-e2e] dry-run argv: %s\n' "$ARGV_STR" >&2
  write_verdict dry-run 0
  exit 0
fi

SPEC_PATH="$(e2e_spec_path "$E2E_PROJECT" "$E2E_SPEC")"
[[ -f "$SPEC_PATH" ]] || finish_error 1

export CI=true
export NX_DAEMON=false
export TZ="${TZ:-UTC}"

ISO_LOG="$(mktemp)"
trap 'rm -f "$ISO_LOG"' EXIT

TIMEOUT="${ISOLATE_E2E_TIMEOUT:-20m}"
nx_exit=0
started=$SECONDS
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
DURATION_S=$((SECONDS - started))

# GNU timeout → 124; some busybox builds use 143 after SIGTERM.
if [[ "$nx_exit" -eq 124 || "$nx_exit" -eq 143 ]]; then
  write_verdict error "$nx_exit"
  exit "$nx_exit"
fi

# Executed = Passing + Failing. Not "Tests:": unless grepOmitFiltered is set,
# @cypress/grep reports filtered-out tests as Pending, and Tests: counts them.
PASSING="$(results_count Passing "$ISO_LOG")"
FAILING="$(results_count Failing "$ISO_LOG")"
PENDING="$(results_count Pending "$ISO_LOG")"
if [[ -n "$PASSING" || -n "$FAILING" ]]; then
  MATCHED=$(( ${PASSING:-0} + ${FAILING:-0} ))
fi

if [[ -z "$MATCHED" || "$MATCHED" -eq 0 ]]; then
  write_verdict no_match "$nx_exit"
  exit 1
fi

# A grep substring hit on a sibling test would let its green count as ours.
if [[ "$MATCHED" -gt 1 ]]; then
  write_verdict multi_match "$nx_exit"
  exit 1
fi

if [[ "$nx_exit" -eq 0 && "${FAILING:-0}" -eq 0 ]]; then
  write_verdict pass 0
  exit 0
fi

write_verdict fail "$nx_exit"
if [[ "$nx_exit" -eq 0 ]]; then exit 1; fi
exit "$nx_exit"
