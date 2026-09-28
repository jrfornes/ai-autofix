#!/usr/bin/env bash
# Post the verified autofix diff as a review comment on the failing PR (plan
# mode — nothing is pushed). Invoked by publish.sh. Reads artifact metadata
# from the environment (sourced by publish.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PATCH="${1:?patch file required}"
[[ -s "$PATCH" ]] || die "patch file empty: $PATCH"

CHANGE_ID="${CHANGE_ID:?CHANGE_ID required to comment on PR}"
TOKEN="${BITBUCKET_AUTOFIX_TOKEN:?token required}"
WORKSPACE="${BITBUCKET_WORKSPACE:-workassureonline}"
SLUG="${BITBUCKET_REPO_SLUG:-acme-ui}"
STAGE="${FAILED_STAGE:-unknown}"
SOURCE="${AUTOFIX_SOURCE:-agent}"

BODY_FILE="$(mktemp)"; JSON_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}" "${JSON_FILE}"' EXIT

{
  echo "## Cursor CI auto-fix (plan mode)"
  echo
  if [[ "$SOURCE" == "e2e-flake" ]]; then
    echo "Stage \`${STAGE}\` failed. Isolated re-run of the failing test passed;"
    echo "below is a candidate **quarantine as \`@flaky\`** (${SOURCE}) so PR E2E"
    echo "(\`-@flaky\`) skips it. It has **not** been pushed; apply it yourself if"
    echo "it looks right."
  else
    echo "Stage \`${STAGE}\` failed. Below is a candidate fix (${SOURCE}) that CI"
    echo "**applied to a clean tree and re-verified** — the ${STAGE} check passes"
    echo "with it. It has **not** been pushed; apply it yourself if it looks right."
  fi
  echo
  echo '```diff'
  cat "$PATCH"
  echo '```'
} >"${BODY_FILE}"

if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; print(json.dumps({"content":{"raw":sys.stdin.read()}}))' \
    <"${BODY_FILE}" >"${JSON_FILE}"
elif command -v jq >/dev/null 2>&1; then
  jq -n --rawfile content "${BODY_FILE}" '{content:{raw:$content}}' >"${JSON_FILE}"
else
  die "need python3 or jq to build comment JSON"
fi

API_URL="https://api.bitbucket.org/2.0/repositories/${WORKSPACE}/${SLUG}/pullrequests/${CHANGE_ID}/comments"
HTTP_CODE="$(curl -sS -o /tmp/bb-comment-response.json -w '%{http_code}' \
  -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d @"${JSON_FILE}" "${API_URL}")"

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  log "Bitbucket comment failed HTTP ${HTTP_CODE}"
  cat /tmp/bb-comment-response.json >&2 || true
  exit 1
fi
log "commented candidate fix on PR ${CHANGE_ID}"
