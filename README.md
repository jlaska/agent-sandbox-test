# agent-sandbox

Sandboxed agent launcher for AI coding agents. Runs Claude Code, Pi, or a plain
shell inside an [OpenShell](https://github.com/nvidia/openshell) container with
per-repository GitHub security constraints.

## What it does

`agent-run` handles the full lifecycle of a sandboxed agent session:

1. Resolve GitHub credentials (App token or PAT)
2. Generate a repo-scoped L7 network policy
3. Create an isolated container with credential injection
4. Clone the target repo, configure Git identity
5. Launch the agent harness with your inference env vars
6. Clean up everything on exit (sandbox, tokens, providers)

The agent gets exactly the permissions it needs for one repo — enforced at the
network layer — with credentials that self-destruct.

## Security model

| Layer | Enforcement |
|---|---|
| GitHub App + rulesets | Agent can only push `agent/**` branches, create PRs, comment. Cannot push `main`, merge, or manipulate tags. |
| L7 network policy | Per-binary enforcement: only `git` can reach github.com, only the harness can reach inference endpoints. Merge APIs blocked. |
| Token scope | Single-repo scoped, auto-expires (~1h), revoked on exit. |
| Container isolation | Podman rootless container, default-deny network, read-only system paths. |

## Installation

```bash
make build          # builds bin/agent-run
make install        # installs to GOPATH/bin
```

Requires: Go 1.21+, [OpenShell](https://github.com/nvidia/openshell), Podman.

## Usage

```bash
agent-run <owner/repo> <harness> [options] [-- <harness-args>...]
```

### Harnesses

| Harness | Binary | Description |
|---|---|---|
| `claude` | `claude` | Claude Code CLI |
| `pi` | `pi` | Pi coding agent |
| `shell` | `bash` | Interactive shell for debugging |

### Inference authentication

Agent-run passes your inference credentials through to the sandbox via
environment variables. Set them before running, or use `--env`:

```bash
# Direct Anthropic API
export ANTHROPIC_API_KEY=sk-ant-...
agent-run jlaska/agent-sandbox claude

# Claude Max/Pro subscription (via OAuth token from `claude setup-token`)
export CLAUDE_CODE_OAUTH_TOKEN=<token>
agent-run jlaska/agent-sandbox claude

# LiteLLM proxy
export ANTHROPIC_API_KEY=sk-litellm-...
export ANTHROPIC_BASE_URL=https://litellm.example.com
agent-run jlaska/agent-sandbox claude

# Vertex AI
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID=my-project
agent-run jlaska/agent-sandbox claude

# Explicit env override
agent-run jlaska/agent-sandbox claude --env ANTHROPIC_API_KEY=sk-ant-...
```

### GitHub authentication

Two modes, auto-detected:

- **App mode** (default): Uses a GitHub App installation token minted from a
  private key stored in macOS Keychain. Repos are auto-discovered from the App
  installation. Tokens are revoked on exit.
- **PAT mode**: Pass a Personal Access Token via `--github-token` or
  `GITHUB_TOKEN` env var. No App required. L7 sandbox policy still constrains
  operations.

```bash
# App mode (auto, if App key is in Keychain)
agent-run jlaska/agent-sandbox claude

# PAT mode
agent-run --github-token ghp_xxx jlaska/agent-sandbox claude
```

### Passthrough args

Everything after `--` is forwarded to the harness:

```bash
agent-run jlaska/agent-sandbox claude -- -p "fix the failing test"
agent-run jlaska/agent-sandbox claude -- --model opus-4-8 --allowedTools Bash,Read,Edit
```

### Flags

| Flag | Description |
|---|---|
| `--model <m>` | Override the default model |
| `--env KEY=VAL` | Pass environment variable to sandbox (repeatable) |
| `--github-token <t>` | Use a GitHub PAT instead of App token |
| `--diag` | Print diagnostic information |
| `--list-repos` | List repositories accessible to the GitHub App |
| `--mint-token <repo>` | Mint a repo-scoped token (for scripts) |
| `--revoke-token <t>` | Revoke a previously minted token |
| `--generate-policy <repo>` | Generate a repo-scoped policy file |

## Development

```bash
make test       # run tests
make vet        # go vet
make lint       # golangci-lint
make fmt        # format source
make setup      # install dev dependencies + pre-commit hooks
```

## License

See [LICENSE](LICENSE) for details.
