#!/usr/bin/env bash
# Phase E apply: commit a gated @flaky quarantine patch onto CHANGE_BRANCH tip
# and push (no sibling PR, no force). Invoked from Jenkins with Bitbucket token;
# optional second arg is e2e-quarantine.env when not already sourced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PATCH="${1:?patch file required}"
ENV_FILE="${2:-}"

if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || die "env file missing: $ENV_FILE"
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

[[ -s "$PATCH" ]] || die "patch file empty: $PATCH"

CHANGE_BRANCH="${CHANGE_BRANCH:-}"
[[ -n "$CHANGE_BRANCH" ]] || die "CHANGE_BRANCH required"
if [[ "$CHANGE_BRANCH" == "main" || "$CHANGE_BRANCH" == "master" ]]; then
  die "refusing push destination ${CHANGE_BRANCH}"
fi

TOKEN="${BITBUCKET_AUTOFIX_TOKEN:?token required}"
WORKSPACE="${BITBUCKET_WORKSPACE:-workassureonline}"
SLUG="${BITBUCKET_REPO_SLUG:-acme-ui}"
BUILD_URL="${BUILD_URL:-}"
TITLE="${E2E_TITLE:-unknown}"

IFS=',' read -r -a PATHS <<<"${AUTOFIX_PATHS:-}"
[[ "${#PATHS[@]}" -eq 1 && -n "${PATHS[0]}" ]] || die "AUTOFIX_PATHS must be exactly one path"
EXPECTED="${PATHS[0]}"

gate_e2e_quarantine_patch "$PATCH" "$EXPECTED" || die "quarantine gate rejected patch at publish"

if is_e2e_flake_head; then
  log "HEAD already has Cursor-Autofix: e2e-flake; skipping push (loop guard)"
  exit 0
fi

BASE_SHA="$(git rev-parse HEAD)"
restore_head() {
  git switch --detach "$BASE_SHA" 2>/dev/null || git checkout -q "$BASE_SHA"
}
trap restore_head EXIT

git fetch origin "${CHANGE_BRANCH}" || die "fetch origin/${CHANGE_BRANCH} failed"
TIP="$(git rev-parse "origin/${CHANGE_BRANCH}")"
git switch --detach "$TIP" 2>/dev/null || git checkout -q "$TIP"

git apply --check "$PATCH" || die "patch no longer applies on origin/${CHANGE_BRANCH} (${TIP})"
git apply "$PATCH"
git add -- "${PATHS[@]}"

if git diff --cached --quiet; then
  log "nothing staged after apply (already quarantined on tip); skipping push"
  exit 0
fi

git config user.email "cursor-ci-autofix@noreply.bitbucket"
git config user.name  "Cursor CI Autofix"
git commit -q -m "chore(e2e): [cursor-autofix] quarantine ${TITLE} as @flaky

Isolated re-run passed (spec + grep); tagging so PR E2E (-@flaky) skips it.
Source build: ${BUILD_URL:-n/a}
Do not auto-merge implications: already on the feature branch.

Cursor-Autofix: e2e-flake"

REMOTE_URL="https://x-token-auth:${TOKEN}@bitbucket.org/${WORKSPACE}/${SLUG}.git"
if ! git push "${REMOTE_URL}" "HEAD:refs/heads/${CHANGE_BRANCH}"; then
  die "push to ${CHANGE_BRANCH} failed (non-fast-forward or auth); not force-pushing"
fi

log "pushed quarantine commit to ${CHANGE_BRANCH}"
trap - EXIT
restore_head
