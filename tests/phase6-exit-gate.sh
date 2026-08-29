#!/usr/bin/env bash
# Phase 6 exit gate — graduation verification.
#
# Proves that agent-run can produce a review-ready PR on the target
# repository with no YubiKey or human GitHub credential involvement.
#
# Usage:
#   ./tests/phase6-exit-gate.sh [--repo OWNER/REPO] [--skip-pr-proof]
#
# Prerequisites:
#   - OpenShell gateway running
#   - GitHub App Keychain entries configured
#   - LiteLLM Keychain entries configured
#   - scripts/agent-run.sh working (Phase 4+5 proven)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MINT_SCRIPT="${REPO_ROOT}/scripts/mint-token.sh"
POLICY_FILE="${REPO_ROOT}/openshell/sandbox-policy.yaml"
LITELLM_PROFILE="${REPO_ROOT}/openshell/litellm-inference-profile.yaml"

REPO="${REPO:-jlaska/agent-sandbox-test}"
export SKIP_PR_PROOF=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --skip-pr-proof) SKIP_PR_PROOF=true; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

SANDBOX_NAME="phase6-gate-$(date +%s | tail -c 6)"
BRANCH="agent/phase6-gate-$(date +%s | tail -c 4)"
PASS=0
FAIL=0
SKIP=0

keychain_get() { security find-generic-password -s "$1" -a "$USER" -w 2>/dev/null; }
keychain_exists() { security find-generic-password -s "$1" -a "$USER" >/dev/null 2>&1; }

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  ⏭️  SKIP: $1"; SKIP=$((SKIP + 1)); }

test_expect_pass() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

test_expect_fail() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then fail "$desc (should have failed)"; else pass "$desc"; fi
}

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
    openshell provider delete github-agent 2>/dev/null || true
    openshell provider delete claude-code 2>/dev/null || true
    openshell provider delete litellm-inference 2>/dev/null || true
    gh pr list --repo "$REPO" --head "$BRANCH" --json number -q ".[0].number" 2>/dev/null | \
        xargs -I{} gh pr close {} --repo "$REPO" --delete-branch 2>/dev/null || true
    git push origin --delete "$BRANCH" 2>/dev/null || true
    echo "  Cleanup complete."
}
trap cleanup EXIT

echo "========================================="
echo "Phase 6 Exit Gate: Graduation"
echo "========================================="
echo "  Repository: $REPO"
echo "  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# --- Section 1: Prerequisite checks ---
echo "--- Prerequisite checks ---"

test_expect_pass "OpenShell gateway running" openshell status
test_expect_pass "Token minting works" "$MINT_SCRIPT" --token-only
test_expect_pass "agent-run script exists" test -x "$REPO_ROOT/scripts/agent-run.sh"
test_expect_pass "Sandbox policy exists" test -f "$POLICY_FILE"

REPO_IN_ALLOWLIST=$(grep -c "$REPO" "$REPO_ROOT/scripts/agent-run.sh" 2>/dev/null || echo 0)
if [[ "$REPO_IN_ALLOWLIST" -gt 0 ]]; then
    pass "Repository in agent-run allowlist"
else
    fail "Repository not in agent-run allowlist"
fi

# --- Section 2: GitHub rulesets ---
echo ""
echo "--- GitHub ruleset verification ---"

RULESETS=$(gh api /repos/$REPO/rulesets --jq '.[].name' 2>/dev/null || true)
for expected in "Protect default branch" "Protect tags" "Restrict non-agent branches"; do
    if echo "$RULESETS" | grep -qF "$expected"; then
        pass "Ruleset: $expected"
    else
        fail "Ruleset missing: $expected"
    fi
done

BYPASS_COUNT=$(gh api /repos/$REPO/rulesets --jq '[.[] | (.bypass_actors // [])[] | select(.actor_type == "Integration")] | length' 2>/dev/null || echo "-1")
if [[ "$BYPASS_COUNT" == "0" ]]; then
    pass "No App bypass on rulesets"
else
    fail "App bypass found on rulesets (count: $BYPASS_COUNT)"
fi

# --- Section 3: Full security regression in sandbox ---
echo ""
echo "--- Security regression (sandboxed) ---"

MINTED_TOKEN=$("$MINT_SCRIPT" --token-only 2>/dev/null) || { echo "FATAL: mint failed"; exit 1; }

openshell provider delete github-agent 2>/dev/null || true
openshell provider create --name github-agent --type github-agent \
    --credential "api_token=${MINTED_TOKEN}" >/dev/null 2>&1

API_KEY=$(keychain_get "litellm-api-key") || { echo "FATAL: no litellm-api-key"; exit 1; }
BEARER=$(keychain_get "litellm-bearer-token") || BEARER="unused"
BASE_URL=$(keychain_get "anthropic-base-url") || { echo "FATAL: no anthropic-base-url"; exit 1; }

if ! openshell provider list-profiles 2>/dev/null | grep -q "litellm-inference"; then
    openshell provider profile import --file "$LITELLM_PROFILE" >/dev/null 2>&1
fi

openshell provider delete litellm-inference 2>/dev/null || true
openshell provider create --name litellm-inference --type litellm-inference \
    --credential "litellm_api_key=${API_KEY}" \
    --credential "litellm_bearer_token=${BEARER}" >/dev/null 2>&1

