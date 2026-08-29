#!/usr/bin/env bash
# Security acceptance-test suite for agent GitHub App / OpenShell sandbox.
#
# Usage:
#   ./tests/security-acceptance.sh [--repo OWNER/REPO] [--clone-dir DIR]
#
# Prerequisites:
#   - Authenticated as the GitHub App installation (not the human user).
#   - The target repo must have seed content on main.
#   - GitHub rulesets must be configured before negative tests pass.
#
# Each test prints PASS/FAIL/SKIP and the suite exits non-zero if any
# expected-PASS fails or any expected-FAIL succeeds.

set -euo pipefail

REPO="${REPO:-jlaska/agent-sandbox-test}"
CLONE_DIR=""
CLEANUP_CLONE=false
PASS=0
ERRORS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --clone-dir) CLONE_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }

record_pass() { green "  PASS: $1"; ((PASS++)); }
record_fail() { red   "  FAIL: $1"; ((ERRORS++)); }
record_skip() { yellow "  SKIP: $1"; }

# expect_success: command should succeed
expect_success() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        record_pass "$label"
    else
        record_fail "$label (expected success, got failure)"
    fi
}

# expect_failure: command should fail
expect_failure() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        record_fail "$label (expected failure, got success)"
    else
        record_pass "$label"
    fi
}

echo "=== Security Acceptance Tests ==="
echo "Repository: $REPO"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# --- Section 1: Clone / Fetch ---
echo "--- Clone and Fetch ---"

if [[ -z "$CLONE_DIR" ]]; then
    CLONE_DIR=$(mktemp -d)
    CLEANUP_CLONE=true
fi

if git clone "https://github.com/${REPO}.git" "$CLONE_DIR/repo" 2>/dev/null; then
    record_pass "Clone approved repository via HTTPS"
    cd "$CLONE_DIR/repo"

    # Configure sandbox-local identity
    git config user.name "jlaska-agent[bot]"
    git config user.email "jlaska-agent[bot]@users.noreply.github.com"
    git config commit.gpgsign false
    git config tag.gpgsign false
else
    record_fail "Clone approved repository via HTTPS"
    echo "Cannot continue without a clone. Exiting."
    exit 1
fi

expect_success "Fetch approved repository" git fetch origin

# --- Section 2: Branch push (allowed) ---
echo ""
echo "--- Allowed branch pushes ---"

BRANCH_FLAT="agent/test-$(date +%s)"
BRANCH_NESTED="agent/claude/test-$(date +%s)"
BRANCH_DEEP="agent/tasks/123/fix-$(date +%s)"

for branch in "$BRANCH_FLAT" "$BRANCH_NESTED" "$BRANCH_DEEP"; do
    git checkout -b "$branch" origin/main 2>/dev/null
    echo "test: $branch" >> sandbox-test.txt
    git add sandbox-test.txt
    git commit -m "test: push $branch" --no-gpg-sign 2>/dev/null
    expect_success "Push $branch" git push origin "$branch"
    git checkout main 2>/dev/null
done

# --- Section 3: Branch push (denied) ---
echo ""
echo "--- Denied branch pushes ---"

for forbidden in "main" "feature/foo" "release/foo"; do
    if [[ "$forbidden" == "main" ]]; then
        # Try pushing a new commit to main
        git checkout main 2>/dev/null
        echo "forbidden" >> sandbox-test.txt
        git add sandbox-test.txt
        git commit -m "test: forbidden push to $forbidden" --no-gpg-sign 2>/dev/null
        expect_failure "Push $forbidden" git push origin main
        git reset --hard origin/main 2>/dev/null
    else
        git checkout -b "$forbidden" origin/main 2>/dev/null
        echo "forbidden" >> sandbox-test.txt
        git add sandbox-test.txt
        git commit -m "test: forbidden push to $forbidden" --no-gpg-sign 2>/dev/null
        expect_failure "Push $forbidden" git push origin "$forbidden"
        git checkout main 2>/dev/null
    fi
