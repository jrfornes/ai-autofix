#!/usr/bin/env bash
# Local gate checks — no Cursor/Bitbucket network. Unit-tests the pure helpers
# in lib.sh plus the skip behaviour of run.sh and the refuse-main guard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN="${SCRIPT_DIR}/run.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Results only hold for this awk; parse-e2e-failure.sh is its sole runtime user.
echo "awk: $(command -v awk || echo none) — $({ awk -W version || awk --version; } </dev/null 2>&1 | head -n1)"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
not()  { ! "$@"; }
check(){ if "$@"; then ok "$T"; else bad "$T"; fi; }

# assert a command exits with a specific code
assert_exit() {
  local name="$1" want="$2"; shift 2
  local got=0; "$@" >/tmp/av.out 2>&1 || got=$?
  if [[ "$got" -eq "$want" ]]; then ok "$name"
  else bad "$name (exit $got, want $want)"; cat /tmp/av.out; fi
}

run_clean() {  # clear autofix env, then apply caller overrides
  env FAILED_STAGE= CHANGE_TARGET= CHANGE_BRANCH= CHANGE_ID= \
      CURSOR_API_KEY= BITBUCKET_AUTOFIX_TOKEN= AI_AUTOFIX_MODE= \
      AI_AUTOFIX_ARTIFACT_DIR= "$@"
}

echo "== stage eligibility =="
T="eligible: Check Format"; check is_eligible_stage "Check Format"
T="eligible: Lint";         check is_eligible_stage "Lint"
T="ineligible: Build";      check not is_eligible_stage "Build"
T="ineligible: Unit Tests"; check not is_eligible_stage "Unit Tests"
T="ineligible: E2E Tests";  check not is_eligible_stage "E2E Tests"
T="has deterministic: Lint";        check has_deterministic_fix "Lint"
T="has deterministic: Check Format"; check has_deterministic_fix "Check Format"
T="no deterministic: Unit Tests";   check not has_deterministic_fix "Unit Tests"

echo "== path gate =="
T="denied: spec file";   check is_denied_path "apps/foo/src/x.spec.ts"
T="denied: eslintrc";    check is_denied_path "apps/foo/.eslintrc.json"
T="denied: nested tsconfig"; check is_denied_path "libs/bar/tsconfig.json"
T="denied: lockfile";    check is_denied_path "package-lock.json"
T="denied: ci path";     check is_denied_path "ci/ai-autofix/run.sh"
T="denied: e2e dir";     check is_denied_path "apps/foo-e2e/e2e/app.ts"
T="allowed: source ts";  check not is_denied_path "apps/foo/src/app.ts"
T="allowed: source html";check not is_denied_path "libs/ui/src/button.html"

echo "== gate_patch =="
GOOD="$(mktemp)"; BADP="$(mktemp)"; REN="$(mktemp)"
cat >"$GOOD" <<'EOF'
diff --git a/apps/foo/src/app.ts b/apps/foo/src/app.ts
index 111..222 100644
--- a/apps/foo/src/app.ts
+++ b/apps/foo/src/app.ts
@@ -1 +1 @@
-const x=1
+const x = 1;
EOF
cat >"$BADP" <<'EOF'
diff --git a/.eslintrc.json b/.eslintrc.json
index 111..222 100644
--- a/.eslintrc.json
+++ b/.eslintrc.json
@@ -1 +1 @@
-{"rules":{"eqeqeq":"error"}}
+{"rules":{}}
EOF
cat >"$REN" <<'EOF'
diff --git a/apps/foo/src/a.ts b/apps/foo/src/b.ts
similarity index 100%
rename from apps/foo/src/a.ts
rename to apps/foo/src/b.ts
EOF
T="gate accepts clean source patch"; check gate_patch "$GOOD"
T="gate rejects config patch";       check not gate_patch "$BADP"
T="gate rejects rename patch";        check not gate_patch "$REN"
T="patch_paths extracts file"
if patch_paths "$GOOD" | grep -qx apps/foo/src/app.ts; then ok "$T"; else bad "$T"; fi
T="patch_paths: both rename sides, ignores indented/added headers, no final newline"
PP="$(mktemp)"
printf '%s\n' \
  'diff --git a/apps/foo/src/a.ts b/apps/foo/src/b.ts' \
  ' diff --git a/context/line b/context/line' \
  '+diff --git a/added/line b/added/line' >"$PP"
printf '%s' 'diff --git a/b/odd.ts b/b/odd.ts' >>"$PP"
if [[ "$(patch_paths "$PP" | paste -sd, -)" == "apps/foo/src/a.ts,apps/foo/src/b.ts,b/odd.ts" ]]; then ok "$T"
else bad "$T"; patch_paths "$PP"; fi
rm -f "$GOOD" "$BADP" "$REN" "$PP"

echo "== loop guard (needs a repo) =="
TMPREPO="$(mktemp -d)"
(
  cd "$TMPREPO"
  git init -q; git config user.email t@t; git config user.name t
  echo hi >f; git add f; git commit -qm "normal work"
  # normal branch, normal message -> not a bot
  CHANGE_BRANCH="feature/x" bash -c "source '${SCRIPT_DIR}/lib.sh'; is_bot_change" && exit 20 || true
  # bot branch name -> bot
  CHANGE_BRANCH="cursor/ci-autofix-9-lint" bash -c "source '${SCRIPT_DIR}/lib.sh'; is_bot_change" || exit 21
  # empty branch (unknown ref) -> fail safe to bot
  CHANGE_BRANCH="" BRANCH_NAME="" bash -c "source '${SCRIPT_DIR}/lib.sh'; is_bot_change" || exit 22
  # bot commit trailer -> bot
  git commit -q --allow-empty -m "x

Cursor-Autofix: true"
  CHANGE_BRANCH="feature/x" bash -c "source '${SCRIPT_DIR}/lib.sh'; is_bot_change" || exit 23
  # e2e-flake trailer + [cursor-autofix] subject -> NOT Format/Lint bot
  git commit -q --allow-empty -m "chore(e2e): [cursor-autofix] quarantine title as @flaky

Cursor-Autofix: e2e-flake"
  CHANGE_BRANCH="feature/x" bash -c "source '${SCRIPT_DIR}/lib.sh'; is_bot_change" && exit 24 || true
  CHANGE_BRANCH="feature/x" bash -c "source '${SCRIPT_DIR}/lib.sh'; is_e2e_flake_head" || exit 25
)
case $? in
  0)  ok "loop guard: normal / bot-branch / unknown / trailer / e2e-flake" ;;
  20) bad "loop guard: normal change misclassified as bot" ;;
  21) bad "loop guard: bot branch not detected" ;;
  22) bad "loop guard: unknown ref not treated as bot" ;;
  23) bad "loop guard: bot trailer not detected" ;;
  24) bad "loop guard: e2e-flake misclassified as Format/Lint bot" ;;
  25) bad "loop guard: is_e2e_flake_head missed e2e-flake trailer" ;;
  *)  bad "loop guard: unexpected error" ;;
