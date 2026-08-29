package agentrun

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// setupProvider configures an inference provider and returns:
// - sandbox init hook name (if any)
// - provider names to track for cleanup
// - environment flags for sandbox creation
func setupProvider(provider, harness string, useMax bool) (hook string, providers []string, envFlags []string, err error) {
	switch provider {
	case ProviderLiteLLM:
		return setupProviderLiteLLM(harness, useMax)
	case ProviderVertex:
		return setupProviderVertex(harness, useMax)
	case ProviderAPI:
		return setupProviderAPI(harness, useMax)
	default:
		return "", nil, nil, fmt.Errorf("unknown provider: %s", provider)
	}
}

func setupProviderLiteLLM(harness string, useMax bool) (string, []string, []string, error) {
	fmt.Println("[agent-run] Inference provider: litellm")

	// Check keychain credentials
	if !keychainExists("litellm-api-key") {
		return "", nil, nil, fmt.Errorf("missing Keychain: litellm-api-key")
	}
	if !keychainExists("anthropic-base-url") {
		return "", nil, nil, fmt.Errorf("missing Keychain: anthropic-base-url")
	}

	apiKey := keychainGet("litellm-api-key")
	baseURL := keychainGet("anthropic-base-url")

	// Check for litellm profile
	out, _ := execCmdOutput("openshell", "provider", "list-profiles")
	if !strings.Contains(out, "litellm-inference") {
		repoRoot := findRepoRoot()
		profilePath := filepath.Join(repoRoot, "openshell", "litellm-inference-profile.yaml")
		if err := execCmd("openshell", "provider", "profile", "import", "--file", profilePath); err != nil {
			return "", nil, nil, fmt.Errorf("failed to import LiteLLM provider profile")
		}
	}

	// Get bearer token (optional)
	bearerToken := ""
	if keychainExists("litellm-bearer-token") {
		bearerToken = keychainGet("litellm-bearer-token")
	}

	// Create litellm-inference provider
	_ = execCmd("openshell", "provider", "delete", "litellm-inference")
	if err := execCmd("openshell", "provider", "create",
		"--name", "litellm-inference",
		"--type", "litellm-inference",
		"--credential", fmt.Sprintf("litellm_api_key=%s", apiKey),
		"--credential", fmt.Sprintf("litellm_bearer_token=%s", orDefault(bearerToken, "unused")),
	); err != nil {
		return "", nil, nil, fmt.Errorf("failed to create litellm-inference provider")
	}
	providers := []string{"litellm-inference"}
	envFlags := []string{"--provider", "litellm-inference"}

	// Claude Code also requires builtin claude-code provider
	if harness == HarnessClaude {
		_ = execCmd("openshell", "provider", "delete", "claude-code")
		if err := execCmd("openshell", "provider", "create",
			"--name", "claude-code",
			"--type", "claude-code",
			"--credential", fmt.Sprintf("api_key=%s", apiKey),
		); err != nil {
			return "", nil, nil, fmt.Errorf("failed to create claude-code provider")
		}
		providers = append(providers, "claude-code")
		envFlags = append(envFlags, "--provider", "claude-code")
	}

	// Environment flags
	switch harness {
	case HarnessClaude:
		envFlags = append(envFlags,
			"--env", "ANTHROPIC_API_KEY=__LITELLM_PLACEHOLDER__",
			"--env", fmt.Sprintf("ANTHROPIC_BASE_URL=%s", baseURL),
			"--env", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
		)
		if useMax {
			if bearerToken == "" {
				return "", nil, nil, fmt.Errorf("missing Keychain: litellm-bearer-token (required for --max)")
			}
			envFlags = append(envFlags,
				"--env", fmt.Sprintf("ANTHROPIC_CUSTOM_HEADERS=x-litellm-api-key: Bearer %s", bearerToken),
			)
			fmt.Println("[agent-run]   Max subscription mode enabled.")
		}
	case HarnessPi:
		envFlags = append(envFlags,
			"--env", fmt.Sprintf("LITELLM_BASE_URL=%s", baseURL),
		)
	}

	return "setup_sandbox_litellm", providers, envFlags, nil
}

