#!/usr/bin/env bash
# Run validate-gates.sh once per awk dialect on this machine. The PR #1 parser
# break was mawk-only and passed under gawk, so one dialect proves little.
# Fails if any dialect fails, or if no known dialect is found at all.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM_ROOT="$(mktemp -d)"
trap 'rm -rf "$SHIM_ROOT"' EXIT

ran=(); failed=()

run_with() {
  local name="$1"; shift
  local bin="${SHIM_ROOT}/${name}"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexec %s "$@"\n' "$*" >"${bin}/awk"
  chmod +x "${bin}/awk"
  echo "===== awk dialect: ${name} ====="
  if PATH="${bin}:${PATH}" "${SCRIPT_DIR}/validate-gates.sh"; then
    ran+=("$name")
  else
    ran+=("$name"); failed+=("$name")
  fi
}

for d in mawk gawk; do
  if p="$(command -v "$d")"; then run_with "$d" "$p"; fi
done
if p="$(command -v busybox)" && "$p" awk 'BEGIN{}' 2>/dev/null; then
  run_with busybox "$p" awk
fi

if [[ "${#ran[@]}" -eq 0 ]]; then
  echo "validate-gates-all-awk: no mawk, gawk or busybox awk found" >&2
  exit 1
fi
echo "validate-gates-all-awk: ran under ${ran[*]}"
if [[ "${#ran[@]}" -eq 1 ]]; then
  echo "validate-gates-all-awk: WARNING only one dialect available" >&2
fi
if [[ "${#failed[@]}" -gt 0 ]]; then
  echo "validate-gates-all-awk: FAILED under ${failed[*]}" >&2
  exit 1
fi