esac
rm -rf "$TMPREPO"

echo "== run.sh skip gates =="
assert_exit "skip when FAILED_STAGE unset" 0 \
  run_clean CHANGE_TARGET=main "$RUN"
assert_exit "skip ineligible stage (E2E)" 0 \
  run_clean FAILED_STAGE="E2E Tests" CHANGE_TARGET=main "$RUN"
assert_exit "skip ineligible stage (Unit Tests)" 0 \
  run_clean FAILED_STAGE="Unit Tests" CHANGE_TARGET=main "$RUN"
assert_exit "skip ineligible stage (Build)" 0 \
  run_clean FAILED_STAGE="Build" CHANGE_TARGET=main "$RUN"
assert_exit "skip when mode=off" 0 \
  run_clean FAILED_STAGE="Lint" CHANGE_TARGET=main AI_AUTOFIX_MODE=off "$RUN"
assert_exit "skip when CHANGE_TARGET unset" 0 \
  run_clean FAILED_STAGE="Lint" "$RUN"

echo "== publish guards =="
assert_exit "refuse PR into main" 1 \
  run_clean CHANGE_BRANCH=main FAILED_STAGE=Lint AUTOFIX_PATHS=x \
    BITBUCKET_AUTOFIX_TOKEN=x "${SCRIPT_DIR}/open-bitbucket-pr.sh" /etc/hostname
assert_exit "comment requires CHANGE_ID" 1 \
  run_clean BITBUCKET_AUTOFIX_TOKEN=x FAILED_STAGE=Lint \
    "${SCRIPT_DIR}/comment-bitbucket-pr.sh" /etc/hostname
assert_exit "push-e2e refuse main" 1 \
  run_clean CHANGE_BRANCH=main AUTOFIX_PATHS=apps/x/src/e2e/a.cy.ts \
    BITBUCKET_AUTOFIX_TOKEN=x E2E_TITLE=t \
    "${SCRIPT_DIR}/push-e2e-quarantine.sh" /etc/hostname
assert_exit "push-e2e refuse master" 1 \
  run_clean CHANGE_BRANCH=master AUTOFIX_PATHS=apps/x/src/e2e/a.cy.ts \
    BITBUCKET_AUTOFIX_TOKEN=x E2E_TITLE=t \
    "${SCRIPT_DIR}/push-e2e-quarantine.sh" /etc/hostname

T="push script has no force push";
check bash -c "! grep -qE 'push[[:space:]]+.*--force|push[[:space:]]+-f' '${SCRIPT_DIR}/push-e2e-quarantine.sh'"
T="push script scopes git add";
check bash -c "! grep -q 'git add -A' '${SCRIPT_DIR}/push-e2e-quarantine.sh'"
T="push script uses e2e-flake trailer";
check bash -c "grep -q 'Cursor-Autofix: e2e-flake' '${SCRIPT_DIR}/push-e2e-quarantine.sh'"
T="comment body mentions quarantine for e2e-flake";
check bash -c "grep -q 'quarantine as' '${SCRIPT_DIR}/comment-bitbucket-pr.sh'"
T="is_bot_change body has no [cursor-autofix] substring match";
check bash -c "! awk '/^is_bot_change\\(\\)/,/^}/' '${SCRIPT_DIR}/lib.sh' | grep -q '\\[cursor-autofix\\]'"

echo "== bitbucket repo + token handling (E-1, E-5) =="
bb_repo_in() {  # ORIGIN_URL [VAR=VALUE...] → bitbucket_repo output from a repo with that origin
  local url="$1"; shift
  local r; r="$(mktemp -d)"
  git -C "$r" init -q && git -C "$r" remote add origin "$url"
  (cd "$r" && env BITBUCKET_WORKSPACE= BITBUCKET_REPO_SLUG= "$@" \
    bash -c "source '${SCRIPT_DIR}/lib.sh'; bitbucket_repo" 2>/dev/null)
  local st=$?; rm -rf "$r"; return "$st"
}
T="repo from https origin";  check test "$(bb_repo_in https://bitbucket.org/ws1/slug1.git)" = ws1/slug1
T="repo from ssh origin";    check test "$(bb_repo_in git@bitbucket.org:ws2/slug2.git)" = ws2/slug2
T="explicit repo wins";      check test "$(bb_repo_in https://bitbucket.org/a/b.git BITBUCKET_WORKSPACE=x BITBUCKET_REPO_SLUG=y)" = x/y
T="non-bitbucket origin fails loudly"; check not bb_repo_in https://github.com/a/b.git
T="half-set repo vars fail";           check not bb_repo_in https://bitbucket.org/a/b.git BITBUCKET_WORKSPACE=x
T="token with quote rejected"
check not env BITBUCKET_AUTOFIX_TOKEN='abc"def' bash -c "source '${SCRIPT_DIR}/lib.sh'; bitbucket_token_ok 2>/dev/null"

