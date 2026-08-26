#!/usr/bin/env bash
# agent-run — Trusted-host launcher for sandboxed agent sessions.
#
# Usage:
#   agent-run <owner/repo> <agent> [--max]
#   agent-run --diag                  # print diagnostic info
#   agent-run --list-repos            # list approved repos
#
# Supported agents: claude, pi, shell
#
# Inference auth modes (for claude/pi):
#   Default:  API key billing via LiteLLM proxy (ANTHROPIC_API_KEY)
#   --max:    Claude Max subscription via LiteLLM header forwarding
#
# The launcher:
#   1. Validates the repository against an allowlist
#   2. Retrieves the GitHub App private key from macOS Keychain
#   3. Mints a fresh repository-scoped installation token
#   4. Creates/updates the OpenShell GitHub provider
#   5. Creates inference provider for the agent (from Keychain)
#   6. Creates an ephemeral sandbox with security policy
#   7. Clones the repository and configures Git identity
#   8. Launches the requested agent
#   9. On exit: revokes token, deletes sandbox, cleans up

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_FILE="${REPO_ROOT}/openshell/sandbox-policy.yaml"
LITELLM_PROFILE="${REPO_ROOT}/openshell/litellm-inference-profile.yaml"
MINT_SCRIPT="${SCRIPT_DIR}/mint-token.sh"

APP_ID="4720923"
APP_SLUG="jlaska-agent"

GITHUB_PROVIDER_NAME="github-agent"
INFERENCE_PROVIDER_NAME="litellm-inference"

GIT_USER="jlaska-agent[bot]"
GIT_EMAIL="jlaska-agent[bot]@users.noreply.github.com"

# Approved repositories
APPROVED_REPOS=(
    "jlaska/agent-sandbox-test"
)

# Supported agents and their commands
SUPPORTED_AGENTS="claude pi shell"

agent_command() {
    case "$1" in
        claude) echo "claude" ;;
        pi)     echo "pi" ;;
        shell)  echo "bash" ;;
        *)      return 1 ;;
    esac
}

agent_needs_inference() {
    case "$1" in
        claude|pi) return 0 ;;
        *)         return 1 ;;
    esac
}

# --- Keychain helpers ---
keychain_get() {
    security find-generic-password -s "$1" -a "$USER" -w 2>/dev/null
}

keychain_exists() {
    security find-generic-password -s "$1" -a "$USER" >/dev/null 2>&1
}

# --- State for cleanup ---
SANDBOX_NAME=""
MINTED_TOKEN=""
PROVIDERS_CREATED=()
POLICY_TMP=""

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

    for prov in "${PROVIDERS_CREATED[@]}"; do
        echo "  Deleting provider: $prov"
        openshell provider delete "$prov" 2>/dev/null || true
    done

    [[ -n "$POLICY_TMP" ]] && rm -f "$POLICY_TMP"

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
    echo "  Keychain credentials:"
    for svc in github-app-jlaska-agent litellm-api-key litellm-bearer-token anthropic-base-url; do
        keychain_exists "$svc" && echo "    $svc: present" || echo "    $svc: MISSING"
    done
    echo ""
    echo "  Installed agents (host):"
    for cmd in claude pi codex; do
        printf "    %-8s: " "$cmd"
        which "$cmd" 2>/dev/null && true || echo "not found"
    done
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

