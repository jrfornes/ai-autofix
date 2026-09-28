#!/usr/bin/env bash
# Parse Nx+Cypress E2E stdout into E2E_PROJECT / E2E_SPEC / E2E_TITLE.
# Success: exit 0 + write env file. Ambiguous/partial: exit 1, no file, log why.
# Never changes Jenkins build result — callers ignore this exit status.
set -euo pipefail

LOG="${1:-ci-output.txt}"
OUT="${2:-e2e-failure.env}"

log() { echo "[parse-e2e-failure] $*" >&2; }

die() {
  log "$*"
  rm -f "$OUT"
  exit 1
}

[[ -f "$LOG" ]] || die "log not found: $LOG"

STRIPPED="$(mktemp)"
trap 'rm -f "$STRIPPED"' EXIT

# Strip ANSI / CSI sequences so regexes see plain Mocha/Nx text.
sed -E 's/\x1B\[[0-9;?]*[a-zA-Z]//g' "$LOG" >"$STRIPPED"

# Project-relative spec: *.cy.ts | *.cy.js (optionally under dirs).
SPEC_RE='((?:[^[:space:]]+/)*[^[:space:]]+\.cy\.(ts|js))'

normalize_spec() {
  local raw="$1" project="$2"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  # Absolute or repo path → strip through apps/<project>/
  if [[ "$raw" == /* || "$raw" == *"/apps/"* ]]; then
    if [[ -n "$project" && "$raw" == *"/apps/${project}/"* ]]; then
      echo "${raw#*"/apps/${project}/"}"
      return
    fi
    if [[ "$raw" =~ /apps/[^/]+/(.+\.cy\.(ts|js))$ ]]; then
      echo "${BASH_REMATCH[1]}"
      return
    fi
  fi
  raw="${raw#./}"
  echo "$raw"
}

# --- Title: first Mocha entry in the last "N failing" end-summary ----------
# Cypress prints near EOF:
#   1 failing
#   1) Suite name
#        leaf it title:
#      AssertionError: ...
failing_line="$(grep -nE '^[[:space:]]+[0-9]+[[:space:]]+failing[[:space:]]*$' "$STRIPPED" | tail -1 | cut -d: -f1 || true)"
[[ -n "$failing_line" ]] || die "no Cypress end-summary 'N failing' block"

# Slice from that summary to EOF (or next NX banner if present).
summary="$(tail -n +"$((failing_line + 1))" "$STRIPPED")"

# First numbered failure: "  1) ..."
first_block="$(printf '%s\n' "$summary" | awk '
  /^[[:space:]]+1\)/ { capture=1; print; next }
  capture && /^[[:space:]]+[0-9]+\)/ { exit }
  capture { print }
')"
[[ -n "$first_block" ]] || die "no '1)' entry after failing summary"

# Leaf title: indented line after "1) Suite", trailing colon stripped.
title="$(printf '%s\n' "$first_block" | awk '
  NR==1 { next }
  /^[[:space:]]{2,}[^[:space:]0-9]/ {
    line=$0
    sub(/^[[:space:]]+/, "", line)
    sub(/:[[:space:]]*$/, "", line)
    print line
    exit
  }
')"
[[ -n "$title" ]] || die "could not extract leaf it title from first failing entry"
[[ "$title" != *$'\n'* ]] || die "title contains newlines"

# --- Spec: nearest Spec Ran: / Running: before the summary (prefer last) ---
head_part="$(head -n "$failing_line" "$STRIPPED")"
spec_raw="$(
  printf '%s\n' "$head_part" | grep -Eo "(Spec Ran:|Running:)[[:space:]]+${SPEC_RE}" \
    | tail -1 \
    | sed -E "s/.*(Spec Ran:|Running:)[[:space:]]+//" \
    || true
)"
# Fallback: any .cy.ts/.cy.js path on a Spec Ran / Running line
if [[ -z "$spec_raw" ]]; then
  spec_raw="$(
    printf '%s\n' "$head_part" | grep -E '(Spec Ran:|Running:)' \
      | grep -Eo "${SPEC_RE}" \
      | tail -1 \
      || true
  )"
fi
[[ -n "$spec_raw" ]] || die "could not find Spec Ran: / Running: path"

# --- Project: Failed tasks: / *-e2e:e2e, else apps/<name>-e2e/ in paths -----
project=""
# Prefer Failed tasks block (often after the Cypress summary).
ft_line="$(grep -nE 'Failed tasks:' "$STRIPPED" | tail -1 | cut -d: -f1 || true)"
if [[ -n "$ft_line" ]]; then
  project="$(
    tail -n +"$((ft_line + 1))" "$STRIPPED" \
      | grep -Eo '[^[:space:]:]+-e2e:e2e' \
      | head -1 \
      | sed 's/:e2e$//' \
      || true
  )"
fi
# Failed target lines elsewhere (nx run / error summary).
if [[ -z "$project" ]]; then
  project="$(
    grep -Eo '[^[:space:]:]+-e2e:e2e' "$STRIPPED" \
      | tail -1 \
      | sed 's/:e2e$//' \
      || true
  )"
fi
# Derive from absolute/apps path if still empty.
if [[ -z "$project" ]]; then
  if [[ "$spec_raw" =~ /apps/([^/]+)/ ]]; then
    project="${BASH_REMATCH[1]}"
  elif [[ "$head_part" =~ /apps/([^/]+-e2e)/ ]]; then
    project="${BASH_REMATCH[1]}"
  fi
fi
[[ -n "$project" ]] || die "could not resolve E2E_PROJECT"

# Multi-project conflict: distinct *-e2e:e2e targets with no Failed-tasks winner.
projects_all="$(grep -Eo '[^[:space:]:]+-e2e:e2e' "$STRIPPED" | sed 's/:e2e$//' | sort -u || true)"
project_count="$(printf '%s\n' "$projects_all" | grep -c . || true)"
if [[ "$project_count" -gt 1 && -z "$ft_line" ]]; then
  die "ambiguous project (multiple *-e2e targets, no Failed tasks:): $(printf '%s' "$projects_all" | paste -sd, -)"
fi

spec="$(normalize_spec "$spec_raw" "$project")"
[[ "$spec" =~ \.cy\.(ts|js)$ ]] || die "spec not *.cy.ts|*.cy.js after normalize: $spec"
[[ -n "$spec" && -n "$title" && -n "$project" ]] || die "incomplete identity"

{
  echo "E2E_PROJECT=$(printf '%q' "$project")"
  echo "E2E_SPEC=$(printf '%q' "$spec")"
  echo "E2E_TITLE=$(printf '%q' "$title")"
} >"$OUT"

log "wrote $OUT (project=$project spec=$spec title=$title)"
exit 0