SECRET="SeCrEt-token_123"
SHIM_BIN="$(mktemp -d)"; ARGV_LOG="$(mktemp)"; CURL_STDIN="$(mktemp)"; CURL_DATA="$(mktemp)"
REAL_GIT="$(command -v git)"
cat >"${SHIM_BIN}/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"${ARGV_LOG}"
cat >"${CURL_STDIN}"
out=""; prev=""
for a in "\$@"; do
  [[ "\$prev" == "-o" ]] && out="\$a"
  [[ "\$prev" == "--data-binary" ]] && cp "\${a#@}" "${CURL_DATA}"
  prev="\$a"
done
[[ -n "\$out" ]] && echo '{"error":"fake"}' >"\$out"
printf '%s' "\${FAKE_HTTP_CODE:-201}"
EOF
cat >"${SHIM_BIN}/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >>"${ARGV_LOG}"
exec "${REAL_GIT}" "\$@"
EOF
chmod +x "${SHIM_BIN}/curl" "${SHIM_BIN}/git"

COMMENT_PATCH="$(mktemp)"
printf 'diff --git a/x.cy.ts b/x.cy.ts\n+  it(%s, { tags: [%s] }, () => {\n' "'t'" "'@flaky'" >"$COMMENT_PATCH"
comment_run() {
  : >"$ARGV_LOG"
  run_clean PATH="${SHIM_BIN}:${PATH}" BITBUCKET_AUTOFIX_TOKEN="$SECRET" CHANGE_ID=7 \
    BITBUCKET_WORKSPACE=ws BITBUCKET_REPO_SLUG=slug FAILED_STAGE="E2E Tests" AUTOFIX_SOURCE=e2e-flake \
    E2E_PROJECT=p-e2e E2E_SPEC=src/e2e/x.cy.ts E2E_TITLE=t \
    ISOLATION_BROWSER=chromium ISOLATION_MATCHED=1 ISOLATION_ATTEMPTS=1 \
    "$@" "${SCRIPT_DIR}/comment-bitbucket-pr.sh" "$COMMENT_PATCH"
}
assert_exit "comment posts (fake curl 201)" 0 comment_run
T="comment: token not in curl argv";  check not grep -qF "$SECRET" "$ARGV_LOG"
T="comment: token reaches curl via stdin config"; check grep -qF "Authorization: Bearer ${SECRET}" "$CURL_STDIN"
T="comment: posts to the PR comments endpoint"
check grep -qF "https://api.bitbucket.org/2.0/repositories/ws/slug/pullrequests/7/comments" "$ARGV_LOG"
T="comment: body inlines diff and quotes evidence"
check bash -c "jq -er .content.raw '$CURL_DATA' | grep -qF '\`\`\`diff' && jq -er .content.raw '$CURL_DATA' | grep -qF -- '- Tests executed: 1' && jq -er .content.raw '$CURL_DATA' | grep -qF 'not a proof'"
comment_run MAX_PATCH_BYTES=10 >/dev/null 2>&1
T="comment: oversized patch is referenced, not inlined"
check bash -c "jq -er .content.raw '$CURL_DATA' | grep -qF 'too large to inline' && ! jq -er .content.raw '$CURL_DATA' | grep -qF '\`\`\`diff'"
assert_exit "comment: HTTP 400 exits 1" 1 comment_run FAKE_HTTP_CODE=400
T="comment: response file is not a fixed /tmp path"
check not grep -qF "/tmp/bb-comment-response.json" "${SCRIPT_DIR}/comment-bitbucket-pr.sh"
rm -f "$COMMENT_PATCH"

echo "== push-e2e-quarantine against a local remote (E-1, E-3, E-4) =="
PUSH_TMP="$(mktemp -d)"
(
  set -e
  cd "$PUSH_TMP"
  git init -q --bare remote.git
  git init -q seed && cd seed
  git config user.email t@t; git config user.name t
  mkdir -p apps/fixture-e2e/src/e2e
  cp "${TD:-${SCRIPT_DIR}/testdata}/quarantine/no-options.cy.ts" apps/fixture-e2e/src/e2e/sample.cy.ts
  git add -A && git commit -qm init
  git push -q ../remote.git HEAD:refs/heads/feature/x
  git -C ../remote.git symbolic-ref HEAD refs/heads/feature/x
  cd .. && git clone -q remote.git work && cd work
  git checkout -q --detach origin/feature/x
  node "${SCRIPT_DIR}/tag-e2e-flaky.mjs" apps/fixture-e2e/src/e2e/sample.cy.ts "no options title" 2>/dev/null
  git diff >../quarantine.patch
  git checkout -q -- apps/fixture-e2e/src/e2e/sample.cy.ts
  git remote set-url origin https://bitbucket.org/ws/slug.git
)
push_run() {
  : >"$ARGV_LOG"
  (cd "$PUSH_TMP/work" && run_clean PATH="${SHIM_BIN}:${PATH}" BITBUCKET_AUTOFIX_TOKEN="$SECRET" \
    BITBUCKET_GIT_URL="file://${PUSH_TMP}/remote.git" CHANGE_BRANCH=feature/x E2E_TITLE="no options title" \
    AUTOFIX_PATHS=apps/fixture-e2e/src/e2e/sample.cy.ts \
    "${SCRIPT_DIR}/push-e2e-quarantine.sh" "$PUSH_TMP/quarantine.patch")
}
remote_tip() { git -C "$PUSH_TMP/remote.git" rev-parse refs/heads/feature/x; }
tip_before="$(remote_tip)"
assert_exit "push: quarantine commit lands on the branch" 0 push_run
tip_after="$(remote_tip)"
T="push: remote tip moved and carries the e2e-flake trailer"
check bash -c "[[ '$tip_before' != '$tip_after' ]] && git -C '$PUSH_TMP/remote.git' log -1 --pretty=%B feature/x | grep -qx 'Cursor-Autofix: e2e-flake'"
T="push: token never in git argv"; check not grep -qF "$SECRET" "$ARGV_LOG"
T="push: fetched from the push URL, not origin"
check bash -c "grep -q '^git fetch -q file://' '$ARGV_LOG' && ! grep -q '^git fetch origin' '$ARGV_LOG'"
T="push: local HEAD restored and has no trailer"
check not bash -c "cd '$PUSH_TMP/work' && source '${SCRIPT_DIR}/lib.sh' && is_e2e_flake_head"
assert_exit "push: second run exits 0" 0 push_run
T="push: loop guard reads the fetched tip, not local HEAD"
check bash -c "[[ '$(remote_tip)' == '$tip_after' ]] && grep -q 'already has Cursor-Autofix' /tmp/av.out"
rm -rf "$PUSH_TMP" "$SHIM_BIN"; rm -f "$ARGV_LOG" "$CURL_STDIN" "$CURL_DATA"

