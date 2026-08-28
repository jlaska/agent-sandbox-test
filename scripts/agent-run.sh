#!/usr/bin/env bash
# agent-run — Trusted-host launcher for sandboxed agent sessions.
#
# Usage:
#   agent-run <owner/repo> <harness> [--provider <provider>] [--model <model>] [--max]
#   agent-run --diag
#   agent-run --list-repos
#
# Harnesses (the agent binary):
#   claude    Claude Code CLI
#   pi        Pi coding agent
#   shell     Interactive bash
#
# Inference providers (where model calls go):
#   litellm   LiteLLM proxy at litellm.internal.keener.us (default)
#   vertex    Direct Google Vertex AI via gcloud ADC
#   api       Direct Anthropic API (api.anthropic.com)
#
# Not every harness supports every provider:
#
#   Harness  | litellm | vertex | api  | none
#   ---------+---------+--------+------+------
#   claude   |   ✓     |   ✓    |  ✓   |
#   pi       |   ✓     |        |      |
#   shell    |         |        |      |  ✓
#
# Flags:
#   --model   Override the default model (passed to the harness CLI)
#   --max     Claude Max subscription via LiteLLM header forwarding
#             (only valid with --provider litellm, which is the default)
#
# The launcher:
#   1. Validates the repository against an allowlist
#   2. Mints a fresh repository-scoped GitHub installation token
#   3. Creates OpenShell GitHub provider
#   4. Creates inference provider(s) for the selected backend
#   5. Creates an ephemeral sandbox with security policy
#   6. Clones the repository and configures Git identity
#   7. Launches the requested agent
#   8. On exit: revokes token, deletes sandbox, cleans up

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

GIT_USER="jlaska-agent[bot]"
GIT_EMAIL="jlaska-agent[bot]@users.noreply.github.com"

APPROVED_REPOS=(
    "jlaska/agent-sandbox-test"
)

# --- Harness definitions ---
SUPPORTED_HARNESSES="claude pi shell"

harness_command() {
    case "$1" in
        claude) echo "claude" ;;
        pi)     echo "pi" ;;
        shell)  echo "bash" ;;
        *)      return 1 ;;
    esac
}

harness_needs_inference() {
    case "$1" in
        claude|pi) return 0 ;;
        *)         return 1 ;;
    esac
}

harness_default_provider() {
    case "$1" in
        claude|pi) echo "litellm" ;;
        shell)     echo "none" ;;
    esac
}

harness_supports_provider() {
    local harness="$1" provider="$2"
    case "${harness}:${provider}" in
        claude:litellm|claude:vertex|claude:api) return 0 ;;
        pi:litellm)                              return 0 ;;
        shell:none|shell:litellm)                 return 0 ;;
        *)                                       return 1 ;;
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

CLEANED_UP=false
cleanup() {
    [[ "$CLEANED_UP" == "true" ]] && return
    CLEANED_UP=true
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

    for prov in "${PROVIDERS_CREATED[@]+"${PROVIDERS_CREATED[@]}"}"; do
        echo "  Deleting provider: $prov"
        openshell provider delete "$prov" 2>/dev/null || true
    done

    [[ -n "$POLICY_TMP" ]] && rm -f "$POLICY_TMP"

    echo "  Cleanup complete."
    exit "$exit_code"
}
trap cleanup EXIT

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
    echo "  Supported harnesses: $SUPPORTED_HARNESSES"
    echo ""
    echo "  Keychain credentials:"
    for svc in github-app-jlaska-agent litellm-api-key litellm-bearer-token anthropic-base-url anthropic-vertex-project-id; do
        keychain_exists "$svc" && echo "    $svc: present" || echo "    $svc: MISSING"
    done
    echo ""
    echo "  gcloud ADC:"
    [[ -f ~/.config/gcloud/application_default_credentials.json ]] \
        && echo "    ADC file: present" || echo "    ADC file: MISSING"
    echo ""
    echo "  Installed agents (host):"
    for cmd in claude pi codex; do
        printf "    %-8s: " "$cmd"
        which "$cmd" 2>/dev/null && true || echo "not found"
    done
    echo ""
    echo "  Provider compatibility matrix:"
    echo "    claude:  litellm (default), vertex, api"
    echo "    pi:      litellm (default)"
    echo "    shell:   none"
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

# ========================================================================
#  Inference provider setup — one function per provider
# ========================================================================

