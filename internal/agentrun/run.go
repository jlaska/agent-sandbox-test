package agentrun

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Constants for the agent run configuration.
const (
	AppID   = "4720923"
	AppSlug = "jlaska-agent"

	GitUser  = "jlaska-agent[bot]"
	GitEmail = "jlaska-agent[bot]@users.noreply.github.com"

	GitHubProviderName = "github-agent"

	SandboxReadyTimeout = 30 * time.Second
	SandboxReadyPoll    = 1 * time.Second
)

// Run executes the agent-run command with the given configuration.
func Run(cfg *Config) error {
	if cfg.Diag {
		return printDiagnostics()
	}

	// Validate configuration
	if err := cfg.Validate(); err != nil {
		return err
	}

	// Find script directory for helper scripts
	scriptDir, err := findScriptDir()
	if err != nil {
		return fmt.Errorf("failed to find script directory: %w", err)
	}

	// State for cleanup
	var (
		sandboxName      string
		mintedToken      string
		providersCreated []string
	)

	// Cleanup function
	defer func() {
		fmt.Println("--- Cleanup ---")
		if sandboxName != "" {
			fmt.Printf("  Deleting sandbox: %s ... ", sandboxName)
			execCmdSilent("openshell", "sandbox", "delete", sandboxName)
			fmt.Println("done")
		}
		if mintedToken != "" {
			fmt.Print("  Revoking installation token ... ")
			mintScript := filepath.Join(scriptDir, "mint-token.sh")
			execCmdSilent(mintScript, "--revoke", mintedToken)
			mintedToken = ""
			fmt.Println("done")
		}
		for _, prov := range providersCreated {
			fmt.Printf("  Deleting provider: %s ... ", prov)
			execCmdSilent("openshell", "provider", "delete", prov)
			fmt.Println("done")
		}
		fmt.Println("  Cleanup complete.")
	}()

	// Log configuration
	fmt.Printf("[agent-run] Repository: %s\n", cfg.Repo)
	fmt.Printf("[agent-run] Harness:    %s\n", cfg.Harness)
	fmt.Printf("[agent-run] Provider:   %s\n", cfg.Provider)
	if cfg.Model != "" {
		fmt.Printf("[agent-run] Model:      %s\n", cfg.Model)
	}

	// Generate sandbox name
	sandboxName = fmt.Sprintf("a-%s-%d", cfg.Harness, time.Now().Unix()%1000000)
	fmt.Printf("[agent-run] Sandbox:    %s\n", sandboxName)

	if cfg.Max {
		fmt.Println("[agent-run] Mode:       Max subscription (header forwarding)")
	}

	// Step 1: Verify OpenShell gateway
	fmt.Println("[agent-run] Checking OpenShell gateway...")
	if err := execCmdSilent("openshell", "status"); err != nil {
		return fmt.Errorf("OpenShell gateway is not running")
	}

	// Step 2: Mint GitHub installation token
	fmt.Println("[agent-run] Minting installation token...")
	mintScript := filepath.Join(scriptDir, "mint-token.sh")
	output, err := execCmdOutput(mintScript, "--token-only")
	if err != nil {
		return fmt.Errorf("failed to mint token: %w", err)
	}
	mintedToken = strings.TrimSpace(output)
	fmt.Println("[agent-run] Token minted (expires in ~1 hour).")

	// Step 3: Create GitHub provider
	fmt.Println("[agent-run] Creating GitHub provider...")
	_ = execCmd("openshell", "provider", "delete", GitHubProviderName)
	if err := execCmd("openshell", "provider", "create",
		"--name", GitHubProviderName,
		"--type", "github-agent",
		"--credential", fmt.Sprintf("api_token=%s", mintedToken),
	); err != nil {
		return fmt.Errorf("failed to create GitHub provider: %w", err)
	}
	providersCreated = append(providersCreated, GitHubProviderName)
	fmt.Printf("[agent-run] Provider '%s' created.\n", GitHubProviderName)

	// Step 4: Set up inference provider
	providerFlags := []string{"--provider", GitHubProviderName}
	envFlags := []string{}
	sandboxInitHook := ""

	if cfg.Provider != ProviderNone {
		hook, pFlags, eFlags, err := setupProvider(cfg.Provider, cfg.Harness, cfg.Max)
		if err != nil {
			return fmt.Errorf("failed to setup provider: %w", err)
		}
		providersCreated = append(providersCreated, pFlags...)
		providerFlags = append(providerFlags, eFlags...)
		envFlags = append(envFlags, eFlags...)
		sandboxInitHook = hook
	}

	// Step 5: Generate repo-specific policy
	fmt.Printf("[agent-run] Generating sandbox policy for %s...\n", cfg.Repo)
	policyTmp, err := generatePolicy(cfg.Repo, scriptDir)
	if err != nil {
		return fmt.Errorf("failed to generate policy: %w", err)
	}
	defer func() { _ = os.Remove(policyTmp) }()

	// Step 6: Create sandbox
	fmt.Printf("[agent-run] Creating sandbox '%s'...\n", sandboxName)
	createArgs := []string{
		"sandbox", "create",
		"--name", sandboxName,
	}
	createArgs = append(createArgs, providerFlags...)
	createArgs = append(createArgs, "--policy", policyTmp)
	createArgs = append(createArgs, envFlags...)
	createArgs = append(createArgs, "--detach")

	if err := execCmd("openshell", createArgs...); err != nil {
		return fmt.Errorf("failed to create sandbox: %w", err)
	}

	// Wait for sandbox to be ready
	if err := waitForSandbox(sandboxName); err != nil {
		return err
	}
	fmt.Println("[agent-run] Sandbox ready.")

	// Step 7: Harness-specific install
	if err := installHarness(cfg.Harness, sandboxName); err != nil {
		return err
	}

	// Step 8: Provider-specific sandbox init
	if sandboxInitHook != "" {
		if err := runSandboxInitHook(sandboxInitHook, cfg.Harness, sandboxName); err != nil {
			return err
		}
	}

	// Step 9: Clone repository
	fmt.Printf("[agent-run] Cloning %s...\n", cfg.Repo)
	if err := execCmd("openshell", "sandbox", "exec", "-n", sandboxName, "--",
		"git", "clone", fmt.Sprintf("https://github.com/%s.git", cfg.Repo), "/sandbox/repo"); err != nil {
		return fmt.Errorf("clone failed: %w", err)
	}

	// Step 10: Configure Git identity
	fmt.Println("[agent-run] Configuring Git identity...")
	gitConfig := fmt.Sprintf(`
		cd /sandbox/repo
		git config user.name '%s'
		git config user.email '%s'
		git config commit.gpgsign false
		git config tag.gpgsign false
		git config credential.helper '!f() { echo "username=x-access-token"; echo "password=${api_token}"; }; f'
	`, GitUser, GitEmail)
	if err := execCmd("openshell", "sandbox", "exec", "-n", sandboxName, "--", "sh", "-c", gitConfig); err != nil {
		return fmt.Errorf("git configuration failed: %w", err)
	}

	// Step 11: Launch agent
	harnessCmd := harnessCommands[cfg.Harness]
	fmt.Printf("[agent-run] Launching harness: %s (provider: %s)\n", cfg.Harness, cfg.Provider)
	if cfg.Model != "" {
		fmt.Printf("[agent-run] Model override: %s\n", cfg.Model)
	}
	fmt.Println("[agent-run] Working directory: /sandbox/repo")
	fmt.Println("---")

	// Build harness args
	harnessArgs := ""
	if cfg.Model != "" {
		switch cfg.Harness {
		case HarnessClaude, HarnessPi:
			harnessArgs = fmt.Sprintf("--model %s", cfg.Model)
		}
	}

	launchCmd := fmt.Sprintf("source ~/.profile 2>/dev/null; export GH_TOKEN=$api_token; exec %s %s", harnessCmd, harnessArgs)
	execCmd("openshell", "sandbox", "exec", "-n", sandboxName, "--workdir", "/sandbox/repo", "--tty", "--",
		"bash", "-c", launchCmd)

	fmt.Println("\n[agent-run] Harness exited. Cleaning up...")

	return nil
}