echo "== publish.sh exports sourced artifact env (exec boundary) =="
PUB_META="$(mktemp)"; PUB_CHILD="$(mktemp)"
cat >"$PUB_META" <<'EOF'
AUTOFIX_SOURCE=deterministic
AUTOFIX_PATCH=/tmp/does-not-need-to-exist-for-this-check
AUTOFIX_PATHS=apps/foo/src/app.ts
AI_AUTOFIX_MODE=plan
EOF
cat >"$PUB_CHILD" <<'EOF'
#!/usr/bin/env bash
# Mimic open-bitbucket-pr.sh / comment-bitbucket-pr.sh: only see exported env.
[[ -n "${AUTOFIX_PATHS:-}" ]] || exit 11
[[ "${AUTOFIX_SOURCE:-}" == "deterministic" ]] || exit 12
exit 0
EOF
chmod +x "$PUB_CHILD"
# Reproduce publish.sh: set -a; source; set +a; exec child
assert_exit "sourced autofix.env reaches exec child" 0 \
  bash -c 'set -a; source "$1"; set +a; exec "$2"' _ "$PUB_META" "$PUB_CHILD"
# Prove the bug mode still fails (non-exported source)
assert_exit "non-exported source does not reach exec child" 11 \
  bash -c 'source "$1"; exec "$2"' _ "$PUB_META" "$PUB_CHILD"
rm -f "$PUB_META" "$PUB_CHILD"

echo "== open-pr path fallback from patch =="
FALLBACK_PATCH="$(mktemp)"
cat >"$FALLBACK_PATCH" <<'EOF'
diff --git a/apps/foo/src/app.ts b/apps/foo/src/app.ts
index 111..222 100644
--- a/apps/foo/src/app.ts
+++ b/apps/foo/src/app.ts
@@ -1 +1 @@
-const x=1
+const x = 1;
EOF
# Empty AUTOFIX_PATHS + valid patch: path fallback succeeds, then refuse main
assert_exit "open-pr derives paths when AUTOFIX_PATHS unset (still refuses main)" 1 \
  run_clean CHANGE_BRANCH=main FAILED_STAGE=Lint AUTOFIX_PATHS= \
    BITBUCKET_AUTOFIX_TOKEN=x "${SCRIPT_DIR}/open-bitbucket-pr.sh" "$FALLBACK_PATCH"
# Contentful file with no diff --git headers → cannot derive paths
assert_exit "open-pr dies when patch has no paths" 1 \
  run_clean CHANGE_BRANCH=feature/x FAILED_STAGE=Lint AUTOFIX_PATHS= \
    BITBUCKET_AUTOFIX_TOKEN=x "${SCRIPT_DIR}/open-bitbucket-pr.sh" /etc/hostname
rm -f "$FALLBACK_PATCH"

echo "== source markers / config sanity =="
T="loop markers present in open-pr";
check bash -c "grep -q '\[cursor-autofix\]' '${SCRIPT_DIR}/open-bitbucket-pr.sh' && grep -q 'Cursor-Autofix: true' '${SCRIPT_DIR}/open-bitbucket-pr.sh'"
T="no 'git add -A' in open-pr (scoped staging)";
check bash -c "! grep -q 'git add -A' '${SCRIPT_DIR}/open-bitbucket-pr.sh'"
T="cli config denies Shell";
check bash -c "grep -q 'Shell' '${SCRIPT_DIR}/cursor-cli-config.json'"
T="run.sh has no agent tier fallthrough";
check bash -c "! grep -q 'agent-fix.sh' '${SCRIPT_DIR}/run.sh'"
for stage in "Check Format" "Lint"; do
  T="verify map covers ${stage}"; check bash -c "grep -Fq '\"${stage}\"' '${SCRIPT_DIR}/lib.sh'"
done
for stage in "Unit Tests" "Build"; do
  T="verify map omits ${stage}"; check bash -c "! grep -Fq '\"${stage}\"' '${SCRIPT_DIR}/lib.sh'"
done

echo "== parse-e2e-failure.sh =="
PARSE="${SCRIPT_DIR}/parse-e2e-failure.sh"
TD="${SCRIPT_DIR}/testdata"
ENV_OUT="$(mktemp)"
rm -f "$ENV_OUT"
assert_exit "parse happy path (acme-product)" 0 \
  "$PARSE" "${TD}/e2e-fail-acme-product.txt" "$ENV_OUT"
T="happy path env keys"
# shellcheck disable=SC1090
if [[ -f "$ENV_OUT" ]] && set -a && source "$ENV_OUT" && set +a \
  && [[ "$E2E_PROJECT" == "acme-app-e2e" ]] \
  && [[ "$E2E_SPEC" == "src/e2e/module-a/local/products.cy.ts" ]] \
  && [[ "$E2E_TITLE" == "should show chevron link properly." ]]; then
  ok "$T"
else
  bad "$T"; cat "$ENV_OUT" 2>/dev/null || true
fi
rm -f "$ENV_OUT"

