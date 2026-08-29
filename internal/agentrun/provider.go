package agentrun

import (
	"fmt"
	"os"
	"strings"
)

// placeholderCredential is a non-secret value used when creating OpenShell
// providers that need a credential field but don't use it for auth.
const placeholderCredential = "api_key=not-a-real-key" //nolint:gosec // gitleaks:allow

// Known inference env vars to auto-forward from the host environment.
var inferenceEnvVars = map[string][]string{
	HarnessClaude: {
		"ANTHROPIC_API_KEY",
		"ANTHROPIC_BASE_URL",
		"ANTHROPIC_AUTH_TOKEN",
		"CLAUDE_CODE_OAUTH_TOKEN",
		"CLAUDE_CODE_USE_VERTEX",
		"ANTHROPIC_VERTEX_PROJECT_ID",
		"CLOUD_ML_REGION",
		"ANTHROPIC_CUSTOM_HEADERS",
		"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
	},
	HarnessPi: {
		"LITELLM_API_KEY",
		"LITELLM_BASE_URL",
		"ANTHROPIC_API_KEY",
		"ANTHROPIC_BASE_URL",
	},
}

// resolveInferenceEnv merges auto-forwarded host env vars with explicit --env
// overrides. Returns --env flags for openshell sandbox create.
func resolveInferenceEnv(harness string, explicitEnv []string) []string {
	// Collect explicit keys for override detection
	explicitKeys := make(map[string]bool)
	for _, e := range explicitEnv {
		if k, _, ok := strings.Cut(e, "="); ok {
			explicitKeys[k] = true
		}
	}

	var envFlags []string

	// Auto-forward known env vars from host (unless overridden by --env)
	for _, key := range inferenceEnvVars[harness] {
		if explicitKeys[key] {
			continue
		}
		if val := os.Getenv(key); val != "" {
			envFlags = append(envFlags, "--env", key+"="+val)
		}
	}

	// Add explicit --env values
	for _, e := range explicitEnv {
		envFlags = append(envFlags, "--env", e)
	}

	return envFlags
}

// createInferenceProviders creates the minimal OpenShell providers needed for
// the harness. Returns provider names for cleanup tracking.
func createInferenceProviders(harness string) (providerFlags []string, providerNames []string, err error) {
	switch harness {
	case HarnessClaude:
		name := "claude-code"
		_ = execCmdSilent("openshell", "provider", "delete", name)
		if err := execCmd("openshell", "provider", "create",
			"--name", name,
			"--type", "claude-code",
			"--credential", placeholderCredential,
		); err != nil {
			return nil, nil, fmt.Errorf("failed to create claude-code provider: %w", err)
		}
		return []string{"--provider", name}, []string{name}, nil

	default:
		return nil, nil, nil
	}
}