setup_provider_litellm() {
    local harness="$1" use_max="$2"
    log "Inference provider: litellm"

    keychain_exists "litellm-api-key" || die "Missing Keychain: litellm-api-key"
    keychain_exists "anthropic-base-url" || die "Missing Keychain: anthropic-base-url"

    local api_key base_url
    api_key=$(keychain_get "litellm-api-key")
    base_url=$(keychain_get "anthropic-base-url")

    # Import custom profile if needed (avoid pipefail + grep -q SIGPIPE)
    local profile_check
    profile_check=$(openshell provider list-profiles 2>/dev/null | grep "litellm-inference" || true)
    if [[ -z "$profile_check" ]]; then
        openshell provider profile import --file "$LITELLM_PROFILE" \
            >/dev/null 2>&1 || die "Failed to import LiteLLM provider profile."
    fi

    # LiteLLM inference provider (gateway credential injection for litellm.internal.keener.us)
    local bearer_token=""
    keychain_exists "litellm-bearer-token" && bearer_token=$(keychain_get "litellm-bearer-token")

    openshell provider delete litellm-inference 2>/dev/null || true
    openshell provider create \
        --name litellm-inference \
        --type litellm-inference \
        --credential "litellm_api_key=${api_key}" \
        --credential "litellm_api_key_bearer=${api_key}" \
        --credential "litellm_bearer_token=${bearer_token:-unused}" \
        >/dev/null 2>&1 || die "Failed to create litellm-inference provider."
    PROVIDERS_CREATED+=("litellm-inference")
    PROVIDER_FLAGS="$PROVIDER_FLAGS --provider litellm-inference"

    # The claude-code provider handles Anthropic API credential injection
    # (x-api-key header). Required for any harness that sends Anthropic-style
    # requests through the LiteLLM proxy (Claude Code, Pi, etc.).
    openshell provider delete claude-code 2>/dev/null || true
    openshell provider create \
        --name claude-code \
        --type claude-code \
        --credential "api_key=${api_key}" \
        >/dev/null 2>&1 || die "Failed to create claude-code provider."
    PROVIDERS_CREATED+=("claude-code")
    PROVIDER_FLAGS="$PROVIDER_FLAGS --provider claude-code"

    # Env flags
    case "$harness" in
        claude)
            # ANTHROPIC_API_KEY placeholder activates API key mode; resolved to
            # the litellm_api_key provider placeholder at sandbox init.
            ENV_FLAGS="$ENV_FLAGS --env ANTHROPIC_API_KEY=__LITELLM_PLACEHOLDER__"
            ENV_FLAGS="$ENV_FLAGS --env ANTHROPIC_BASE_URL=${base_url}"
            ENV_FLAGS="$ENV_FLAGS --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=0"

            if [[ "$use_max" == "true" ]]; then
                [[ -n "$bearer_token" ]] || die "Missing Keychain: litellm-bearer-token (required for --max)"
                ENV_FLAGS="$ENV_FLAGS --env ANTHROPIC_CUSTOM_HEADERS=x-litellm-api-key:\ Bearer\ ${bearer_token}"
                log "  Max subscription mode enabled."
            fi
            ;;
        pi)
            ENV_FLAGS="$ENV_FLAGS --env LITELLM_BASE_URL=${base_url}"
            ;;
    esac

    # Sandbox init hook
    SANDBOX_INIT_HOOK="setup_sandbox_litellm"
}

setup_sandbox_litellm() {
    local harness="$1"
    case "$harness" in
        claude)
            openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c '
                echo "export ANTHROPIC_API_KEY=\"\$litellm_api_key\"" >> ~/.bashrc
                echo "export ANTHROPIC_API_KEY=\"\$litellm_api_key\"" >> ~/.profile
            ' >/dev/null 2>&1
            log "  ANTHROPIC_API_KEY mapped to litellm_api_key placeholder."
            ;;
        pi)
            # LITELLM_API_KEY → litellm_api_key_bearer placeholder
            # Gateway resolves in Authorization: Bearer header for pi-provider-litellm
            openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c '
                echo "export LITELLM_API_KEY=\"\$litellm_api_key_bearer\"" >> ~/.bashrc
                echo "export LITELLM_API_KEY=\"\$litellm_api_key_bearer\"" >> ~/.profile
            ' >/dev/null 2>&1
            log "  Pi configured: LITELLM_API_KEY (Bearer) + LITELLM_BASE_URL."
            ;;
    esac
}

# --- Vertex AI provider ---