rm -f "$ENV_OUT"
assert_exit "parse ambiguous exits 1" 1 \
  "$PARSE" "${TD}/e2e-fail-ambiguous.txt" "$ENV_OUT"
T="ambiguous leaves no env file"
if [[ ! -f "$ENV_OUT" ]]; then ok "$T"; else bad "$T"; rm -f "$ENV_OUT"; fi

rm -f "$ENV_OUT"
assert_exit "parse multi-fail exits 0" 0 \
  "$PARSE" "${TD}/e2e-fail-multi.txt" "$ENV_OUT"
T="multi-fail first title wins"
# shellcheck disable=SC1090
if [[ -f "$ENV_OUT" ]] && set -a && source "$ENV_OUT" && set +a \
  && [[ "$E2E_TITLE" == "opens heatmap from session list" ]] \
  && [[ "$E2E_SPEC" == "src/e2e/spectrum-navigation.cy.ts" ]] \
  && [[ "$E2E_PROJECT" == "acme-app-e2e" ]]; then
  ok "$T"
else
  bad "$T"; cat "$ENV_OUT" 2>/dev/null || true
fi
rm -f "$ENV_OUT"

echo "== isolate-e2e-failure.sh =="
ISO="${SCRIPT_DIR}/isolate-e2e-failure.sh"
ISO_OUT="$(mktemp)"
SAMPLE="${TD}/e2e-failure.env.sample"
# Drop exported identity from parse checks so isolate children see a clean env.
unset E2E_PROJECT E2E_SPEC E2E_TITLE ISOLATION_RESULT ISOLATION_EXIT ISOLATION_ATTEMPTS 2>/dev/null || true

# Missing keys → error verdict + non-zero
BAD_ENV="$(mktemp)"
echo "E2E_PROJECT=acme-app-e2e" >"$BAD_ENV"
rm -f "$ISO_OUT"
assert_exit "isolate missing keys exits 1" 1 \
  "$ISO" "$BAD_ENV" "$ISO_OUT"
T="missing keys writes error verdict"
# shellcheck disable=SC1090
if [[ -f "$ISO_OUT" ]] && set -a && source "$ISO_OUT" && set +a \
  && [[ "$ISOLATION_RESULT" == "error" ]]; then
  ok "$T"
else
  bad "$T"; cat "$ISO_OUT" 2>/dev/null || true
fi
rm -f "$BAD_ENV" "$ISO_OUT"
unset E2E_PROJECT E2E_SPEC E2E_TITLE ISOLATION_RESULT ISOLATION_EXIT ISOLATION_ATTEMPTS 2>/dev/null || true

# Missing spec → error
MISS_SPEC="$(mktemp)"
{
  echo "E2E_PROJECT=acme-app-e2e"
  echo "E2E_SPEC=src/e2e/does-not-exist.cy.ts"
  echo "E2E_TITLE=some\ title"
} >"$MISS_SPEC"
rm -f "$ISO_OUT"
ISO_ROOT="$(mktemp -d)"
assert_exit "isolate missing spec exits 1" 1 \
  env AUTOFIX_ROOT="$ISO_ROOT" "$ISO" "$MISS_SPEC" "$ISO_OUT"
T="missing spec writes error verdict"
# shellcheck disable=SC1090
if [[ -f "$ISO_OUT" ]] && set -a && source "$ISO_OUT" && set +a \
  && [[ "$ISOLATION_RESULT" == "error" ]]; then
  ok "$T"
else
  bad "$T"; cat "$ISO_OUT" 2>/dev/null || true
fi
rm -f "$MISS_SPEC" "$ISO_OUT"
unset E2E_PROJECT E2E_SPEC E2E_TITLE ISOLATION_RESULT ISOLATION_EXIT ISOLATION_ATTEMPTS 2>/dev/null || true

# DRY_RUN locks argv shape (escaped grep, --spec, -@flaky)
rm -f "$ISO_OUT"
DRY_LOG="$(mktemp)"
assert_exit "isolate dry-run exits 0" 0 \
  env ISOLATE_E2E_DRY_RUN=1 "$ISO" "$SAMPLE" "$ISO_OUT"
# Re-run capturing stderr for argv assertions
env ISOLATE_E2E_DRY_RUN=1 "$ISO" "$SAMPLE" "$ISO_OUT" >"$DRY_LOG" 2>&1 || true
T="dry-run verdict is dry-run"
# shellcheck disable=SC1090
if [[ -f "$ISO_OUT" ]] && set -a && source "$ISO_OUT" && set +a \
  && [[ "$ISOLATION_RESULT" == "dry-run" ]] \
  && [[ "$ISOLATION_ATTEMPTS" == "1" ]]; then
  ok "$T"
else
  bad "$T"; cat "$ISO_OUT" 2>/dev/null || true
fi
T="dry-run argv has --spec"
if grep -q -- '--spec=src/e2e/module-a/local/products.cy.ts' "$DRY_LOG"; then ok "$T"; else bad "$T"; cat "$DRY_LOG"; fi
T="dry-run argv has escaped grep (dot/parens)"
# argv is printf '%q'-quoted; escaped pattern appears as dots\\.\\\(
if grep -Fq 'dots\\.\\\(and' "$DRY_LOG"; then ok "$T"; else bad "$T"; cat "$DRY_LOG"; fi
T="dry-run argv excludes @flaky"
if grep -q -- '--env.grepTags=-@flaky' "$DRY_LOG"; then ok "$T"; else bad "$T"; cat "$DRY_LOG"; fi
T="dry-run argv targets acme-app-e2e:e2e"
if grep -q 'acme-app-e2e:e2e' "$DRY_LOG"; then ok "$T"; else bad "$T"; cat "$DRY_LOG"; fi
rm -f "$ISO_OUT" "$DRY_LOG"
unset E2E_PROJECT E2E_SPEC E2E_TITLE ISOLATION_RESULT ISOLATION_EXIT ISOLATION_ATTEMPTS 2>/dev/null || true