# --- Create inference provider ---
create_inference_provider() {
    local agent="$1"
    log "Creating inference provider (LiteLLM)..."

    keychain_exists "litellm-api-key" || die "Missing Keychain: litellm-api-key"
    keychain_exists "anthropic-base-url" || die "Missing Keychain: anthropic-base-url"

    local api_key
    api_key=$(keychain_get "litellm-api-key") || die "Failed to read litellm-api-key."

    # Import profile if needed
    if ! openshell provider list-profiles 2>/dev/null | grep -q "litellm-inference"; then
        openshell provider profile import --file "$LITELLM_PROFILE" \
            >/dev/null 2>&1 || die "Failed to import LiteLLM provider profile."
        log "  Imported litellm-inference profile."
    fi

    # For Claude Code, also create the builtin claude-code provider (required by auto-detection)
    if [[ "$agent" == "claude" ]]; then
        openshell provider delete claude-code 2>/dev/null || true
        openshell provider create \
            --name claude-code \
            --type claude-code \
            --credential "api_key=${api_key}" \
            >/dev/null 2>&1 || die "Failed to create claude-code provider."
        PROVIDERS_CREATED+=("claude-code")
        log "  Provider 'claude-code' created."
    fi

    # Create the LiteLLM inference provider (for network policy)
    local bearer_token=""
    if keychain_exists "litellm-bearer-token"; then
        bearer_token=$(keychain_get "litellm-bearer-token") || true
    fi

    openshell provider delete "$INFERENCE_PROVIDER_NAME" 2>/dev/null || true
    if [[ -n "$bearer_token" ]]; then
        openshell provider create \
            --name "$INFERENCE_PROVIDER_NAME" \
            --type litellm-inference \
            --credential "litellm_api_key=${api_key}" \
            --credential "litellm_bearer_token=${bearer_token}" \
            >/dev/null 2>&1 || die "Failed to create inference provider."
    else
        openshell provider create \
            --name "$INFERENCE_PROVIDER_NAME" \
            --type litellm-inference \
            --credential "litellm_api_key=${api_key}" \
            --credential "litellm_bearer_token=unused" \
            >/dev/null 2>&1 || die "Failed to create inference provider."
    fi
    PROVIDERS_CREATED+=("$INFERENCE_PROVIDER_NAME")
    log "  Provider '$INFERENCE_PROVIDER_NAME' created."
}

# --- Build sandbox env flags ---
build_env_flags() {
    local agent="$1"
    local use_max="$2"
    local env_flags=""

    local base_url
    base_url=$(keychain_get "anthropic-base-url") || die "Failed to read anthropic-base-url."

    case "$agent" in
        claude)
            # ANTHROPIC_API_KEY is set to a deferred reference that the sandbox init
            # resolves to the litellm_api_key provider placeholder. The gateway then
            # injects the real credential in the x-api-key HTTP header.
            env_flags="--env ANTHROPIC_API_KEY=__LITELLM_PLACEHOLDER__"
            env_flags="$env_flags --env ANTHROPIC_BASE_URL=${base_url}"
            env_flags="$env_flags --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=0"

            if [[ "$use_max" == "true" ]]; then
                keychain_exists "litellm-bearer-token" || die "Missing Keychain: litellm-bearer-token (required for --max)"
                local bearer
                bearer=$(keychain_get "litellm-bearer-token")
                env_flags="$env_flags --env ANTHROPIC_CUSTOM_HEADERS=x-litellm-api-key:\ Bearer\ ${bearer}"
                log "  Max subscription mode: custom headers configured."
            fi
            ;;
        pi)
            env_flags="--env LITELLM_BASE_URL=${base_url}"
            ;;
    esac

    echo "$env_flags"
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
        echo "Usage: agent-run <owner/repo> <agent> [--max]"
        echo ""
        echo "  Agents:  $SUPPORTED_AGENTS"
        echo "  Repos:   ${APPROVED_REPOS[*]}"
        echo ""
        echo "  --max         Use Claude Max subscription (header forwarding) instead of API key billing"
        echo "  --diag        Print diagnostic info"
        echo "  --list-repos  List approved repositories"
        exit 0
        ;;
esac

REPO="${1:?Usage: agent-run <owner/repo> <agent> [--max]}"
AGENT="${2:?Usage: agent-run <owner/repo> <agent> [--max]}"
USE_MAX="false"
[[ "${3:-}" == "--max" ]] && USE_MAX="true"

# Validate repo
is_approved_repo "$REPO" || die "Repository '$REPO' is not in the approved list. Use --list-repos."

# Validate agent
AGENT_CMD=$(agent_command "$AGENT") || die "Unknown agent '$AGENT'. Supported: $SUPPORTED_AGENTS"
SANDBOX_NAME="a-${AGENT}-$(date +%s | tail -c 6)"

log "Repository: $REPO"
log "Agent:      $AGENT"
log "Sandbox:    $SANDBOX_NAME"
[[ "$USE_MAX" == "true" ]] && log "Mode:       Max subscription (header forwarding)"

# Step 1: Verify OpenShell gateway
log "Checking OpenShell gateway..."
openshell status >/dev/null 2>&1 || die "OpenShell gateway is not running. Start it first."

# Step 2: Mint GitHub installation token
log "Minting installation token..."
MINTED_TOKEN=$("$MINT_SCRIPT" --token-only 2>/dev/null) || die "Failed to mint token."
log "Token minted (expires in ~1 hour)."

