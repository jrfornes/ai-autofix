#!/usr/bin/env bash
# Post the gated diff as a comment on the failing PR (plan mode — nothing is
# pushed). Invoked by the Jenkinsfile (E2E quarantine) and publish.sh
# (Format/Lint). Reads artifact metadata from the already-sourced environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PATCH="${1:?patch file required}"
[[ -s "$PATCH" ]] || die "patch file empty: $PATCH"

CHANGE_ID="${CHANGE_ID:?CHANGE_ID required to comment on PR}"
bitbucket_token_ok || die "token required"
command -v jq >/dev/null 2>&1 || die "jq required to build comment JSON"
REPO="$(bitbucket_repo)" || die "Bitbucket repository unknown"
API_BASE="${BITBUCKET_API_URL:-https://api.bitbucket.org/2.0}"
STAGE="${FAILED_STAGE:-unknown}"
SOURCE="${AUTOFIX_SOURCE:-agent}"
# Inline the diff only below this; an oversized body is a 4xx and no comment.
MAX_PATCH_BYTES="${MAX_PATCH_BYTES:-32768}"

BODY_FILE="$(mktemp)"; JSON_FILE="$(mktemp)"; RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}" "${JSON_FILE}" "${RESPONSE_FILE}"' EXIT

evidence_line() {  # LABEL VALUE — skipped when the verdict did not record it
  [[ -n "$2" ]] && printf -- '- %s: %s\n' "$1" "$2"
  return 0
}

{
  echo "## Cursor CI auto-fix (plan mode)"
  echo
  if [[ "$SOURCE" == "e2e-flake" ]]; then
    echo "Stage \`${STAGE}\` failed. Isolated re-run of the failing test passed;"
    echo "below is a candidate **quarantine as \`@flaky\`** (${SOURCE}) so PR E2E"
    echo "(\`-@flaky\`) skips it. It has **not** been pushed; apply it yourself if"
    echo "it looks right."
    echo
    echo "**Evidence**"
    echo
    evidence_line "Test" "\`${E2E_TITLE:-unknown}\`"
    evidence_line "Spec" "\`${E2E_PROJECT:-?}/${E2E_SPEC:-?}\`"
    evidence_line "Browser" "${ISOLATION_BROWSER:-}"
    evidence_line "Tests executed" "${ISOLATION_MATCHED:-}"
    evidence_line "Re-runs" "${ISOLATION_ATTEMPTS:-}"
    evidence_line "Duration" "${ISOLATION_DURATION_S:+${ISOLATION_DURATION_S}s}"
    evidence_line "Command" "${ISOLATION_ARGV:+\`${ISOLATION_ARGV}\`}"
    echo
    echo "A test passing alone is consistent with flakiness, but equally with"
    echo "order dependence, resource contention, or a real bug that does not"
    echo "reproduce in isolation. This is a judgement, not a proof."
  else
    echo "Stage \`${STAGE}\` failed. Below is a candidate fix (${SOURCE}) that CI"
    echo "**applied to a clean tree and re-verified** — the ${STAGE} check passes"
    echo "with it. It has **not** been pushed; apply it yourself if it looks right."
  fi
  echo
  patch_bytes="$(wc -c <"$PATCH" | tr -d ' ')"
  if [[ "$patch_bytes" -le "$MAX_PATCH_BYTES" ]]; then
    echo '```diff'
    cat "$PATCH"
    echo '```'
  else
    echo "The patch is ${patch_bytes} bytes, too large to inline; it is archived"
    echo "with the build: ${BUILD_URL:-(no BUILD_URL)}"
  fi
} >"${BODY_FILE}"

jq -n --rawfile content "${BODY_FILE}" '{content:{raw:$content}}' >"${JSON_FILE}"

API_URL="${API_BASE}/repositories/${REPO}/pullrequests/${CHANGE_ID}/comments"
HTTP_CODE="$(bitbucket_api_post "$API_URL" "$JSON_FILE" "$RESPONSE_FILE" || true)"

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  log "Bitbucket comment failed HTTP ${HTTP_CODE:-none}"
  cat "${RESPONSE_FILE}" >&2 || true
  exit 1
fi
log "commented candidate fix on PR ${CHANGE_ID}"
