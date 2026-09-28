#!/usr/bin/env bash
# Local gate checks — no Cursor/Bitbucket network. Unit-tests the pure helpers
# in lib.sh plus the skip behaviour of run.sh and the refuse-main guard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN="${SCRIPT_DIR}/run.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

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
rm -f "$GOOD" "$BADP" "$REN"

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
assert_exit "parse happy path (acme-app)" 0 \
  "$PARSE" "${TD}/e2e-fail-acme-app.txt" "$ENV_OUT"
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
assert_exit "isolate missing spec exits 1" 1 \
  "$ISO" "$MISS_SPEC" "$ISO_OUT"
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

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
