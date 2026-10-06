#!/usr/bin/env bash
# On isolation pass, tag the matching leaf it() with @flaky and emit a gated patch.
# Soft-fail friendly: abort/skip paths exit 0 with no patch.
set -euo pipefail

ROOT="${AUTOFIX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

IN="${1:-e2e-isolation.env}"
PATCH_OUT="${2:-e2e-quarantine.patch}"
ENV_OUT="${3:-e2e-quarantine.env}"
TAGGER="${SCRIPT_DIR}/tag-e2e-flaky.mjs"

log() { echo "[tag-e2e-flaky] $*" >&2; }

clear_outputs() {
  rm -f "$PATCH_OUT" "$ENV_OUT"
}

cd "$ROOT"

if [[ "${SKIP_E2E_QUARANTINE:-}" == "true" ]]; then
  log "SKIP_E2E_QUARANTINE=true; skipping"
  clear_outputs
  exit 0
fi

[[ -f "$IN" ]] || { log "missing isolation env: $IN"; clear_outputs; exit 0; }

EVIDENCE_KEYS=(
  ISOLATION_ATTEMPTS ISOLATION_BROWSER ISOLATION_MATCHED ISOLATION_PASSING
  ISOLATION_FAILING ISOLATION_PENDING ISOLATION_DURATION_S ISOLATION_ARGV
)
unset E2E_PROJECT E2E_SPEC E2E_TITLE ISOLATION_RESULT "${EVIDENCE_KEYS[@]}"
# shellcheck disable=SC1090
set -a && source "$IN" && set +a

if [[ "${ISOLATION_RESULT:-}" != "pass" ]]; then
  log "ISOLATION_RESULT=${ISOLATION_RESULT:-}; skip (need pass)"
  clear_outputs
  exit 0
fi

if [[ -z "${E2E_PROJECT:-}" || -z "${E2E_SPEC:-}" || -z "${E2E_TITLE:-}" ]]; then
  log "missing E2E_* keys; skip"
  clear_outputs
  exit 0
fi

SPEC_PATH="$(e2e_spec_path "$E2E_PROJECT" "$E2E_SPEC")"
if [[ ! -f "$SPEC_PATH" ]]; then
  log "spec not found: $SPEC_PATH"
  clear_outputs
  exit 0
fi

case "$SPEC_PATH" in
  *.cy.ts|*.cy.js) ;;
  *)
    log "spec is not *.cy.ts/*.cy.js: $SPEC_PATH"
    clear_outputs
    exit 0
    ;;
esac

clear_outputs

edit_status=0
node "$TAGGER" "$SPEC_PATH" "$E2E_TITLE" || edit_status=$?

if [[ "$edit_status" -eq 2 ]]; then
  log "no patch (noop/abort)"
  exit 0
fi
if [[ "$edit_status" -ne 0 ]]; then
  log "tagger failed (exit $edit_status)"
  git checkout -- "$SPEC_PATH" >/dev/null 2>&1 || true
  exit 0
fi

diff_status=0
git diff -- "$SPEC_PATH" >"$PATCH_OUT" || diff_status=$?
git checkout -- "$SPEC_PATH" >/dev/null 2>&1 || true

if [[ "$diff_status" -ne 0 || ! -s "$PATCH_OUT" ]]; then
  log "empty or failed diff after tag; discarding"
  clear_outputs
  exit 0
fi

if ! gate_e2e_quarantine_patch "$PATCH_OUT" "$SPEC_PATH"; then
  log "quarantine gate rejected patch"
  clear_outputs
  exit 0
fi

{
  echo "AUTOFIX_SOURCE=$(printf '%q' "e2e-flake")"
  echo "FAILED_STAGE=$(printf '%q' "E2E Tests")"
  echo "E2E_PROJECT=$(printf '%q' "$E2E_PROJECT")"
  echo "E2E_SPEC=$(printf '%q' "$E2E_SPEC")"
  echo "E2E_TITLE=$(printf '%q' "$E2E_TITLE")"
  echo "AUTOFIX_PATHS=$(printf '%q' "$SPEC_PATH")"
  echo "ISOLATION_RESULT=$(printf '%q' "pass")"
  for k in "${EVIDENCE_KEYS[@]}"; do
    echo "${k}=$(printf '%q' "${!k:-}")"
  done
} >"$ENV_OUT"

log "quarantine patch ready: $PATCH_OUT"
exit 0
