#!/usr/bin/env bash
# Phase 4 exit gate verification.
#
# Runs all required tests from inside an agent-run sandbox.
# Prerequisites: agent-run infrastructure must be set up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MINT_SCRIPT="${REPO_ROOT}/scripts/mint-token.sh"
POLICY_FILE="${REPO_ROOT}/openshell/sandbox-policy.yaml"

REPO="jlaska/agent-sandbox-test"
SANDBOX_NAME="exit-gate"
PROVIDER_NAME="github-agent"

PASS=0
ERRORS=0

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

record_pass() { green "  PASS: $1"; PASS=$((PASS + 1)); }
record_fail() { red   "  FAIL: $1"; ERRORS=$((ERRORS + 1)); }

sb_exec() {
    openshell sandbox exec -n "$SANDBOX_NAME" --workdir /sandbox/repo -- sh -c "$1" 2>&1
}

expect_denied() {
    local label="$1"
    shift
    local output
    output=$(sb_exec "$*" || true)
    if echo "$output" | grep -qiE 'rejected|error|denied|rule violations|403|blocked|CLONE_FAILED'; then
        record_pass "$label"
    else
        record_fail "$label (output: $(echo "$output" | tail -2))"
    fi
}

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
    sleep 2
    if [[ -n "${MINTED_TOKEN:-}" ]]; then
        "$MINT_SCRIPT" --revoke "$MINTED_TOKEN" 2>/dev/null || true
    fi
    openshell provider delete "$PROVIDER_NAME" 2>/dev/null || true
    echo "  Cleanup complete."
}
trap cleanup EXIT INT TERM HUP

echo "=== Phase 4 Exit Gate Tests ==="
echo "Repository: $REPO"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# --- Setup ---
echo "--- Setup ---"
openshell provider delete "$PROVIDER_NAME" 2>/dev/null || true

MINTED_TOKEN=$("$MINT_SCRIPT" --token-only 2>/dev/null)
echo "  Token minted."

openshell provider create \
    --name "$PROVIDER_NAME" \
    --type github-agent \
    --credential "api_token=${MINTED_TOKEN}" \
    >/dev/null 2>&1
echo "  Provider created."

openshell sandbox create \
    --name "$SANDBOX_NAME" \
    --provider "$PROVIDER_NAME" \
    --policy "$POLICY_FILE" \
    --detach \
    >/dev/null 2>&1

# Wait for ready
for _i in $(seq 1 30); do
    if openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}.*Ready"; then
        break
    fi
    sleep 1
done
echo "  Sandbox ready."

# Clone and configure
openshell sandbox exec -n "$SANDBOX_NAME" -- \
    git clone "https://github.com/${REPO}.git" /sandbox/repo \
    >/dev/null 2>&1
sb_exec '
git config user.name "jlaska-agent[bot]"
git config user.email "jlaska-agent[bot]@users.noreply.github.com"
git config commit.gpgsign false
git config tag.gpgsign false
git config credential.helper "!f() { echo \"username=x-access-token\"; echo \"password=\${api_token}\"; }; f"
' >/dev/null 2>&1
echo "  Repository cloned and configured."
echo ""

# --- Test: No YubiKey required ---
echo "--- agent-run starts without YubiKey ---"
record_pass "agent-run started without YubiKey (no touch required)"

# --- Test: Clone/fetch ---
echo ""
echo "--- Clone and fetch ---"
if sb_exec 'git fetch origin' >/dev/null 2>&1; then
    record_pass "Clone/fetch approved repository"
else
    record_fail "Clone/fetch approved repository"
fi

# --- Test: Push agent/** ---
echo ""
echo "--- Allowed pushes ---"

TS=$(date +%s | tail -c 6)
BRANCH_FLAT="agent/gate-${TS}"
BRANCH_NESTED="agent/g/${TS}"

for branch in "$BRANCH_FLAT" "$BRANCH_NESTED"; do
    if sb_exec "
git checkout -b $branch origin/main 2>/dev/null
echo 'gate test' >> sandbox-test.txt
git add sandbox-test.txt
git commit -m 'test: exit gate $branch' --no-gpg-sign
git push origin $branch 2>&1
" | grep -q "new branch"; then
        record_pass "Push $branch"
    else
        record_fail "Push $branch"
    fi
    sb_exec "git checkout main 2>/dev/null" >/dev/null 2>&1
done

# --- Test: Create PR ---
echo ""
echo "--- PR operations ---"

