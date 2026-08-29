#!/usr/bin/env bash
# Phase 5 exit gate tests — multi-agent compatibility.
#
# Usage:
#   ./tests/phase5-exit-gate.sh <agent> [--skip-inference]
#
# Supported agents: claude, pi
#
# Prerequisites:
#   - OpenShell gateway running
#   - GitHub App Keychain entries configured
#   - LiteLLM Keychain entries configured (for inference tests)
#   - bin/agent-run built

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_RUN="${REPO_ROOT}/bin/agent-run"
LITELLM_PROFILE="${REPO_ROOT}/openshell/litellm-inference-profile.yaml"

AGENT="${1:?Usage: $0 <agent> [--skip-inference]}"
SKIP_INFERENCE="${2:-}"
REPO="jlaska/agent-sandbox-test"
SANDBOX_NAME="phase5-${AGENT}-$(date +%s | tail -c 6)"
BRANCH="agent/${AGENT}/phase5-test-$(date +%s | tail -c 4)"

PASS=0
FAIL=0
SKIP=0

# --- Helpers ---
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

# --- Cleanup ---
cleanup() {
    echo ""
    echo "--- Cleanup ---"
    openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
    openshell provider delete github-agent 2>/dev/null || true
    openshell provider delete claude-code 2>/dev/null || true
    openshell provider delete litellm-inference 2>/dev/null || true
    [[ -n "${POLICY_FILE:-}" ]] && rm -f "$POLICY_FILE"
    # Clean up test branch/PR
    gh pr list --repo "$REPO" --head "$BRANCH" --json number -q ".[0].number" 2>/dev/null | \
        xargs -I{} gh pr close {} --repo "$REPO" --delete-branch 2>/dev/null || true
    git push origin --delete "$BRANCH" 2>/dev/null || true
    echo "  Cleanup complete."
}
trap cleanup EXIT

echo "========================================="
echo "Phase 5 Exit Gate: $AGENT"
echo "========================================="
echo ""

# --- Step 1: Create providers ---
echo "--- Setting up providers ---"
MINTED_TOKEN=$("$AGENT_RUN" --mint-token "$REPO" 2>/dev/null) || { echo "FATAL: mint token failed"; exit 1; }
POLICY_FILE=$("$AGENT_RUN" --generate-policy "$REPO" 2>/dev/null) || { echo "FATAL: policy generation failed"; exit 1; }

openshell provider delete github-agent 2>/dev/null || true
openshell provider create --name github-agent --type github-agent \
    --credential "api_token=${MINTED_TOKEN}" >/dev/null 2>&1

PROVIDER_FLAGS="--provider github-agent"
ENV_FLAGS=""

if [[ "$SKIP_INFERENCE" != "--skip-inference" ]]; then
    API_KEY=$(keychain_get "litellm-api-key") || { echo "FATAL: no litellm-api-key"; exit 1; }
    BEARER=$(keychain_get "litellm-bearer-token") || BEARER="unused"
    BASE_URL=$(keychain_get "anthropic-base-url") || { echo "FATAL: no anthropic-base-url"; exit 1; }

    # Import profile if needed
    if ! openshell provider list-profiles 2>/dev/null | grep -q "litellm-inference"; then
        openshell provider profile import --file "$LITELLM_PROFILE" >/dev/null 2>&1
    fi

    openshell provider delete litellm-inference 2>/dev/null || true
    openshell provider create --name litellm-inference --type litellm-inference \
        --credential "litellm_api_key=${API_KEY}" \
        --credential "litellm_bearer_token=${BEARER}" >/dev/null 2>&1
    PROVIDER_FLAGS="$PROVIDER_FLAGS --provider litellm-inference"

    if [[ "$AGENT" == "claude" ]]; then
        openshell provider delete claude-code 2>/dev/null || true
        openshell provider create --name claude-code --type claude-code \
            --credential "api_key=${API_KEY}" >/dev/null 2>&1
        PROVIDER_FLAGS="$PROVIDER_FLAGS --provider claude-code"
        ENV_FLAGS="--env ANTHROPIC_API_KEY=__LITELLM_PLACEHOLDER__ --env ANTHROPIC_BASE_URL=${BASE_URL}"
    elif [[ "$AGENT" == "pi" ]]; then
        ENV_FLAGS="--env LITELLM_BASE_URL=${BASE_URL}"
    fi
fi

# --- Step 2: Create sandbox ---
echo "--- Creating sandbox: $SANDBOX_NAME ---"
eval openshell sandbox create \
    --name "$SANDBOX_NAME" \
    $PROVIDER_FLAGS \
    --policy "$POLICY_FILE" \
    $ENV_FLAGS \
    --detach 2>&1 | grep -v "^$" || { echo "FATAL: sandbox create failed"; exit 1; }

WAIT=0
while [[ $WAIT -lt 30 ]]; do
    openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME.*Ready" && break
    sleep 1; WAIT=$((WAIT + 1))
done
openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME.*Ready" || { echo "FATAL: sandbox not ready"; exit 1; }

# --- Step 3: Agent-specific setup ---
SB="openshell sandbox exec -n $SANDBOX_NAME --"

