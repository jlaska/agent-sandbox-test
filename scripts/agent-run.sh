#!/usr/bin/env bash
# agent-run — Trusted-host launcher for sandboxed agent sessions.
#
# Usage:
#   agent-run <owner/repo> <agent>
#   agent-run --diag                  # print diagnostic info
#   agent-run --list-repos            # list approved repos
#
# The launcher:
#   1. Validates the repository against an allowlist
#   2. Retrieves the GitHub App private key from macOS Keychain
#   3. Mints a fresh repository-scoped installation token
#   4. Creates/updates the OpenShell GitHub provider
#   5. Creates an ephemeral sandbox with security policy
#   6. Clones the repository and configures Git identity
#   7. Launches the requested agent
#   8. On exit: revokes token, deletes sandbox, cleans up

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_FILE="${REPO_ROOT}/openshell/sandbox-policy.yaml"
MINT_SCRIPT="${SCRIPT_DIR}/mint-token.sh"

APP_ID="4720923"
APP_SLUG="jlaska-agent"

PROVIDER_NAME="github-agent"
SANDBOX_PREFIX="agent"

GIT_USER="jlaska-agent[bot]"
GIT_EMAIL="jlaska-agent[bot]@users.noreply.github.com"

# Approved repositories
APPROVED_REPOS=(
    "jlaska/agent-sandbox-test"
)

# Supported agents
SUPPORTED_AGENTS="claude shell"

agent_command() {
    case "$1" in
        claude) echo "claude" ;;
        shell)  echo "bash" ;;
        *)      return 1 ;;
    esac
}

# --- State for cleanup ---
SANDBOX_NAME=""
MINTED_TOKEN=""
PROVIDER_CREATED=false

# --- Cleanup ---
cleanup() {
    local exit_code=$?
    echo ""
    echo "--- Cleanup ---"

    if [[ -n "$SANDBOX_NAME" ]]; then
        echo "  Deleting sandbox: $SANDBOX_NAME"
        openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
    fi

    if [[ -n "$MINTED_TOKEN" ]]; then
        echo "  Revoking installation token..."
        "$MINT_SCRIPT" --revoke "$MINTED_TOKEN" 2>/dev/null || true
        MINTED_TOKEN=""
    fi

    if [[ "$PROVIDER_CREATED" == "true" ]]; then
        echo "  Deleting provider: $PROVIDER_NAME"
        openshell provider delete "$PROVIDER_NAME" 2>/dev/null || true
        PROVIDER_CREATED=false
    fi

    echo "  Cleanup complete."
    exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

# --- Helpers ---
log()  { echo "[agent-run] $*"; }
err()  { echo "[agent-run] ERROR: $*" >&2; }
die()  { err "$@"; exit 1; }

is_approved_repo() {
    local repo="$1"
    for approved in "${APPROVED_REPOS[@]}"; do
        [[ "$repo" == "$approved" ]] && return 0
    done
    return 1
}

# --- Diagnostics ---
print_diagnostics() {
    echo "=== agent-run diagnostics ==="
    echo "  OpenShell version:  $(openshell --version 2>/dev/null || echo 'not found')"
    echo "  gh-token version:   $(gh extension list 2>/dev/null | grep token | awk '{print $3}' || echo 'not found')"
    echo "  GitHub App slug:    $APP_SLUG"
    echo "  GitHub App ID:      $APP_ID"
    echo "  Policy file:        $POLICY_FILE"
    echo "  Approved repos:     ${APPROVED_REPOS[*]}"
    echo "  Supported agents:   $SUPPORTED_AGENTS"
    echo ""
    echo "  Gateway status:"
    openshell status 2>&1 | sed 's/^/    /'
    echo ""
    echo "  Active sandboxes:"
    openshell sandbox list 2>&1 | sed 's/^/    /'
    echo ""
    echo "  Providers:"
    openshell provider list 2>&1 | sed 's/^/    /'
    echo ""
    echo "  NOTE: Diagnostics never print: private key, tokens, model API keys"
    exit 0
}

# --- Generate repo-specific policy ---
generate_policy() {
    local repo="$1"
    local owner="${repo%%/*}"
    local name="${repo##*/}"
    local tmpfile
    tmpfile=$(mktemp -t agent-run-policy.XXXXXX)

    sed \
        -e "s|jlaska/agent-sandbox-test|${owner}/${name}|g" \
        "$POLICY_FILE" > "$tmpfile"

    echo "$tmpfile"
}

# --- Main ---
case "${1:-}" in
    --diag|--diagnostics)
        print_diagnostics
        ;;
    --list-repos)
        echo "Approved repositories:"
        for repo in "${APPROVED_REPOS[@]}"; do
            echo "  $repo"
        done
        exit 0
        ;;
    --help|-h|"")
        echo "Usage: agent-run <owner/repo> <agent>"
        echo ""
        echo "  Agents:  $SUPPORTED_AGENTS"
        echo "  Repos:   ${APPROVED_REPOS[*]}"
        echo ""
        echo "  --diag        Print diagnostic info"
        echo "  --list-repos  List approved repositories"
        exit 0
        ;;
