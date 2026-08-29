# agent-sandbox-test

Disposable proving ground for testing GitHub App permissions, rulesets, and
OpenShell sandbox policies against agent workflows.

This repository exists to be exercised by automated agents. Content here is
intentionally trivial — it is not production infrastructure.

## Purpose

- Validate that the `jlaska-agent` GitHub App can push `agent/**` branches.
- Validate that the App **cannot** push `main`, unauthorized branches, or tags.
- Validate that merge APIs are blocked by OpenShell policy.
- Provide a safe target for destructive/negative authorization testing.

## agent-run

The `agent-run` Go binary is the single supported entry point for launching
sandboxed agent sessions. It handles repository-scoped token minting,
single-repository OpenShell policy generation, and secure cleanup.

### Building

```bash
# Build the binary
make build

# Run tests
make test

# Lint the code
make lint

# Install to GOPATH/bin
make install
```

### Usage

```bash
agent-run <owner/repo> <harness> [--provider <provider>] [--model <model>] [--max]
agent-run --diag
agent-run --list-repos
```

**Harnesses** (the agent binary):

- `claude` - Claude Code CLI
- `pi` - Pi coding agent
- `shell` - Interactive bash

**Providers** (where model calls go):

- `litellm` - LiteLLM proxy (default)
- `vertex` - Direct Google Vertex AI
- `api` - Direct Anthropic API

**Flags**:

- `--model` - Override the default model
- `--max` - Claude Max subscription via LiteLLM
- `--diag` - Print diagnostic information
- `--list-repos` - List approved repositories
- `--mint-token` - Mint a repo-scoped token (for testing/scripts)
- `--revoke-token` - Revoke a previously minted token