# Step 3: Create GitHub provider
log "Creating GitHub provider..."
openshell provider delete "$GITHUB_PROVIDER_NAME" 2>/dev/null || true
openshell provider create \
    --name "$GITHUB_PROVIDER_NAME" \
    --type github-agent \
    --credential "api_token=${MINTED_TOKEN}" \
    >/dev/null 2>&1 || die "Failed to create GitHub provider."
PROVIDERS_CREATED+=("$GITHUB_PROVIDER_NAME")
log "Provider '$GITHUB_PROVIDER_NAME' created."

# Step 4: Create inference provider(s)
PROVIDER_FLAGS="--provider $GITHUB_PROVIDER_NAME"
if agent_needs_inference "$AGENT"; then
    create_inference_provider "$AGENT"
    PROVIDER_FLAGS="$PROVIDER_FLAGS --provider $INFERENCE_PROVIDER_NAME"
    [[ "$AGENT" == "claude" ]] && PROVIDER_FLAGS="$PROVIDER_FLAGS --provider claude-code"
fi

# Step 5: Build env flags
ENV_FLAGS=""
if agent_needs_inference "$AGENT"; then
    ENV_FLAGS=$(build_env_flags "$AGENT" "$USE_MAX")
fi

# Step 6: Generate repo-specific policy
log "Generating sandbox policy for $REPO..."
POLICY_TMP=$(generate_policy "$REPO")

# Step 7: Create sandbox
log "Creating sandbox '$SANDBOX_NAME'..."
eval openshell sandbox create \
    --name "$SANDBOX_NAME" \
    $PROVIDER_FLAGS \
    --policy "$POLICY_TMP" \
    $ENV_FLAGS \
    --detach \
    2>&1 | grep -v "^$" || die "Failed to create sandbox."
rm -f "$POLICY_TMP"
POLICY_TMP=""

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

# Step 8: Agent-specific sandbox setup
case "$AGENT" in
    claude)
        # Resolve ANTHROPIC_API_KEY to the litellm_api_key provider placeholder.
        # This lets Claude Code activate API key mode while the gateway injects
        # the real credential at the HTTP level.
        openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c '
            echo "export ANTHROPIC_API_KEY=\"\$litellm_api_key\"" >> ~/.bashrc
            echo "export ANTHROPIC_API_KEY=\"\$litellm_api_key\"" >> ~/.profile
        ' >/dev/null 2>&1
        log "  ANTHROPIC_API_KEY mapped to provider placeholder."
        ;;
    pi)
        log "Installing Pi in sandbox..."
        openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c '
            mkdir -p /sandbox/.npm-global
            npm config set prefix /sandbox/.npm-global
            npm install -g @earendil-works/pi-coding-agent
        ' 2>&1 | tail -3 || log "  WARNING: Pi npm install may have failed."
        # Add Pi to PATH and configure LiteLLM credentials
        openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c '
            echo "export PATH=\"/sandbox/.npm-global/bin:\$PATH\"" >> ~/.bashrc
            echo "export PATH=\"/sandbox/.npm-global/bin:\$PATH\"" >> ~/.profile
            echo "export LITELLM_API_KEY=\"\$litellm_api_key\"" >> ~/.bashrc
            echo "export LITELLM_API_KEY=\"\$litellm_api_key\"" >> ~/.profile
        ' >/dev/null 2>&1
        ;;
esac

# Step 9: Clone repository
log "Cloning $REPO..."
openshell sandbox exec -n "$SANDBOX_NAME" -- \
    git clone "https://github.com/${REPO}.git" /sandbox/repo \
    >/dev/null 2>&1 || die "Clone failed."

# Step 10: Configure Git identity
log "Configuring Git identity..."
openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c "
    cd /sandbox/repo
    git config user.name '$GIT_USER'
    git config user.email '$GIT_EMAIL'
    git config commit.gpgsign false
    git config tag.gpgsign false
    git config credential.helper '!f() { echo \"username=x-access-token\"; echo \"password=\${api_token}\"; }; f'
" >/dev/null 2>&1 || die "Git configuration failed."

# Step 11: Launch agent
log "Launching agent: $AGENT"
log "Working directory: /sandbox/repo"
echo "---"

openshell sandbox exec -n "$SANDBOX_NAME" --workdir /sandbox/repo -- \
    bash -c "source ~/.profile 2>/dev/null; export GH_TOKEN=\$api_token; exec $AGENT_CMD" || true

# Cleanup runs via trap
