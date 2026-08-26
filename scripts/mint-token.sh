#!/usr/bin/env bash
# Mint a short-lived GitHub App installation token from macOS Keychain.
#
# Usage:
#   ./scripts/mint-token.sh [--revoke TOKEN] [--token-only] [--repo OWNER/REPO]
#
# The App private key is retrieved from macOS Keychain, written to an
# ephemeral 0600 file, and deleted on exit (trap-guaranteed cleanup).

set -euo pipefail

APP_ID="4720923"
INSTALLATION_ID="156618153"
KEYCHAIN_SERVICE="github-app-jlaska-agent"
KEYCHAIN_ACCOUNT="private-key"

MODE="generate"
TOKEN_ONLY=false
REVOKE_TOKEN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --revoke)     MODE="revoke"; REVOKE_TOKEN="$2"; shift 2 ;;
        --token-only) TOKEN_ONLY=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--revoke TOKEN] [--token-only]"
            echo ""
            echo "  --token-only   Print only the token value (for piping)"
            echo "  --revoke TOK   Revoke a previously minted token"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ "$MODE" == "revoke" ]]; then
    gh token revoke --token "$REVOKE_TOKEN" --silent
    echo "Token revoked."
    exit 0
fi

# --- Ephemeral key file with guaranteed cleanup ---
TMPKEY=$(mktemp -t gh-app-key.XXXXXX)
chmod 600 "$TMPKEY"
cleanup() { rm -f "$TMPKEY"; }
trap cleanup EXIT INT TERM HUP

RAW=$(security find-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "$KEYCHAIN_ACCOUNT" \
    -w)

# macOS Keychain hex-encodes multi-line values stored via -w.
# Detect hex output (no dashes/newlines) and decode if needed.
if echo "$RAW" | head -1 | grep -q "^[0-9a-fA-F]*$"; then
    echo "$RAW" | xxd -r -p > "$TMPKEY"
else
    printf '%s\n' "$RAW" > "$TMPKEY"
fi

# Validate we got a PEM
if ! head -1 "$TMPKEY" | grep -q "BEGIN.*PRIVATE KEY"; then
    echo "ERROR: Keychain entry does not contain a valid PEM key." >&2
    exit 1
fi

if $TOKEN_ONLY; then
    gh token generate \
        --app-id "$APP_ID" \
        --installation-id "$INSTALLATION_ID" \
        --key "$TMPKEY" \
        --token-only
else
    gh token generate \
        --app-id "$APP_ID" \
        --installation-id "$INSTALLATION_ID" \
        --key "$TMPKEY"
fi
