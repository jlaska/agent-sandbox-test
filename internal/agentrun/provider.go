package agentrun

import (
	"fmt"
	"os"
	"path/filepath"
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

// createInferenceProviders creates the OpenShell providers needed for the
// harness to reach its inference endpoint. Returns provider flags for sandbox
// creation and provider names for cleanup tracking.
func createInferenceProviders(harness string) (providerFlags []string, providerNames []string, err error) {
	var flags []string
	var names []string

	switch harness {
	case HarnessClaude:
		// Claude Code requires the built-in claude-code provider type.
		name := "claude-code"
		_ = execCmdSilent("openshell", "provider", "delete", name)
		if err := execCmd("openshell", "provider", "create",
			"--name", name,
			"--type", "claude-code",
			"--credential", placeholderCredential,
		); err != nil {
			return nil, nil, fmt.Errorf("failed to create claude-code provider: %w", err)
		}
		flags = append(flags, "--provider", name)
		names = append(names, name)

	case HarnessPi:
		// Pi needs the litellm-inference provider for network access.
		if err := ensureLiteLLMProvider(); err != nil {
			return nil, nil, err
		}
		name := "litellm-inference"
		_ = execCmdSilent("openshell", "provider", "delete", name)
		if err := execCmd("openshell", "provider", "create",
			"--name", name,
			"--type", "litellm-inference",
			"--credential", "litellm_api_key=placeholder", //nolint:gosec // gitleaks:allow
			"--credential", "litellm_bearer_token=placeholder", //nolint:gosec // gitleaks:allow
		); err != nil {
			return nil, nil, fmt.Errorf("failed to create litellm-inference provider: %w", err)
		}
		flags = append(flags, "--provider", name)
		names = append(names, name)
	}

	return flags, names, nil
}

// ensureLiteLLMProvider imports the litellm-inference profile if not present.
func ensureLiteLLMProvider() error {
	out, _ := execCmdOutput("openshell", "provider", "list-profiles")
	if strings.Contains(out, "litellm-inference") {
		return nil
	}
	repoRoot := findRepoRoot()
	profilePath := filepath.Join(repoRoot, "openshell", "litellm-inference-profile.yaml")
	if err := execCmd("openshell", "provider", "profile", "import", "--file", profilePath); err != nil {
		return fmt.Errorf("failed to import litellm-inference provider profile: %w", err)
	}
	return nil
}