done

# --- Section 4: Tag operations (denied) ---
echo ""
echo "--- Denied tag operations ---"

git tag "test-tag-$(date +%s)" 2>/dev/null
expect_failure "Create tag" git push origin --tags

# --- Section 5: Force push / delete protected ref (denied) ---
echo ""
echo "--- Denied destructive operations ---"

expect_failure "Force-push main" git push --force origin main
expect_failure "Delete main" git push origin --delete main

# --- Section 6: PR operations (allowed) ---
echo ""
echo "--- PR operations ---"

PR_BRANCH="agent/pr-test-$(date +%s)"
git checkout -b "$PR_BRANCH" origin/main 2>/dev/null
echo "PR test content" >> sandbox-test.txt
git add sandbox-test.txt
git commit -m "test: PR creation" --no-gpg-sign 2>/dev/null
git push origin "$PR_BRANCH" 2>/dev/null

PR_URL=$(gh pr create --repo "$REPO" --base main --head "$PR_BRANCH" \
    --title "Test PR (auto-cleanup)" --body "Automated security test PR." 2>/dev/null || true)

if [[ -n "$PR_URL" ]]; then
    record_pass "Create PR"
    PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')

    expect_success "Comment on PR" \
        gh pr comment "$PR_NUMBER" --repo "$REPO" --body "Automated test comment."

    expect_success "Read PR checks" \
        gh pr checks "$PR_NUMBER" --repo "$REPO"

    # --- Section 7: Merge (denied) ---
    echo ""
    echo "--- Denied merge operations ---"

    expect_failure "gh pr merge" \
        gh pr merge "$PR_NUMBER" --repo "$REPO" --merge --yes

    expect_failure "REST merge endpoint" \
        gh api "repos/$REPO/pulls/$PR_NUMBER/merge" -X PUT \
            -f merge_method=merge -f commit_title="forbidden merge"

    expect_failure "GraphQL mergePullRequest" \
        gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"$(gh pr view "$PR_NUMBER" --repo "$REPO" --json id -q .id)\"}) { pullRequest { number } } }"

    expect_failure "GraphQL enablePullRequestAutoMerge" \
        gh api graphql -f query="mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"$(gh pr view "$PR_NUMBER" --repo "$REPO" --json id -q .id)\"}) { pullRequest { number } } }"

    # Cleanup: close the test PR
    gh pr close "$PR_NUMBER" --repo "$REPO" --delete-branch 2>/dev/null || true
else
    record_skip "PR operations (could not create PR)"
    record_skip "Merge denial tests (no PR)"
fi

# --- Section 8: Unapproved repo access (denied) ---
echo ""
echo "--- Unapproved repository access ---"

# jlaska/agent-sandbox-denied is a permanent canary repo that must NEVER
# be installed on the jlaska-agent GitHub App.
expect_failure "Clone unapproved private repo (canary)" \
    git clone "https://github.com/jlaska/agent-sandbox-denied.git" "$CLONE_DIR/unapproved" 2>/dev/null

# --- Section 9: No YubiKey involvement ---
echo ""
echo "--- YubiKey non-involvement ---"
echo "  (Manual verification: no YubiKey touch was required during this run)"

# --- Cleanup ---
echo ""
echo "--- Cleanup ---"

# Remove test branches
for branch in "$BRANCH_FLAT" "$BRANCH_NESTED" "$BRANCH_DEEP"; do
    git push origin --delete "$branch" 2>/dev/null || true
done

if [[ "$CLEANUP_CLONE" == "true" ]]; then
    rm -rf "$CLONE_DIR"
    echo "  Cleaned up temp clone directory."
fi

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $ERRORS"
echo "  Date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

if [[ $ERRORS -gt 0 ]]; then
    red "RESULT: $ERRORS test(s) did not meet expected outcome."
    exit 1
else
    green "RESULT: All tests passed."
    exit 0
fi