// waitForSandbox waits for a sandbox to become ready.
func waitForSandbox(name string) error {
	timeout := time.After(SandboxReadyTimeout)
	ticker := time.NewTicker(SandboxReadyPoll)
	defer ticker.Stop()

	for {
		select {
		case <-timeout:
			return fmt.Errorf("sandbox did not become ready within %v", SandboxReadyTimeout)
		case <-ticker.C:
			out, _ := execCmdOutput("openshell", "sandbox", "list")
			if strings.Contains(out, name) && strings.Contains(out, "Ready") {
				return nil
			}
		}
	}
}

// findScriptDir finds the directory containing helper scripts.
func findScriptDir() (string, error) {
	// Try to find relative to executable
	exe, err := os.Executable()
	if err == nil {
		dir := filepath.Dir(filepath.Dir(exe))
		scriptDir := filepath.Join(dir, "scripts")
		if _, err := os.Stat(scriptDir); err == nil {
			return scriptDir, nil
		}
	}

	// Fallback: look for script in current directory
	if _, err := os.Stat("scripts/agent-run.sh"); err == nil {
		return "scripts", nil
	}

	return "", fmt.Errorf("cannot find scripts directory")
}

// printDiagnostics prints diagnostic information.
func printDiagnostics() error {
	fmt.Println("=== agent-run diagnostics ===")

	// OpenShell version
	fmt.Print("  OpenShell version:  ")
	out, _ := execCmdOutput("openshell", "--version")
	if out != "" {
		fmt.Println(strings.TrimSpace(out))
	} else {
		fmt.Println("not found")
	}

	// gh-token version
	fmt.Print("  gh-token version:   ")
	out, _ = execCmdOutput("gh", "extension", "list")
	if strings.Contains(out, "token") {
		lines := strings.Split(out, "\n")
		for _, line := range lines {
			if strings.Contains(line, "token") {
				parts := strings.Fields(line)
				if len(parts) >= 3 {
					fmt.Println(parts[2])
					break
				}
			}
		}
	} else {
		fmt.Println("not found")
	}

	fmt.Printf("  GitHub App slug:    %s\n", AppSlug)
	fmt.Printf("  GitHub App ID:      %s\n", AppID)
	fmt.Println("  Approved repos:    ", strings.Join(ApprovedRepos, ", "))
	fmt.Printf("  Supported harnesses: %s, %s, %s\n", HarnessClaude, HarnessPi, HarnessShell)

	// Keychain credentials
	fmt.Println("\n  Keychain credentials:")
	keychainServices := []string{
		"github-app-jlaska-agent",
		"litellm-api-key",
		"litellm-bearer-token",
		"anthropic-base-url",
		"anthropic-vertex-project-id",
	}
	for _, svc := range keychainServices {
		fmt.Printf("    %s: ", svc)
		if keychainExists(svc) {
			fmt.Println("present")
		} else {
			fmt.Println("MISSING")
		}
	}

	// gcloud ADC
	fmt.Println("\n  gcloud ADC:")
	home, _ := os.UserHomeDir()
	adcPath := filepath.Join(home, ".config/gcloud/application_default_credentials.json")
	if _, err := os.Stat(adcPath); err == nil {
		fmt.Println("    ADC file: present")
	} else {
		fmt.Println("    ADC file: MISSING")
	}

	// Installed agents
	fmt.Println("\n  Installed agents (host):")
	for _, cmd := range []string{"claude", "pi", "codex"} {
		fmt.Printf("    %-8s: ", cmd)
		if path, err := exec.LookPath(cmd); err == nil {
			fmt.Println(path)
		} else {
			fmt.Println("not found")
		}
	}

	// Provider compatibility matrix
	fmt.Println("\n  Provider compatibility matrix:")
	fmt.Println("    claude:  litellm (default), vertex, api")
	fmt.Println("    pi:      litellm (default)")
	fmt.Println("    shell:   none")

	// Gateway status
	fmt.Println("\n  Gateway status:")
	out, _ = execCmdOutput("openshell", "status")
	for _, line := range strings.Split(out, "\n") {
		if line != "" {
			fmt.Printf("    %s\n", line)
		}
	}

	// Active sandboxes
	fmt.Println("\n  Active sandboxes:")
	out, _ = execCmdOutput("openshell", "sandbox", "list")
	for _, line := range strings.Split(out, "\n") {
		if line != "" {
			fmt.Printf("    %s\n", line)
		}
	}

	// Providers
	fmt.Println("\n  Providers:")
	out, _ = execCmdOutput("openshell", "provider", "list")
	for _, line := range strings.Split(out, "\n") {
		if line != "" {
			fmt.Printf("    %s\n", line)
		}
	}

	fmt.Println("\n  NOTE: Diagnostics never print: private key, tokens, model API keys")
	return nil
}

// keychainExists checks if a keychain entry exists (macOS only).
func keychainExists(service string) bool {
	return execCmdSilent("security", "find-generic-password", "-s", service, "-a", os.Getenv("USER")) == nil
}