# AUTOFIX_ROOT: relative in/out paths resolve under the override, not the repo
cp "$SAMPLE" "$ISO_ROOT/e2e-failure.env"
assert_exit "isolate dry-run under AUTOFIX_ROOT exits 0" 0 \
  env ISOLATE_E2E_DRY_RUN=1 AUTOFIX_ROOT="$ISO_ROOT" "$ISO" e2e-failure.env e2e-isolation.env
T="AUTOFIX_ROOT receives the verdict"
# shellcheck disable=SC1090
if [[ -f "$ISO_ROOT/e2e-isolation.env" && ! -e "${ROOT}/e2e-isolation.env" ]] \
  && set -a && source "$ISO_ROOT/e2e-isolation.env" && set +a \
  && [[ "$ISOLATION_RESULT" == "dry-run" ]]; then
  ok "$T"
else
  bad "$T"; ls -la "$ISO_ROOT"
fi
rm -rf "$ISO_ROOT"
unset E2E_PROJECT E2E_SPEC E2E_TITLE ISOLATION_RESULT ISOLATION_EXIT ISOLATION_ATTEMPTS 2>/dev/null || true

# Kill switch
rm -f "$ISO_OUT"
assert_exit "isolate SKIP_E2E_ISOLATION exits 0" 0 \
  env SKIP_E2E_ISOLATION=true "$ISO" "$SAMPLE" "$ISO_OUT"
T="skip writes skipped verdict"
# shellcheck disable=SC1090
if [[ -f "$ISO_OUT" ]] && set -a && source "$ISO_OUT" && set +a \
  && [[ "$ISOLATION_RESULT" == "skipped" ]]; then
  ok "$T"
else
  bad "$T"; cat "$ISO_OUT" 2>/dev/null || true
fi
rm -f "$ISO_OUT"

# --- verdict from a real (faked) run: npx on PATH replays a Cypress log ---
FAKE_BIN="$(mktemp -d)"
cat >"${FAKE_BIN}/npx" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_NPX_ARGV:-/dev/null}"
[[ -n "${FAKE_NPX_LOG:-}" ]] && cat "$FAKE_NPX_LOG"
exit "${FAKE_NPX_EXIT:-0}"
EOF
chmod +x "${FAKE_BIN}/npx"

# cypress_box TESTS PASSING FAILING PENDING — the per-spec (Results) table.
cypress_box() {
  printf '  │ Tests:        %s │\n  │ Passing:      %s │\n  │ Failing:      %s │\n  │ Pending:      %s │\n  │ Skipped:      0 │\n' "$@"
}

ISO_ROOT="$(mktemp -d)"
mkdir -p "$ISO_ROOT/apps/acme-app-e2e/src/e2e/module-a/local"
touch "$ISO_ROOT/apps/acme-app-e2e/src/e2e/module-a/local/products.cy.ts"
FAKE_LOG="$(mktemp)"

# isolate_case NAME EXIT WANT_RESULT WANT_MATCHED BOX_ARGS...  (no box args → no results table)
isolate_case() {
  local name="$1" fexit="$2" want="$3" want_matched="$4"; shift 4
  if [[ "$#" -gt 0 ]]; then cypress_box "$@" >"$FAKE_LOG"; else echo "webpack compile error" >"$FAKE_LOG"; fi
  rm -f "$ISO_OUT"
  env PATH="${FAKE_BIN}:${PATH}" AUTOFIX_ROOT="$ISO_ROOT" FAKE_NPX_LOG="$FAKE_LOG" FAKE_NPX_EXIT="$fexit" \
    "$ISO" "$SAMPLE" "$ISO_OUT" >/dev/null 2>&1 || true
  T="isolate verdict: ${name}"
  # shellcheck disable=SC1090
  if [[ -f "$ISO_OUT" ]] && set -a && source "$ISO_OUT" && set +a \
    && [[ "$ISOLATION_RESULT" == "$want" && "$ISOLATION_MATCHED" == "$want_matched" ]]; then
    ok "$T"
  else
    bad "$T (want ${want}/${want_matched})"; cat "$ISO_OUT" 2>/dev/null || true
  fi
  unset ISOLATION_RESULT ISOLATION_MATCHED
}
isolate_case "one test passed → pass"               0   pass        1  1 1 0 0
isolate_case "one test failed → fail"               1   fail        1  1 0 1 0
isolate_case "filtered tests pending, none ran"     0   no_match    0  4 0 0 4
isolate_case "grep hit two tests → multi_match"     0   multi_match 2  2 2 0 0
isolate_case "no results table → no_match"          1   no_match    ""
isolate_case "timeout → error"                      124 error       ""

isolate_case "evidence run" 0 pass 1 3 1 0 2 >/dev/null
T="pass verdict records evidence (browser, counts, duration, argv)"
# shellcheck disable=SC1090
if set -a && source "$ISO_OUT" && set +a \
  && [[ "$ISOLATION_BROWSER" == "chromium" && "$ISOLATION_PASSING" == "1" \
     && "$ISOLATION_FAILING" == "0" && "$ISOLATION_PENDING" == "2" \
     && "$ISOLATION_DURATION_S" =~ ^[0-9]+$ \
     && "$ISOLATION_ARGV" == "npx nx run acme-app-e2e:e2e --browser=chromium "* ]]; then
  ok "$T"
else
  bad "$T"; cat "$ISO_OUT"
fi
rm -rf "$ISO_ROOT" "$FAKE_LOG"
rm -f "$ISO_OUT"
unset E2E_PROJECT E2E_SPEC E2E_TITLE "${!ISOLATION_@}" 2>/dev/null || true

echo "== tag-e2e-flaky + gate_e2e_quarantine_patch =="
TAG_SH="${SCRIPT_DIR}/tag-e2e-flaky.sh"
TAG_MJS="${SCRIPT_DIR}/tag-e2e-flaky.mjs"
QD="${TD}/quarantine"
chmod +x "$TAG_SH" "$TAG_MJS" 2>/dev/null || true

