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
