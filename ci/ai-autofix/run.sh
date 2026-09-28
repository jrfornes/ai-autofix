#!/usr/bin/env bash
# ===========================================================================
# CI auto-fix — PHASE 1 (fix)
# ===========================================================================
# Produces a VERIFIED, GATED patch for a Format/Lint CI failure via Tier 0
# deterministic fixers only (nx format:write / lint --fix) and writes it as
# an artifact for the credentialed publish phase to act on.
#
# Phase A: no Cursor agent on the live path. This phase runs with NO Bitbucket
# credential, NO Cursor API key, and NO network path to Bitbucket. Everything
# that touches git remotes or the Bitbucket API lives in phase 2 (publish.sh).
#
# Exits 0 on every skip / soft failure so the ORIGINAL build failure stays the
# signal. Jenkins re-runs the real check on the patch before any PR is opened.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
cd "${REPO_ROOT}"

FAILED_STAGE="${FAILED_STAGE:-}"
CHANGE_TARGET="${CHANGE_TARGET:-}"
AI_AUTOFIX_MODE="${AI_AUTOFIX_MODE:-plan}"          # plan | apply | off
ARTIFACT_DIR="${AI_AUTOFIX_ARTIFACT_DIR:-}"

# ---- gates (every one fails open: exit 0) ---------------------------------
[[ -n "$FAILED_STAGE" ]]           || { log "FAILED_STAGE unset; skipping"; exit 0; }
is_eligible_stage "$FAILED_STAGE"  || { log "stage '$FAILED_STAGE' ineligible; skipping"; exit 0; }
[[ "$AI_AUTOFIX_MODE" != "off" ]]  || { log "mode=off; skipping"; exit 0; }
[[ -n "$CHANGE_TARGET" ]]          || { log "CHANGE_TARGET unset; skipping"; exit 0; }
[[ -f ci-output.txt ]]             || { log "ci-output.txt missing; skipping"; exit 0; }
if is_bot_change; then log "change looks like a prior autofix; skipping (loop guard)"; exit 0; fi

# Compile/postinstall often leaves untracked noise (e.g. cache/Cypress). Reset to
# committed HEAD so the patch is only fixer edits; keep node_modules and
# ci-output.txt (restore_tree uses -fd, not -fdx).
BASELINE_SHA="$(git rev-parse HEAD)"
if ! tree_is_clean; then
  log "discarding pre-existing dirty tree before fix:"
  git status --porcelain 2>/dev/null | grep -vE '[[:space:]]ci-output\.txt$' | head -n 50 >&2 || true
  restore_tree "$BASELINE_SHA"
fi
tree_is_clean || {
  log "working tree still dirty after restore; skipping"
  git status --porcelain 2>/dev/null | grep -vE '[[:space:]]ci-output\.txt$' | head -n 50 >&2 || true
  exit 0
}

: "${ARTIFACT_DIR:=$(mktemp -d)}"
mkdir -p "$ARTIFACT_DIR"
# Resolve .. and symlinks so the in-repo warning is not a false positive on
# paths like ${WORKSPACE}/../ai-autofix-N (canonical path is outside).
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"
export ARTIFACT_DIR
PATCH="${ARTIFACT_DIR}/autofix.patch"
META="${ARTIFACT_DIR}/autofix.env"
rm -f "$PATCH" "$META"

trap 'restore_tree "$BASELINE_SHA"' EXIT

# Warn (don't fail) if the artifact dir sits inside the repo — it would be swept
# into `git add -A` when capturing the patch. Jenkinsfile keeps it outside.
case "$ARTIFACT_DIR" in
  "$REPO_ROOT"|"$REPO_ROOT"/*) log "WARNING: artifact dir is inside the repo; prefer a path outside REPO_ROOT" ;;
esac

emit_meta() {  # $1 = source tag: deterministic
  {
    echo "FAILED_STAGE=$(printf '%q' "$FAILED_STAGE")"
    echo "AI_AUTOFIX_MODE=$(printf '%q' "$AI_AUTOFIX_MODE")"
    echo "AUTOFIX_SOURCE=$(printf '%q' "$1")"
    echo "AUTOFIX_PATCH=$(printf '%q' "$PATCH")"
    echo "AUTOFIX_PATHS=$(printf '%q' "$(patch_paths "$PATCH" | paste -sd, -)")"
  } >"$META"
  log "artifact ready ($1): $META"
}

# Capture whatever is currently in the working tree as a patch, gate it, then
# prove it by applying to a pristine tree and running the REAL stage check.
# On success the patch file + metadata are emitted and the function returns 0.
try_publishable_patch() {  # $1 = source tag
  local src="$1"
  git add -A -- ':(exclude)ci-output.txt' >/dev/null 2>&1 || git add -A >/dev/null 2>&1 || true
  git diff --cached >"$PATCH"
  restore_tree "$BASELINE_SHA"                       # pristine again; patch retained

  if ! gate_patch "$PATCH"; then
    log "path gate rejected the $src candidate"; return 1
  fi
  if ! git apply --check "$PATCH" >/dev/null 2>&1; then
    log "$src patch does not apply cleanly"; return 1
  fi
  git apply "$PATCH"
  if verify_cmd "$FAILED_STAGE"; then
    restore_tree "$BASELINE_SHA"
    emit_meta "$src"
    log "PASS: '$FAILED_STAGE' verified with $src patch"
    return 0
  fi
  restore_tree "$BASELINE_SHA"
  log "verify still failing after $src patch; discarding"
  return 1
}

# ---- Tier 0: deterministic (no LLM) ---------------------------------------
if has_deterministic_fix "$FAILED_STAGE"; then
  log "tier0: deterministic fix for '$FAILED_STAGE'"
  if deterministic_fix "$FAILED_STAGE"; then
    if tree_is_clean; then
      log "tier0: fixer produced no changes"
    elif try_publishable_patch "deterministic"; then
      exit 0            # deterministic fixes are trusted enough to publish
    fi
  else
    log "tier0: deterministic fixer errored"
  fi
  restore_tree "$BASELINE_SHA"
fi

log "only deterministic autofix is supported; no patch produced"
exit 0