# --- Node edit shapes (copy → edit → assert) ---
edit_tmp="$(mktemp -d)"
assert_tag_edit() {
  local name="$1" src="$2" title="$3" want_re="$4"
  local f="$edit_tmp/$name.cy.ts"
  cp "$src" "$f"
  local st=0
  node "$TAG_MJS" "$f" "$title" >/tmp/tag-edit.out 2>&1 || st=$?
  if [[ "$st" -ne 0 ]]; then
    bad "$name (tagger exit $st)"; cat /tmp/tag-edit.out; return
  fi
  if grep -qE "$want_re" "$f"; then ok "$name"; else bad "$name"; cat "$f"; fi
}
assert_tag_abort() {
  local name="$1" src="$2" title="$3"
  local f="$edit_tmp/$name.cy.ts"
  cp "$src" "$f"
  local before after st=0
  before="$(cat "$f")"
  node "$TAG_MJS" "$f" "$title" >/tmp/tag-abort.out 2>&1 || st=$?
  after="$(cat "$f")"
  if [[ "$st" -eq 2 && "$before" == "$after" ]]; then ok "$name"
  else bad "$name (exit $st)"; cat /tmp/tag-abort.out; cat "$f"; fi
}

assert_tag_edit "no-options inserts tags" \
  "$QD/no-options.cy.ts" "no options title" \
  "it\('no options title', \{ tags: \['@flaky'\] \},"
assert_tag_edit "append tags" \
  "$QD/append-tags.cy.ts" "append tags title" \
  "tags: \['@other', '@flaky'\]"
assert_tag_edit "multiline options adds tags" \
  "$QD/multiline-options.cy.ts" "multiline options title" \
  "tags: \['@flaky'\]"
assert_tag_edit "it.only rewrites to it + tag" \
  "$QD/it-only.cy.ts" "only title" \
  "^  it\('only title', \{ tags: \['@flaky'\] \},"
assert_tag_abort "already tagged no-op" "$QD/already-tagged.cy.ts" "already tagged title"
assert_tag_abort "duplicate title abort" "$QD/duplicate-title.cy.ts" "duplicate title"
assert_tag_abort "template title abort" "$QD/template-title.cy.ts" "template title"