setup_provider_vertex() {
    local harness="$1" use_max="$2"
    log "Inference provider: vertex"

    [[ "$harness" == "claude" ]] || die "Vertex AI provider only supports the claude harness."
    [[ "$use_max" == "false" ]] || die "--max is only valid with --provider litellm."

    [[ -f ~/.config/gcloud/application_default_credentials.json ]] \
        || die "Missing gcloud ADC. Run: gcloud auth application-default login"

    keychain_exists "anthropic-vertex-project-id" \
        || die "Missing Keychain: anthropic-vertex-project-id"

    local project_id
    project_id=$(keychain_get "anthropic-vertex-project-id")

    # Vertex AI provider from gcloud ADC (handles token refresh)
    openshell provider delete vertex-ai 2>/dev/null || true
    openshell provider create \
        --name vertex-ai \
        --type google-vertex-ai \
        --from-gcloud-adc \
        >/dev/null 2>&1 || die "Failed to create vertex-ai provider."
    PROVIDERS_CREATED+=("vertex-ai")
    PROVIDER_FLAGS="$PROVIDER_FLAGS --provider vertex-ai"

    # Claude Code still requires its builtin provider for binary auto-detection.
    # Use a dummy key — Vertex auth goes through the bearer token, not x-api-key.
    openshell provider delete claude-code 2>/dev/null || true
    openshell provider create \
        --name claude-code \
        --type claude-code \
        --credential "api_key=vertex-managed" \
        >/dev/null 2>&1 || die "Failed to create claude-code provider."
    PROVIDERS_CREATED+=("claude-code")
    PROVIDER_FLAGS="$PROVIDER_FLAGS --provider claude-code"

    # Env flags — tell Claude Code to use Vertex
    ENV_FLAGS="$ENV_FLAGS --env CLAUDE_CODE_USE_VERTEX=1"
    ENV_FLAGS="$ENV_FLAGS --env ANTHROPIC_VERTEX_PROJECT_ID=${project_id}"
    ENV_FLAGS="$ENV_FLAGS --env CLOUD_ML_REGION=global"
    ENV_FLAGS="$ENV_FLAGS --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=0"

    SANDBOX_INIT_HOOK="setup_sandbox_vertex"
}

setup_sandbox_vertex() {
    local harness="$1"
    # No additional sandbox init needed — Vertex auth is handled by the
    # gateway injecting the bearer token from gcloud ADC refresh.
    log "  Vertex AI credentials managed by gateway token refresh."
}

# --- Direct Anthropic API provider ---

setup_provider_api() {
    local harness="$1" use_max="$2"
    log "Inference provider: api (direct Anthropic)"

    [[ "$harness" == "claude" ]] || die "Direct Anthropic API provider only supports the claude harness."
    [[ "$use_max" == "false" ]] || die "--max is only valid with --provider litellm."

    # For direct API, we need a real Anthropic API key (not a LiteLLM key).
    # Check for a dedicated keychain entry first, fall back to litellm-api-key.
    local api_key=""
    if keychain_exists "anthropic-api-key-direct"; then
        api_key=$(keychain_get "anthropic-api-key-direct")
        log "  Using dedicated direct API key."
    elif keychain_exists "litellm-api-key"; then
        api_key=$(keychain_get "litellm-api-key")
        log "  Using litellm-api-key (no anthropic-api-key-direct found)."
    else
        die "Missing Keychain: anthropic-api-key-direct or litellm-api-key"
    fi

    # The builtin claude-code provider covers api.anthropic.com endpoints
    # and handles credential injection for x-api-key.
    openshell provider delete claude-code 2>/dev/null || true
    openshell provider create \
        --name claude-code \
        --type claude-code \
        --credential "api_key=${api_key}" \
        >/dev/null 2>&1 || die "Failed to create claude-code provider."
    PROVIDERS_CREATED+=("claude-code")
    PROVIDER_FLAGS="$PROVIDER_FLAGS --provider claude-code"

    # No ANTHROPIC_BASE_URL — Claude Code defaults to api.anthropic.com.
    # No ANTHROPIC_API_KEY env var needed — the claude-code provider injects it.
    ENV_FLAGS="$ENV_FLAGS --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=0"

    SANDBOX_INIT_HOOK="setup_sandbox_api"
}

setup_sandbox_api() {
    local harness="$1"
    # Map ANTHROPIC_API_KEY to the claude-code provider's api_key placeholder
    # so Claude Code activates API key mode.
    openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c '
        echo "export ANTHROPIC_API_KEY=\"\$api_key\"" >> ~/.bashrc
        echo "export ANTHROPIC_API_KEY=\"\$api_key\"" >> ~/.profile
    ' >/dev/null 2>&1
    log "  ANTHROPIC_API_KEY mapped to claude-code api_key placeholder."
}

# ========================================================================