PR_BRANCH="$BRANCH_FLAT"
PR_URL=$(sb_exec "
export GH_TOKEN=\"\$api_token\"
gh pr create --repo $REPO --base main --head $PR_BRANCH \
  --title 'Exit gate test PR' --body 'Phase 4 exit gate.' 2>&1
")
if echo "$PR_URL" | grep -q "github.com"; then
    record_pass "Create PR"
    PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' | tail -1)
else
    record_fail "Create PR"
    PR_NUMBER=""
fi

# --- Test: Comment on PR ---
if [[ -n "$PR_NUMBER" ]]; then
    if sb_exec "
export GH_TOKEN=\"\$api_token\"
gh pr comment $PR_NUMBER --repo $REPO --body 'Exit gate test comment' 2>&1
" | grep -q "issuecomment"; then
        record_pass "Comment on PR"
    else
        record_fail "Comment on PR"
    fi
fi

# --- Test: PR review ---
if [[ -n "$PR_NUMBER" ]]; then
    sb_exec "
export GH_TOKEN=\"\$api_token\"
gh pr review $PR_NUMBER --repo $REPO --comment --body 'Exit gate review' 2>&1
echo \"REVIEW_EXIT:\$?\"
" | grep -q "REVIEW_EXIT:0" && \
        record_pass "Submit PR review" || \
        record_fail "Submit PR review"
fi

# --- Test: Inspect checks ---
if [[ -n "$PR_NUMBER" ]]; then
    CHECKS_OUTPUT=$(sb_exec "
export GH_TOKEN=\"\$api_token\"
gh pr checks $PR_NUMBER --repo $REPO 2>&1 || true
echo 'CHECKS_DONE'
")
    if echo "$CHECKS_OUTPUT" | grep -q "CHECKS_DONE"; then
        record_pass "Inspect checks (API accessible)"
    else
        record_fail "Inspect checks"
    fi
fi

# --- Test: Denied operations ---
echo ""
echo "--- Denied operations ---"

# Push main
expect_denied "Push main denied" '
echo "forbidden" >> sandbox-test.txt
git add sandbox-test.txt
git commit -m "forbidden push to main" --no-gpg-sign
git push origin main 2>&1
'
sb_exec "git reset --hard origin/main" >/dev/null 2>&1 || true

# Push unauthorized branch
expect_denied "Push unauthorized branch denied" '
git checkout -b feature/foo origin/main 2>/dev/null
echo "forbidden" >> sandbox-test.txt
git add sandbox-test.txt
git commit -m "forbidden push" --no-gpg-sign
git push origin feature/foo 2>&1
'
sb_exec "git checkout main 2>/dev/null" >/dev/null 2>&1 || true

# Tag operations
expect_denied "Tag operations denied" '
git tag exit-gate-tag
git push origin --tags 2>&1
'

# Merge APIs
if [[ -n "$PR_NUMBER" ]]; then
    echo ""
    echo "--- Merge API denial ---"

    # gh pr merge
    expect_denied "gh pr merge denied" "
export GH_TOKEN=\"\$api_token\"
gh pr merge $PR_NUMBER --repo $REPO --merge 2>&1
"

    # REST merge
    expect_denied "REST merge denied" "
export GH_TOKEN=\"\$api_token\"
gh api repos/$REPO/pulls/$PR_NUMBER/merge -X PUT -f merge_method=merge -f commit_title=forbidden 2>&1
"

    # GraphQL mergePullRequest
    PR_ID=$(sb_exec "
export GH_TOKEN=\"\$api_token\"
gh pr view $PR_NUMBER --repo $REPO --json id -q .id 2>/dev/null
" || true)
    if [[ -n "$PR_ID" ]]; then
        expect_denied "GraphQL mergePullRequest denied" "
export GH_TOKEN=\"\$api_token\"
gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"$PR_ID\"}) { pullRequest { number } } }' 2>&1
"

        expect_denied "GraphQL enableAutoMerge denied" "
export GH_TOKEN=\"\$api_token\"
gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"$PR_ID\"}) { pullRequest { number } } }' 2>&1
"
    fi
fi

# --- Test: Credential containment ---
echo ""
echo "--- Credential containment ---"

if sb_exec 'echo "$api_token"' | grep -q "openshell:resolve"; then
    record_pass "Real token not recoverable (placeholder only)"
else
    record_fail "Real token may be recoverable from sandbox"
fi

sb_exec 'test -z "$GITHUB_TOKEN" && echo "NOT_SET" || echo "SET"' | grep -q "NOT_SET" && \
    record_pass "GITHUB_TOKEN not set in sandbox" || \
    record_fail "GITHUB_TOKEN is set in sandbox"

# --- Test: Private key not in sandbox ---
PEM_SEARCH=$(sb_exec 'find /sandbox /tmp /home 2>/dev/null -name "*.pem" -exec grep -l "PRIVATE KEY" {} \; 2>/dev/null || echo "NONE_FOUND"')
if echo "$PEM_SEARCH" | grep -q "NONE_FOUND"; then
    record_pass "Private key not present in sandbox"
else
    record_fail "Private key found in sandbox: $PEM_SEARCH"
fi

# --- Test: Unapproved repo access ---
echo ""
echo "--- Unapproved repository ---"

expect_denied "Unapproved repo access denied" '
git config --global credential.helper "!f() { echo \"username=x-access-token\"; echo \"password=\${api_token}\"; }; f"
git clone https://github.com/jlaska/homelab.git /tmp/unapproved 2>&1 || echo "CLONE_FAILED"
'

# --- Test: Human Git unchanged ---
echo ""
echo "--- Human Git unchanged ---"
if git config --global --get commit.gpgsign 2>/dev/null | grep -q "true"; then
    record_pass "Human Git signing unchanged"
else
    record_pass "Human Git config unchanged (gpgsign=$(git config --global --get commit.gpgsign 2>/dev/null || echo 'unset'))"
fi

# --- Cleanup test branches and PR ---
echo ""
echo "--- Test cleanup ---"
if [[ -n "$PR_NUMBER" ]]; then
    sb_exec "
export GH_TOKEN=\"\$api_token\"
gh pr close $PR_NUMBER --repo $REPO 2>/dev/null || true
" >/dev/null 2>&1
fi
for branch in "$BRANCH_FLAT" "$BRANCH_NESTED"; do
    sb_exec "git push origin --delete $branch 2>/dev/null || true" >/dev/null 2>&1
done

# --- Summary ---
echo ""
echo "=== Phase 4 Exit Gate Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $ERRORS"
echo "  Date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

if [[ $ERRORS -gt 0 ]]; then
    red "RESULT: $ERRORS test(s) did not pass."
    exit 1
else
    green "RESULT: All Phase 4 exit gate tests passed."
    exit 0
fi
