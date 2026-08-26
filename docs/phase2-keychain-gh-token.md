# Phase 2 - macOS Keychain + `gh-token`

## `gh-token`

- **Tool:** [Link-/gh-token](https://github.com/Link-/gh-token)
- **Version:** 2.0.10 (pinned)
- **Installed as:** `gh` CLI extension (`gh token ...`)
- **Installed:** 2026-08-26

### Commands

```bash
gh token generate --app-id <ID> --installation-id <ID> --key <PEM_FILE> [--token-only]
gh token revoke --token <TOKEN>
gh token installations --app-id <ID> --key <PEM_FILE>
```

## macOS Keychain Storage

The GitHub App private key is stored in the login keychain:

| Field | Value |
|---|---|
| Service | `github-app-jlaska-agent` |
| Account | `private-key` |
| Label | `jlaska-agent GitHub App Private Key (App ID: 4720923)` |
| Type | `GitHub App PEM` |

### Retrieval note

macOS Keychain hex-encodes multi-line values stored via `security add-generic-password -w`.
The helper script detects hex output and decodes with `xxd -r -p` before use.

### Import command (reference)

```bash
security add-generic-password \
  -s "github-app-jlaska-agent" \
  -a "private-key" \
  -l "jlaska-agent GitHub App Private Key (App ID: 4720923)" \
  -D "GitHub App PEM" \
  -T "" \
  -w "$(cat /path/to/private-key.pem)" \
  login.keychain-db
```

## Helper Script

`scripts/mint-token.sh` retrieves the private key from Keychain, writes it to an
ephemeral `0600` temp file with `trap`-guaranteed cleanup, and invokes `gh token`.

```bash
# Mint a token (full JSON output)
./scripts/mint-token.sh

# Mint a token (token value only, for piping)
./scripts/mint-token.sh --token-only

# Revoke a token
./scripts/mint-token.sh --revoke <TOKEN>
```

The PEM is never logged, never stored on disk beyond the ephemeral lifetime of
the minting call, and never enters shell history.

## Token Lifecycle Test Results

Tested 2026-08-26T14:16:17Z.

| Test | Result |
|---|---|
| Mint token from Keychain | PASS |
| Token reports access to `jlaska/agent-sandbox-test` | PASS |
| Token authenticates HTTPS Git clone | PASS |
| Token revocation succeeds | PASS |
| Revoked token is rejected (401) | PASS |
| No token in shell history | PASS |
| No ephemeral key files left after exit | PASS |

## Security Properties

- Private key lives only in macOS Keychain (and Bitwarden backup)
- Private key never enters: repository files, `.env`, shell history, `~/.ssh`, sandbox, Kubernetes
- Ephemeral key file: `0600` permissions, `trap EXIT INT TERM HUP` cleanup
- Installation tokens expire after 1 hour
- Tokens can be explicitly revoked before expiry
- No YubiKey involvement in token minting or use
