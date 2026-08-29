# Phase 0 - Baseline Documentation

## Mac Git Configuration (recorded, not modified)

```text
user.name       = James Laska
user.email      = 1051173+jlaska@users.noreply.github.com
commit.gpgsign  = true
tag.gpgsign     = true
gpg.format      = (not set — defaults to openpgp)
user.signingkey = 0x07E5ACD7B3165BD3
```

## GPG / YubiKey

- GPG master key: `FE149E5D50B99EC9EE32B49507E5ACD7B3165BD3` (RSA 4096, no expiry)
- Signing subkey: `CC27416519C35FF9` (RSA 4096, expires 2028-06-15) — on YubiKey serial 38083705
- Encryption subkey: `1D8AC3D87178922D` (RSA 4096, expires 2028-06-15) — on YubiKey
- Authentication subkey: `DA11994400ACAF40` (ed25519, expires 2028-06-15) — on YubiKey
- UIF (User Interaction Flag): **on** for Sign, Decrypt, Auth — every operation requires physical touch

## SSH / GitHub Authentication

- Git operations protocol: **SSH**
- SSH key: ed25519 from YubiKey (cardno:38_083_705)
- `gh` CLI: logged in via keyring, active account `jlaska`
- Remote URLs: `git@github.com:...` (SSH)

## Sandbox-Local Git Identity

Inside agent sandboxes, use this repository-local configuration:

```bash
git config user.name "jlaska-agent[bot]"
git config user.email "jlaska-agent[bot]@users.noreply.github.com"
git config commit.gpgsign false
git config tag.gpgsign false
```

The `[bot]` suffix follows GitHub App commit attribution conventions.
The email will be updated to the actual GitHub App noreply address once the App is created in Phase 1.

## Human Workflow Remains Unchanged

- Global Git config: **not modified**
- YubiKey: **not modified**
- SSH agent: **not modified**
- `gh` CLI auth: **not modified**