func setupProviderVertex(harness string, useMax bool) (string, []string, []string, error) {
	fmt.Println("[agent-run] Inference provider: vertex")

	if harness != HarnessClaude {
		return "", nil, nil, fmt.Errorf("vertex AI provider only supports the claude harness")
	}
	if useMax {
		return "", nil, nil, fmt.Errorf("--max is only valid with --provider litellm")
	}

	// Check gcloud ADC
	home, _ := os.UserHomeDir()
	adcPath := filepath.Join(home, ".config/gcloud/application_default_credentials.json")
	if _, err := os.Stat(adcPath); err != nil {
		return "", nil, nil, fmt.Errorf("missing gcloud ADC; run: gcloud auth application-default login")
	}

	// Check keychain
	if !keychainExists("anthropic-vertex-project-id") {
		return "", nil, nil, fmt.Errorf("missing Keychain: anthropic-vertex-project-id")
	}

	projectID := keychainGet("anthropic-vertex-project-id")

	// Create vertex-ai provider
	_ = execCmd("openshell", "provider", "delete", "vertex-ai")
	if err := execCmd("openshell", "provider", "create",
		"--name", "vertex-ai",
		"--type", "google-vertex-ai",
		"--from-gcloud-adc",
	); err != nil {
		return "", nil, nil, fmt.Errorf("failed to create vertex-ai provider")
	}
	providers := []string{"vertex-ai"}
	envFlags := []string{"--provider", "vertex-ai"}

	// Claude Code still requires builtin provider
	_ = execCmd("openshell", "provider", "delete", "claude-code")
	if err := execCmd("openshell", "provider", "create",
		"--name", "claude-code",
		"--type", "claude-code",
		"--credential", "api_key=vertex-managed",
	); err != nil {
		return "", nil, nil, fmt.Errorf("failed to create claude-code provider")
	}
	providers = append(providers, "claude-code")
	envFlags = append(envFlags, "--provider", "claude-code")

	// Environment flags
	envFlags = append(envFlags,
		"--env", "CLAUDE_CODE_USE_VERTEX=1",
		"--env", fmt.Sprintf("ANTHROPIC_VERTEX_PROJECT_ID=%s", projectID),
		"--env", "CLOUD_ML_REGION=global",
		"--env", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
	)

	return "setup_sandbox_vertex", providers, envFlags, nil
}