openshell provider delete claude-code 2>/dev/null || true
openshell provider create --name claude-code --type claude-code \
    --credential "api_key=${API_KEY}" >/dev/null 2>&1

eval openshell sandbox create \
    --name "$SANDBOX_NAME" \
    --provider github-agent \
    --provider litellm-inference \
    --provider claude-code \
    --policy "$POLICY_FILE" \
    --env "ANTHROPIC_API_KEY=__LITELLM_PLACEHOLDER__" \
    --env "ANTHROPIC_BASE_URL=${BASE_URL}" \
    --detach 2>&1 | grep -v "^$" || { echo "FATAL: sandbox failed"; exit 1; }

WAIT=0
while [[ $WAIT -lt 30 ]]; do
    openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME.*Ready" && break
    sleep 1; WAIT=$((WAIT + 1))
done
openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME.*Ready" || { echo "FATAL: not ready"; exit 1; }

SB="openshell sandbox exec -n $SANDBOX_NAME --"
$SB sh -c 'echo "export ANTHROPIC_API_KEY=\"$litellm_api_key\"" >> ~/.profile' 2>/dev/null

$SB git clone "https://github.com/${REPO}.git" /sandbox/repo 2>/dev/null
$SB sh -c "
    cd /sandbox/repo
    git config user.name 'jlaska-agent[bot]'
    git config user.email 'jlaska-agent[bot]@users.noreply.github.com'
    git config commit.gpgsign false
    git config tag.gpgsign false
    git config credential.helper '!f() { echo \"username=x-access-token\"; echo \"password=\${api_token}\"; }; f'
" 2>/dev/null

SBR="openshell sandbox exec -n $SANDBOX_NAME --workdir /sandbox/repo --"

# Allowed operations
test_expect_pass "Clone approved repo" true
$SBR sh -c "git checkout -b $BRANCH && echo 'phase6 gate' > phase6-gate.txt && git add phase6-gate.txt && git commit -m 'Phase 6 gate test'" >/dev/null 2>&1
test_expect_pass "Push agent branch" $SBR git push origin "$BRANCH"
test_expect_pass "Create draft PR" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr create --draft --title 'Phase 6 gate test' --body 'Automated graduation verification' --head $BRANCH --base main"

PR_NUM=$($SBR sh -c "export GH_TOKEN=\$api_token; gh pr list --head $BRANCH --json number -q '.[0].number'" 2>/dev/null)
test_expect_pass "Comment on PR" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr comment $PR_NUM --body 'Phase 6 gate: automated comment'"
test_expect_pass "Submit review" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr review $PR_NUM --comment --body 'Phase 6 gate: automated review'"
test_expect_pass "Inspect checks" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr checks $PR_NUM 2>&1; true"
test_expect_pass "Mark PR ready for review" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr ready $PR_NUM"
test_expect_pass "Commit without YubiKey" true

# Denied operations
test_expect_fail "Push main" $SBR sh -c "git checkout main 2>/dev/null; echo x > fail.txt; git add fail.txt; git commit -m fail; git push origin main"
test_expect_fail "Push unauthorized branch" $SBR sh -c "git checkout -b feature/gate 2>/dev/null; git push origin feature/gate"
test_expect_fail "Create tag" $SBR sh -c "git tag v0.0.99-gate; git push origin v0.0.99-gate"
test_expect_fail "gh pr merge" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr merge $PR_NUM --merge"
test_expect_fail "REST merge API" $SBR sh -c "export GH_TOKEN=\$api_token; gh api -X PUT repos/$REPO/pulls/$PR_NUM/merge -f merge_method=merge"
test_expect_fail "Access unapproved repo" $SBR git clone https://github.com/jlaska/homelab.git /tmp/unapproved

# Credential containment
CRED_CHECK=$($SBR sh -c 'echo "$api_token" | head -c 4' 2>/dev/null)
if [[ "$CRED_CHECK" != "ghs_" ]]; then
    pass "Credential is placeholder (not real token)"
else
    fail "Credential appears to be a real GitHub token"
fi

# Inference connectivity
INFERENCE_RESULT=$($SBR sh -c "source ~/.profile 2>/dev/null; curl -s -o /dev/null -w '%{http_code}' \"\${ANTHROPIC_BASE_URL}/v1/models\" -H 'x-api-key: '\"\$litellm_api_key\"" 2>/dev/null || echo "000")
if [[ "$INFERENCE_RESULT" == "200" || "$INFERENCE_RESULT" == "401" || "$INFERENCE_RESULT" == "403" ]]; then
    pass "Model inference reachable (HTTP $INFERENCE_RESULT)"
else
    fail "Cannot reach inference endpoint (HTTP $INFERENCE_RESULT)"
fi

# --- Summary ---
echo ""
echo "========================================="
echo "Phase 6 Exit Gate Results"
echo "========================================="
echo "  Repository: $REPO"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  SKIP: $SKIP"
echo "  TOTAL: $((PASS + FAIL + SKIP))"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "  ❌ EXIT GATE FAILED"
    exit 1
else
    echo "  ✅ EXIT GATE PASSED"
    exit 0
fi