esac

REPO="${1:?Usage: agent-run <owner/repo> <agent>}"
AGENT="${2:?Usage: agent-run <owner/repo> <agent>}"

# Validate repo
is_approved_repo "$REPO" || die "Repository '$REPO' is not in the approved list. Use --list-repos."

# Validate agent
AGENT_CMD=$(agent_command "$AGENT") || die "Unknown agent '$AGENT'. Supported: $SUPPORTED_AGENTS"
SANDBOX_NAME="a-${AGENT}-$(date +%s | tail -c 6)"

log "Repository: $REPO"
log "Agent:      $AGENT"
log "Sandbox:    $SANDBOX_NAME"

# Step 1: Verify OpenShell gateway
log "Checking OpenShell gateway..."
openshell status >/dev/null 2>&1 || die "OpenShell gateway is not running. Start it first."

# Step 2: Mint installation token
log "Minting installation token..."
MINTED_TOKEN=$("$MINT_SCRIPT" --token-only 2>/dev/null) || die "Failed to mint token."
log "Token minted (expires in ~1 hour)."

# Step 3: Create/update provider
log "Creating GitHub provider..."
# Delete existing provider if present
openshell provider delete "$PROVIDER_NAME" 2>/dev/null || true
export GITHUB_TOKEN="$MINTED_TOKEN"
openshell provider create \
    --name "$PROVIDER_NAME" \
    --type github-agent \
    --credential "api_token=${MINTED_TOKEN}" \
    >/dev/null 2>&1 || die "Failed to create provider."
PROVIDER_CREATED=true
unset GITHUB_TOKEN
log "Provider '$PROVIDER_NAME' created."

# Step 4: Generate repo-specific policy
log "Generating sandbox policy for $REPO..."
POLICY_TMP=$(generate_policy "$REPO")
trap 'rm -f "$POLICY_TMP"; cleanup' EXIT INT TERM HUP

# Step 5: Create sandbox
log "Creating sandbox '$SANDBOX_NAME'..."
openshell sandbox create \
    --name "$SANDBOX_NAME" \
    --provider "$PROVIDER_NAME" \
    --policy "$POLICY_TMP" \
    --detach \
    2>&1 | grep -v "^$" || die "Failed to create sandbox."
rm -f "$POLICY_TMP"

# Wait for sandbox to be ready
WAIT_ATTEMPTS=0
SB_PHASE=""
while [[ $WAIT_ATTEMPTS -lt 30 ]]; do
    if openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME.*Ready"; then
        SB_PHASE="Ready"
        break
    fi
    sleep 1
    WAIT_ATTEMPTS=$((WAIT_ATTEMPTS + 1))
done
[[ "$SB_PHASE" == "Ready" ]] || die "Sandbox did not become ready within 30 seconds."
log "Sandbox ready."

# Step 6: Clone repository
log "Cloning $REPO..."
openshell sandbox exec -n "$SANDBOX_NAME" -- \
    git clone "https://github.com/${REPO}.git" /sandbox/repo \
    >/dev/null 2>&1 || die "Clone failed."

# Step 7: Configure Git identity
log "Configuring Git identity..."
openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c "
    cd /sandbox/repo
    git config user.name '$GIT_USER'
    git config user.email '$GIT_EMAIL'
    git config commit.gpgsign false
    git config tag.gpgsign false
    git config credential.helper '!f() { echo \"username=x-access-token\"; echo \"password=\${api_token}\"; }; f'
" >/dev/null 2>&1 || die "Git configuration failed."

# Step 8: Launch agent
log "Launching agent: $AGENT"
log "Working directory: /sandbox/repo"
echo "---"

openshell sandbox exec -n "$SANDBOX_NAME" --workdir /sandbox/repo -- \
    "$AGENT_CMD" || true

# Cleanup runs via trap