# --- Install agent in sandbox if needed ---
install_harness() {
    local harness="$1"
    case "$harness" in
        pi)
            log "Installing Pi + LiteLLM provider in sandbox..."
            openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c '
                mkdir -p /sandbox/.npm-global
                npm config set prefix /sandbox/.npm-global
                npm install -g @earendil-works/pi-coding-agent
            ' 2>&1 | tail -3 || log "  WARNING: Pi npm install may have failed."
            openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c '
                echo "export PATH=\"/sandbox/.npm-global/bin:\$PATH\"" >> ~/.bashrc
                echo "export PATH=\"/sandbox/.npm-global/bin:\$PATH\"" >> ~/.profile
            ' >/dev/null 2>&1
            # Install pi-provider-litellm extension
            openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c '
                export PATH="/sandbox/.npm-global/bin:$PATH"
                pi install npm:pi-provider-litellm
            ' 2>&1 | tail -3 || log "  WARNING: pi-provider-litellm install may have failed."
            ;;
    esac
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
        trap - EXIT
        echo "Usage: agent-run <owner/repo> <harness> [--provider <provider>] [--model <model>] [--max]"
        echo ""
        echo "  Harnesses:  $SUPPORTED_HARNESSES"
        echo "  Providers:  litellm (default), vertex, api"
        echo "  Repos:      ${APPROVED_REPOS[*]}"
        echo ""
        echo "  Harness/provider compatibility:"
        echo "    claude:  litellm (default), vertex, api"
        echo "    pi:      litellm (default)"
        echo "    shell:   none"
        echo ""
        echo "  --provider <p>  Select inference provider (default: litellm)"
        echo "  --model <m>     Override model (passed to harness CLI as --model)"
        echo "  --max           Claude Max subscription via LiteLLM (litellm only)"
        echo "  --diag          Print diagnostic info"
        echo "  --list-repos    List approved repositories"
        exit 0
        ;;
esac

# Parse arguments
REPO="${1:?Usage: agent-run <owner/repo> <harness> [--provider <provider>] [--model <model>] [--max]}"
HARNESS="${2:?Usage: agent-run <owner/repo> <harness> [--provider <provider>] [--model <model>] [--max]}"
shift 2

INFERENCE_PROVIDER=""
MODEL_OVERRIDE=""
USE_MAX="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider) INFERENCE_PROVIDER="${2:?--provider requires a value}"; shift 2 ;;
        --model)    MODEL_OVERRIDE="${2:?--model requires a value}"; shift 2 ;;
        --max)      USE_MAX="true"; shift ;;
        *)          die "Unknown option: $1" ;;
    esac
done

# Defaults
[[ -z "$INFERENCE_PROVIDER" ]] && INFERENCE_PROVIDER=$(harness_default_provider "$HARNESS")

# Validate
is_approved_repo "$REPO" || die "Repository '$REPO' is not in the approved list. Use --list-repos."
HARNESS_CMD=$(harness_command "$HARNESS") || die "Unknown harness '$HARNESS'. Supported: $SUPPORTED_HARNESSES"
harness_supports_provider "$HARNESS" "$INFERENCE_PROVIDER" \
    || die "Harness '$HARNESS' does not support provider '$INFERENCE_PROVIDER'."

SANDBOX_NAME="a-${HARNESS}-$(date +%s | tail -c 6)"

log "Repository: $REPO"
log "Harness:    $HARNESS"
log "Provider:   $INFERENCE_PROVIDER"
[[ -n "$MODEL_OVERRIDE" ]] && log "Model:      $MODEL_OVERRIDE"
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

# Step 4: Set up inference provider
PROVIDER_FLAGS="--provider $GITHUB_PROVIDER_NAME"
ENV_FLAGS=""
SANDBOX_INIT_HOOK=""

if [[ "$INFERENCE_PROVIDER" != "none" ]]; then
    "setup_provider_${INFERENCE_PROVIDER}" "$HARNESS" "$USE_MAX"
fi

# Step 5: Generate repo-specific policy
log "Generating sandbox policy for $REPO..."
POLICY_TMP=$(generate_policy "$REPO")

# Step 6: Create sandbox
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

# Step 7: Harness-specific install
install_harness "$HARNESS"

# Step 8: Provider-specific sandbox init
if [[ -n "$SANDBOX_INIT_HOOK" ]]; then
    "$SANDBOX_INIT_HOOK" "$HARNESS"
fi

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
log "Launching harness: $HARNESS (provider: $INFERENCE_PROVIDER)"
[[ -n "$MODEL_OVERRIDE" ]] && log "Model override: $MODEL_OVERRIDE"
log "Working directory: /sandbox/repo"
echo "---"

HARNESS_ARGS=""
if [[ -n "$MODEL_OVERRIDE" ]]; then
    case "$HARNESS" in
        claude) HARNESS_ARGS="--model $MODEL_OVERRIDE" ;;
        pi)     HARNESS_ARGS="--model $MODEL_OVERRIDE" ;;
    esac
fi

set +e
openshell sandbox exec -n "$SANDBOX_NAME" --workdir /sandbox/repo --tty -- \
    bash -c "source ~/.profile 2>/dev/null; export GH_TOKEN=\$api_token; exec $HARNESS_CMD $HARNESS_ARGS"
HARNESS_EXIT=$?
set -e

# Cleanup runs via trap