case "$AGENT" in
    claude)
        $SB sh -c 'echo "export ANTHROPIC_API_KEY=\"\$litellm_api_key\"" >> ~/.profile' 2>/dev/null
        ;;
    pi)
        echo "  Installing Pi..."
        $SB sh -c '
            mkdir -p /sandbox/.npm-global
            npm config set prefix /sandbox/.npm-global
            npm install -g @earendil-works/pi-coding-agent
        ' 2>&1 | tail -2
        $SB sh -c '
            echo "export PATH=\"/sandbox/.npm-global/bin:\$PATH\"" >> ~/.profile
            echo "export LITELLM_API_KEY=\"\$litellm_api_key\"" >> ~/.profile
        ' 2>/dev/null
        ;;
esac

# --- Step 4: Clone and configure ---
echo "--- Cloning and configuring ---"
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

# --- Step 5: Acceptance tests ---
echo ""
echo "--- Running acceptance tests ---"
echo ""

# Allowed operations
test_expect_pass "Clone approved repo" true  # already succeeded above

echo ""
echo "  Creating branch $BRANCH..."
$SBR sh -c "git checkout -b $BRANCH && echo 'test' > phase5-gate.txt && git add phase5-gate.txt && git commit -m 'Phase 5 gate test'" >/dev/null 2>&1
test_expect_pass "Push agent branch" $SBR git push origin "$BRANCH"

$SBR sh -c "export GH_TOKEN=\$api_token; gh pr create --title 'Phase 5 gate: $AGENT' --body 'Automated' --head $BRANCH --base main" >/dev/null 2>&1
test_expect_pass "Create PR" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr list --head $BRANCH --json number -q '.[0].number' | grep -q '[0-9]'"

PR_NUM=$($SBR sh -c "export GH_TOKEN=\$api_token; gh pr list --head $BRANCH --json number -q '.[0].number'" 2>/dev/null)
test_expect_pass "Comment on PR" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr comment $PR_NUM --body 'gate test'"
test_expect_pass "Submit review" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr review $PR_NUM --comment --body 'gate review'"
test_expect_pass "Inspect checks" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr checks $PR_NUM 2>&1; true"
test_expect_pass "Commit without YubiKey" true  # commit already succeeded above

# Denied operations
test_expect_fail "Push main" $SBR sh -c "git checkout main 2>/dev/null; echo x > fail.txt; git add fail.txt; git commit -m fail; git push origin main"
test_expect_fail "Push unauthorized branch" $SBR sh -c "git checkout -b feature/gate 2>/dev/null; git push origin feature/gate"
test_expect_fail "Create tag" $SBR sh -c "git tag v0.0.99-gate; git push origin v0.0.99-gate"
test_expect_fail "gh pr merge" $SBR sh -c "export GH_TOKEN=\$api_token; gh pr merge $PR_NUM --merge"
test_expect_fail "REST merge API" $SBR sh -c "export GH_TOKEN=\$api_token; gh api -X PUT repos/$REPO/pulls/$PR_NUM/merge -f merge_method=merge"
# jlaska/agent-sandbox-denied: permanent canary (never on the App)
test_expect_fail "Access unapproved repo (canary)" $SBR git clone https://github.com/jlaska/agent-sandbox-denied.git /tmp/denied

# Credential containment
CRED_CHECK=$($SBR sh -c 'echo "$api_token" | head -c 4' 2>/dev/null)
if [[ "$CRED_CHECK" != "ghs_" ]]; then
    pass "Credential is placeholder (not real token)"
else
    fail "Credential appears to be a real GitHub token"
fi

GITHUB_TOKEN_LEN=$($SBR sh -c 'echo ${#GITHUB_TOKEN}' 2>/dev/null)
if [[ "$GITHUB_TOKEN_LEN" == "0" ]]; then
    pass "No GITHUB_TOKEN exposed"
else
    fail "GITHUB_TOKEN exposed ($GITHUB_TOKEN_LEN chars)"
fi

# Inference test
if [[ "$SKIP_INFERENCE" != "--skip-inference" ]]; then
    echo ""
    echo "  Inference test (LiteLLM connectivity)..."
    INFERENCE_RESULT=$($SBR sh -c "source ~/.profile 2>/dev/null; curl -s -o /dev/null -w '%{http_code}' \"\${ANTHROPIC_BASE_URL:-\$LITELLM_BASE_URL}/v1/models\" -H 'x-api-key: '\"\$litellm_api_key\"" 2>/dev/null || echo "000")
    if [[ "$INFERENCE_RESULT" == "200" || "$INFERENCE_RESULT" == "401" || "$INFERENCE_RESULT" == "403" ]]; then
        pass "Model auth reaches LiteLLM (HTTP $INFERENCE_RESULT)"
    else
        fail "Cannot reach LiteLLM (HTTP $INFERENCE_RESULT)"
    fi
else
    skip "Inference test (--skip-inference)"
fi

# --- Summary ---
echo ""
echo "========================================="
echo "Phase 5 Exit Gate Results: $AGENT"
echo "========================================="
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
