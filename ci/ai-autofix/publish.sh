#!/usr/bin/env bash
# ===========================================================================
# CI auto-fix — PHASE 2 (publish)  [CREDENTIALED]
# ===========================================================================
# The ONLY script that sees BITBUCKET_AUTOFIX_TOKEN. It acts on the artifact
# produced by run.sh (phase 1). No agent runs here; the patch is already
# gated and verified.
#
#   apply mode -> open a PR into the feature branch
#   plan mode  -> post the diff as a review comment (no branch, no PR)
#
# Wire this in Jenkins inside a withCredentials block that binds the token; keep
# the phase-1 (run.sh) stage OUTSIDE that block so the agent never sees it.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ARTIFACT_DIR="${AI_AUTOFIX_ARTIFACT_DIR:-}"
[[ -n "$ARTIFACT_DIR" && -f "${ARTIFACT_DIR}/autofix.env" ]] \
  || { log "no artifact from phase 1; nothing to publish"; exit 0; }

# set -a so sourced keys are exported: exec'd children only inherit the
# environment, not the parent's non-exported shell variables. Without this,
# AUTOFIX_PATHS / AUTOFIX_SOURCE vanish and apply mode dies with
# "no AUTOFIX_PATHS to stage".
set -a
# shellcheck source=/dev/null
source "${ARTIFACT_DIR}/autofix.env"
set +a

[[ -n "${AUTOFIX_PATCH:-}" && -s "${AUTOFIX_PATCH}" ]] \
  || { log "artifact patch missing/empty; nothing to publish"; exit 0; }
[[ -n "${BITBUCKET_AUTOFIX_TOKEN:-}" ]] \
  || { log "BITBUCKET_AUTOFIX_TOKEN unset; cannot publish"; exit 0; }

case "${AI_AUTOFIX_MODE:-plan}" in
  plan)  exec "${SCRIPT_DIR}/comment-bitbucket-pr.sh" "${AUTOFIX_PATCH}" ;;
  apply) exec "${SCRIPT_DIR}/open-bitbucket-pr.sh"    "${AUTOFIX_PATCH}" ;;
  *)     log "mode '${AI_AUTOFIX_MODE}' is not publishable; skipping"; exit 0 ;;
esac