# --- gate_e2e_quarantine_patch ---
GOODQ="$(mktemp)"; BADQ="$(mktemp)"
EXPECTED_Q="apps/acme-app-e2e/src/e2e/sample.cy.ts"
cat >"$GOODQ" <<'EOF'
diff --git a/apps/acme-app-e2e/src/e2e/sample.cy.ts b/apps/acme-app-e2e/src/e2e/sample.cy.ts
index 111..222 100644
--- a/apps/acme-app-e2e/src/e2e/sample.cy.ts
+++ b/apps/acme-app-e2e/src/e2e/sample.cy.ts
@@ -1,3 +1,3 @@
 describe('x', () => {
-  it('sample title', () => {
+  it('sample title', { tags: ['@flaky'] }, () => {
     cy.get('body').should('exist');
EOF
cat >"$BADQ" <<'EOF'
diff --git a/apps/acme-app-e2e/src/e2e/sample.cy.ts b/apps/acme-app-e2e/src/e2e/sample.cy.ts
index 111..222 100644
--- a/apps/acme-app-e2e/src/e2e/sample.cy.ts
+++ b/apps/acme-app-e2e/src/e2e/sample.cy.ts
@@ -1,4 +1,4 @@
 describe('x', () => {
-  it('sample title', () => {
+  it('sample title', { tags: ['@flaky'] }, () => {
-    cy.get('body').should('exist');
+    cy.get('body').should('not.exist');
EOF
T="quarantine gate accepts tag-only patch"; check gate_e2e_quarantine_patch "$GOODQ" "$EXPECTED_Q"
T="quarantine gate rejects assertion edit"; check not gate_e2e_quarantine_patch "$BADQ" "$EXPECTED_Q"
rm -f "$GOODQ" "$BADQ"

# --- shell wrapper: skip / non-pass / full emit in temp repo ---
wrap_root="$(mktemp -d)"
mkdir -p "$wrap_root/apps/fixture-e2e/src/e2e"
cp "$QD/no-options.cy.ts" "$wrap_root/apps/fixture-e2e/src/e2e/sample.cy.ts"
(
  cd "$wrap_root"
  git init -q
  git add -A
  git -c user.email=t@t -c user.name=t commit -qm init
)
ISO_PASS="$(mktemp)"
{
  echo "E2E_PROJECT=fixture-e2e"
  echo "E2E_SPEC=src/e2e/sample.cy.ts"
  echo "E2E_TITLE=no\ options\ title"
  echo "ISOLATION_RESULT=pass"
} >"$ISO_PASS"
PATCH_W="$wrap_root/e2e-quarantine.patch"
ENV_W="$wrap_root/e2e-quarantine.env"

assert_exit "tag SKIP_E2E_QUARANTINE exits 0" 0 \
  env SKIP_E2E_QUARANTINE=true AUTOFIX_ROOT="$wrap_root" \
  "$TAG_SH" "$ISO_PASS" "$PATCH_W" "$ENV_W"
T="skip leaves no quarantine artifacts"
if [[ ! -f "$PATCH_W" && ! -f "$ENV_W" ]]; then ok "$T"; else bad "$T"; fi

ISO_FAIL="$(mktemp)"
{
  echo "E2E_PROJECT=fixture-e2e"
  echo "E2E_SPEC=src/e2e/sample.cy.ts"
  echo "E2E_TITLE=no\ options\ title"
  echo "ISOLATION_RESULT=fail"
} >"$ISO_FAIL"
assert_exit "tag non-pass isolation exits 0" 0 \
  env AUTOFIX_ROOT="$wrap_root" "$TAG_SH" "$ISO_FAIL" "$PATCH_W" "$ENV_W"
T="non-pass leaves no quarantine artifacts"
if [[ ! -f "$PATCH_W" && ! -f "$ENV_W" ]]; then ok "$T"; else bad "$T"; fi

assert_exit "tag pass emits quarantine patch" 0 \
  env AUTOFIX_ROOT="$wrap_root" "$TAG_SH" "$ISO_PASS" "$PATCH_W" "$ENV_W"
T="pass writes gated patch + env"
# shellcheck disable=SC1090
if [[ -s "$PATCH_W" && -f "$ENV_W" ]] \
  && set -a && source "$ENV_W" && set +a \
  && [[ "$AUTOFIX_SOURCE" == "e2e-flake" ]] \
  && [[ "$ISOLATION_RESULT" == "pass" ]] \
  && [[ "$AUTOFIX_PATHS" == "apps/fixture-e2e/src/e2e/sample.cy.ts" ]] \
  && gate_e2e_quarantine_patch "$PATCH_W" "apps/fixture-e2e/src/e2e/sample.cy.ts"; then
  ok "$T"
else
  bad "$T"; cat "$PATCH_W" 2>/dev/null; cat "$ENV_W" 2>/dev/null
fi
T="pass restores working tree in fixture repo"
if [[ -z "$(cd "$wrap_root" && git status --porcelain -- apps/)" ]]; then ok "$T"
else bad "$T"; (cd "$wrap_root" && git status --porcelain); fi

rm -rf "$edit_tmp" "$wrap_root"
rm -f "$ISO_PASS" "$ISO_FAIL"
unset E2E_PROJECT E2E_SPEC E2E_TITLE ISOLATION_RESULT AUTOFIX_SOURCE AUTOFIX_PATHS FAILED_STAGE 2>/dev/null || true

# Every .env in the chain is later sourced by the shell holding the Bitbucket
# token, so a PR-authored title must survive each producer byte-for-byte.
echo "== chain: parse → isolate → tag → gate, hostile title =="
HOSTILE_TITLE="$(cat <<'EOF'
it's "q" $(touch PWNED) `touch PWNED2` ; $HOME \ end
EOF
)"
chain_root="$(mktemp -d)"; SANDBOX="$(mktemp -d)"
CHAIN_SPEC_REL="src/e2e/hostile.cy.ts"
CHAIN_SPEC="apps/hostile-e2e/${CHAIN_SPEC_REL}"
mkdir -p "$chain_root/apps/hostile-e2e/src/e2e"
cat >"$chain_root/$CHAIN_SPEC" <<'EOF'
describe('Hostile', () => {
  it("it's \"q\" $(touch PWNED) `touch PWNED2` ; $HOME \\ end", () => {
    cy.get('body').should('exist');
  });
});
EOF
(cd "$chain_root" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
CHAIN_LOG="$(mktemp)"
cat >"$CHAIN_LOG" <<EOF
> nx run hostile-e2e:e2e --browser=chromium --env.grepTags=-@flaky

  Running:  ${CHAIN_SPEC_REL}                          (1 of 1)

  Spec Ran:     ${CHAIN_SPEC_REL}

  1 failing

  1) Hostile
       ${HOSTILE_TITLE}:
     AssertionError: boom

Failed tasks:

- hostile-e2e:e2e
EOF

sourced_title() {  # E2E_TITLE as the publish shell would see it, sourced in a sandbox
  ( cd "$SANDBOX" && unset E2E_TITLE && set -a && source "$1" && set +a && printf '%s' "$E2E_TITLE" )
}
round_trip() {
  T="round-trip: $1 title is byte-identical"
  if [[ -f "$2" && "$(sourced_title "$2")" == "$HOSTILE_TITLE" ]]; then ok "$T"
  else bad "$T"; cat "$2" 2>/dev/null; fi
}

assert_exit "chain: parse" 0 "$PARSE" "$CHAIN_LOG" "$chain_root/e2e-failure.env"
round_trip "e2e-failure.env" "$chain_root/e2e-failure.env"

cypress_box 1 1 0 0 >"$FAKE_LOG"
FAKE_ARGV="$(mktemp)"
assert_exit "chain: isolate" 0 \
  env PATH="${FAKE_BIN}:${PATH}" AUTOFIX_ROOT="$chain_root" FAKE_NPX_LOG="$FAKE_LOG" FAKE_NPX_ARGV="$FAKE_ARGV" \
  "$ISO" e2e-failure.env e2e-isolation.env
round_trip "e2e-isolation.env" "$chain_root/e2e-isolation.env"
T="chain: isolate ran the parsed spec with a metachar-escaped grep"
if grep -qx -- "--spec=${CHAIN_SPEC_REL}" "$FAKE_ARGV" && grep -qF -- '\$\(touch PWNED\)' "$FAKE_ARGV"; then ok "$T"
else bad "$T"; cat "$FAKE_ARGV"; fi

assert_exit "chain: tag" 0 \
  env AUTOFIX_ROOT="$chain_root" "$TAG_SH" e2e-isolation.env e2e-quarantine.patch e2e-quarantine.env
round_trip "e2e-quarantine.env" "$chain_root/e2e-quarantine.env"
T="chain: quarantine patch clears the gate"
if [[ -s "$chain_root/e2e-quarantine.patch" ]] \
  && gate_e2e_quarantine_patch "$chain_root/e2e-quarantine.patch" "$CHAIN_SPEC"; then ok "$T"
else bad "$T"; cat "$chain_root/e2e-quarantine.patch" 2>/dev/null; fi

T="chain: nothing in the title was executed"
if ! compgen -G "$SANDBOX/PWNED*" >/dev/null && ! compgen -G "$chain_root/PWNED*" >/dev/null \
  && ! compgen -G "./PWNED*" >/dev/null; then ok "$T"
else bad "$T"; ls "$SANDBOX" "$chain_root"; fi

rm -rf "$chain_root" "$SANDBOX" "$FAKE_BIN"
rm -f "$CHAIN_LOG" "$FAKE_LOG" "$FAKE_ARGV"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
