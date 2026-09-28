#!/usr/bin/env bash
# Apply the verified autofix patch on a fresh branch and open a PR into the
# feature branch (never main/master). Invoked by publish.sh in apply mode.
# Reads the artifact metadata sourced by publish.sh via the environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PATCH="${1:?patch file required}"
[[ -s "$PATCH" ]] || die "patch file empty: $PATCH"

# Resolve staging paths before any git work. Prefer AUTOFIX_PATHS from the
# artifact; fall back to parsing the patch (covers a non-exported source).
IFS=',' read -r -a PATHS <<<"${AUTOFIX_PATHS:-}"
if [[ "${#PATHS[@]}" -eq 0 || -z "${PATHS[0]}" ]]; then
  IFS=',' read -r -a PATHS <<<"$(patch_paths "$PATCH" | paste -sd, -)"
fi
[[ "${#PATHS[@]}" -gt 0 && -n "${PATHS[0]}" ]] || die "no AUTOFIX_PATHS to stage"

CHANGE_BRANCH="${CHANGE_BRANCH:-}"
[[ -n "$CHANGE_BRANCH" ]] || die "CHANGE_BRANCH required (PR destination)"
if [[ "$CHANGE_BRANCH" == "main" || "$CHANGE_BRANCH" == "master" ]]; then
  die "refusing PR destination ${CHANGE_BRANCH}"
fi

TOKEN="${BITBUCKET_AUTOFIX_TOKEN:?token required}"
WORKSPACE="${BITBUCKET_WORKSPACE:-workassureonline}"
SLUG="${BITBUCKET_REPO_SLUG:-acme-ui}"
STAGE="${FAILED_STAGE:-unknown}"
SOURCE="${AUTOFIX_SOURCE:-agent}"
CHANGE_ID="${CHANGE_ID:-}"
BUILD_URL="${BUILD_URL:-}"

stage_slug() { echo "$STAGE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-'; }
BRANCH="${autofix_branch_prefix}${CHANGE_ID:-${BUILD_NUMBER:-x}}-$(stage_slug)"

if [[ -z "$(git status --porcelain)" ]]; then
  : # tree clean — good, we apply the patch ourselves below
fi

BASE_SHA="$(git rev-parse HEAD)"
git apply --check "$PATCH" || die "patch no longer applies at ${BASE_SHA}"

# Create the branch and apply the patch. Stage ONLY the gated paths (never all
# paths at once) so nothing incidental rides along.
git switch -c "$BRANCH" 2>/dev/null || git checkout -B "$BRANCH"
git apply "$PATCH"
git add -- "${PATHS[@]}"

git config user.email "cursor-ci-autofix@noreply.bitbucket"
git config user.name  "Cursor CI Autofix"
git commit -q -m "fix(ci): [cursor-autofix] ${STAGE}

Automated ${SOURCE} fix for a single CI-stage failure.
Human review required; do not auto-merge.

Cursor-Autofix: true"

REMOTE_URL="https://x-token-auth:${TOKEN}@bitbucket.org/${WORKSPACE}/${SLUG}.git"
git push "${REMOTE_URL}" "HEAD:refs/heads/${BRANCH}"

# Return to the original commit so downstream steps see a stable tree.
git switch --detach "$BASE_SHA" 2>/dev/null || git checkout -q "$BASE_SHA"

# ---- build PR body (honest about what was and wasn't verified) -------------
TITLE="[cursor-autofix] Fix ${STAGE} (PR ${CHANGE_ID:-?})"
export TITLE CHANGE_BRANCH BRANCH
DESCRIPTION_FILE="$(mktemp)"; JSON_FILE="$(mktemp)"
trap 'rm -f "${DESCRIPTION_FILE}" "${JSON_FILE}"' EXIT

if [[ "$SOURCE" == "deterministic" ]]; then
  ORIGIN_LINE="Produced by a deterministic formatter/linter autofix (no AI)."
else
  ORIGIN_LINE="Proposed by the AI autofix agent (Cursor), constrained to source files only."
fi

{
  echo "## Cursor CI auto-fix"
  echo
  echo "Opened after **${STAGE}** failed on PR ${CHANGE_ID:-n/a}."
  echo
  echo "- ${ORIGIN_LINE}"
  echo "- Source build: ${BUILD_URL:-n/a}"
  echo "- Destination: \`${CHANGE_BRANCH}\` (feature branch — never main/master)"
  echo "- CI re-ran the **${STAGE}** check on this exact patch and it passed."
  echo
  echo "A passing check confirms the failure is gone — it does **not** confirm the"
  echo "change is correct. Please review the diff, and in particular check that it"
  echo "fixes the underlying problem rather than working around it. **Do not"
  echo "auto-merge.**"
} >"${DESCRIPTION_FILE}"

if command -v python3 >/dev/null 2>&1; then
  python3 -c '
import json, os, sys
with open(sys.argv[1]) as f: description = f.read()
print(json.dumps({
  "title": os.environ["TITLE"],
  "description": description,
  "source": {"branch": {"name": os.environ["BRANCH"]}},
  "destination": {"branch": {"name": os.environ["CHANGE_BRANCH"]}},
  "close_source_branch": True,
}))' "${DESCRIPTION_FILE}" >"${JSON_FILE}"
elif command -v jq >/dev/null 2>&1; then
  jq -n --arg title "$TITLE" --arg dest "$CHANGE_BRANCH" --arg src "$BRANCH" \
        --rawfile description "${DESCRIPTION_FILE}" \
    '{title:$title, description:$description,
      source:{branch:{name:$src}}, destination:{branch:{name:$dest}},
      close_source_branch:true}' >"${JSON_FILE}"
else
  die "need python3 or jq to build PR JSON"
fi

API_URL="https://api.bitbucket.org/2.0/repositories/${WORKSPACE}/${SLUG}/pullrequests"
HTTP_CODE="$(curl -sS -o /tmp/bb-pr-response.json -w '%{http_code}' \
  -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d @"${JSON_FILE}" "${API_URL}")"

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  log "Bitbucket create PR failed HTTP ${HTTP_CODE}"
  cat /tmp/bb-pr-response.json >&2 || true
  exit 1
fi

PR_URL="$(python3 -c 'import json;print(json.load(open("/tmp/bb-pr-response.json")).get("links",{}).get("html",{}).get("href",""))' 2>/dev/null || true)"
log "opened autofix PR: ${PR_URL:-see Bitbucket response}"