func setupProviderAPI(harness string, useMax bool) (string, []string, []string, error) {
	fmt.Println("[agent-run] Inference provider: api (direct Anthropic)")

	if harness != HarnessClaude {
		return "", nil, nil, fmt.Errorf("direct Anthropic API provider only supports the claude harness")
	}
	if useMax {
		return "", nil, nil, fmt.Errorf("--max is only valid with --provider litellm")
	}

	// Get API key
	apiKey := ""
	if keychainExists("anthropic-api-key-direct") {
		apiKey = keychainGet("anthropic-api-key-direct")
		fmt.Println("[agent-run]   Using dedicated direct API key.")
	} else if keychainExists("litellm-api-key") {
		apiKey = keychainGet("litellm-api-key")
		fmt.Println("[agent-run]   Using litellm-api-key (no anthropic-api-key-direct found).")
	} else {
		return "", nil, nil, fmt.Errorf("missing Keychain: anthropic-api-key-direct or litellm-api-key")
	}

	// Create claude-code provider
	_ = execCmd("openshell", "provider", "delete", "claude-code")
	if err := execCmd("openshell", "provider", "create",
		"--name", "claude-code",
		"--type", "claude-code",
		"--credential", fmt.Sprintf("api_key=%s", apiKey),
	); err != nil {
		return "", nil, nil, fmt.Errorf("failed to create claude-code provider")
	}
	providers := []string{"claude-code"}
	envFlags := []string{"--provider", "claude-code", "--env", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=0"}

	return "setup_sandbox_api", providers, envFlags, nil
}

// runSandboxInitHook runs a provider-specific sandbox initialization hook.
func runSandboxInitHook(hook, harness, sandboxName string) error {
	switch hook {
	case "setup_sandbox_litellm":
		return setupSandboxLiteLLM(harness, sandboxName)
	case "setup_sandbox_vertex":
		return setupSandboxVertex(harness, sandboxName)
	case "setup_sandbox_api":
		return setupSandboxAPI(harness, sandboxName)
	}
	return nil
}

func setupSandboxLiteLLM(harness, sandboxName string) error {
	switch harness {
	case HarnessClaude:
		return execCmd("openshell", "sandbox", "exec", "-n", sandboxName, "--", "sh", "-c",
			`echo 'export ANTHROPIC_API_KEY="$litellm_api_key"' >> ~/.bashrc
			 echo 'export ANTHROPIC_API_KEY="$litellm_api_key"' >> ~/.profile`)
	case HarnessPi:
		return execCmd("openshell", "sandbox", "exec", "-n", sandboxName, "--", "sh", "-c",
			`echo 'export LITELLM_API_KEY="$litellm_api_key"' >> ~/.bashrc
			 echo 'export LITELLM_API_KEY="$litellm_api_key"' >> ~/.profile`)
	}
	return nil
}

func setupSandboxVertex(harness, sandboxName string) error {
	fmt.Println("[agent-run]   Vertex AI credentials managed by gateway token refresh.")
	return nil
}

func setupSandboxAPI(harness, sandboxName string) error {
	return execCmd("openshell", "sandbox", "exec", "-n", sandboxName, "--", "sh", "-c",
		`echo 'export ANTHROPIC_API_KEY="$api_key"' >> ~/.bashrc
		 echo 'export ANTHROPIC_API_KEY="$api_key"' >> ~/.profile`)
}

// generatePolicy generates a repo-specific sandbox policy.
func generatePolicy(repo, scriptDir string) (string, error) {
	repoRoot := filepath.Dir(scriptDir)
	policyFile := filepath.Join(repoRoot, "openshell", "sandbox-policy.yaml")

	content, err := os.ReadFile(policyFile)
	if err != nil {
		return "", fmt.Errorf("failed to read policy file: %w", err)
	}

	// Replace repo reference
	updated := strings.ReplaceAll(string(content), "jlaska/agent-sandbox-test", repo)

	// Write to temp file
	tmpfile, err := os.CreateTemp("", "agent-run-policy.*.yaml")
	if err != nil {
		return "", fmt.Errorf("failed to create temp policy file: %w", err)
	}

	if _, err := tmpfile.WriteString(updated); err != nil {
		_ = tmpfile.Close()
		_ = os.Remove(tmpfile.Name())
		return "", fmt.Errorf("failed to write policy file: %w", err)
	}

	if err := tmpfile.Close(); err != nil {
		_ = os.Remove(tmpfile.Name())
		return "", err
	}

	return tmpfile.Name(), nil
}

// installHarness installs harness-specific software in the sandbox.
func installHarness(harness, sandboxName string) error {
	switch harness {
	case HarnessPi:
		fmt.Println("[agent-run] Installing Pi in sandbox...")
		installCmd := `
			mkdir -p /sandbox/.npm-global
			npm config set prefix /sandbox/.npm-global
			npm install -g @earendil-works/pi-coding-agent
		`
		if err := execCmd("openshell", "sandbox", "exec", "-n", sandboxName, "--", "sh", "-c", installCmd); err != nil {
			fmt.Println("[agent-run] WARNING: Pi npm install may have failed.")
		}

		// Setup PATH
		pathSetup := `
			echo 'export PATH="/sandbox/.npm-global/bin:$PATH"' >> ~/.bashrc
			echo 'export PATH="/sandbox/.npm-global/bin:$PATH"' >> ~/.profile
		`
		return execCmd("openshell", "sandbox", "exec", "-n", sandboxName, "--", "sh", "-c", pathSetup)
	}
	return nil
}

// keychainGet retrieves a value from macOS Keychain.
func keychainGet(service string) string {
	out, _ := execCmdOutput("security", "find-generic-password", "-s", service, "-a", os.Getenv("USER"), "-w")
	return strings.TrimSpace(out)
}

// findRepoRoot finds the repository root directory.
func findRepoRoot() string {
	// Try to find from script location
	if wd, err := os.Getwd(); err == nil {
		if _, err := os.Stat(filepath.Join(wd, "openshell")); err == nil {
			return wd
		}
	}
	// Fallback
	return "."
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
