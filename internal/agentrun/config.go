package agentrun

import (
	"flag"
	"fmt"
	"strings"
)

// Supported harness types.
const (
	HarnessClaude = "claude"
	HarnessPi     = "pi"
	HarnessShell  = "shell"
)

// Supported inference providers.
const (
	ProviderLiteLLM = "litellm"
	ProviderVertex  = "vertex"
	ProviderAPI     = "api"
	ProviderNone    = "none"
)

// Approved repositories.
// Add new repos here only after completing the full graduation checklist
// (GitHub App installation, rulesets, token-scoping tests, policy generation tests).
var ApprovedRepos = []string{
	"jlaska/agent-sandbox-test",
}

// Config holds parsed command-line arguments and configuration.
type Config struct {
	// Positional arguments
	Repo    string
	Harness string

	// Optional flags
	Provider       string
	Model          string
	Max            bool
	Diag           bool
	ListRepos      bool
	Help           bool
	MintToken      bool
	RevokeToken    string
	GeneratePolicy bool
}

// harnessCommands maps harness names to their shell commands.
var harnessCommands = map[string]string{
	HarnessClaude: "claude",
	HarnessPi:     "pi",
	HarnessShell:  "bash",
}

// harnessDefaultProvider returns the default provider for a harness.
func harnessDefaultProvider(harness string) string {
	switch harness {
	case HarnessClaude, HarnessPi:
		return ProviderLiteLLM
	case HarnessShell:
		return ProviderNone
	default:
		return ""
	}
}

// harnessSupportsProvider checks if a harness supports a provider.
func harnessSupportsProvider(harness, provider string) bool {
	compat := map[string][]string{
		HarnessClaude: {ProviderLiteLLM, ProviderVertex, ProviderAPI},
		HarnessPi:     {ProviderLiteLLM},
		HarnessShell:  {ProviderNone},
	}
	supported, ok := compat[harness]
	if !ok {
		return false
	}
	for _, p := range supported {
		if p == provider {
			return true
		}
	}
	return false
}

// ParseArgs parses command-line arguments into a Config.
// Flags may appear before, after, or between positional arguments.
func ParseArgs(args []string) (*Config, error) {
	cfg := &Config{}

	fs := flag.NewFlagSet("agent-run", flag.ContinueOnError)
	fs.StringVar(&cfg.Provider, "provider", "", "inference provider (litellm, vertex, api)")
	fs.StringVar(&cfg.Model, "model", "", "override model name")
	fs.BoolVar(&cfg.Max, "max", false, "use Claude Max subscription via LiteLLM")
	fs.BoolVar(&cfg.Diag, "diag", false, "print diagnostic information")
	fs.BoolVar(&cfg.ListRepos, "list-repos", false, "list approved repositories")
	fs.BoolVar(&cfg.Help, "help", false, "print usage")
	fs.BoolVar(&cfg.MintToken, "mint-token", false, "mint a repo-scoped token and print it")
	fs.StringVar(&cfg.RevokeToken, "revoke-token", "", "revoke a previously minted token")
	fs.BoolVar(&cfg.GeneratePolicy, "generate-policy", false, "generate a repo-scoped policy file and print its path")

	// Separate flags from positional args so flags work in any position.
	var flagArgs, positional []string
	flagsWithValue := map[string]bool{"--provider": true, "--model": true, "--revoke-token": true}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if strings.HasPrefix(a, "-") {
			flagArgs = append(flagArgs, a)
			if flagsWithValue[a] && i+1 < len(args) {
				i++
				flagArgs = append(flagArgs, args[i])
			}
		} else {
			positional = append(positional, a)
		}
	}

	if err := fs.Parse(flagArgs); err != nil {
		return nil, err
	}

	if cfg.Help {
		printUsage()
		return cfg, nil
	}

	if cfg.ListRepos {
		printRepos()
		return cfg, nil
	}

	if cfg.RevokeToken != "" {
		return cfg, nil
	}

	if cfg.MintToken || cfg.GeneratePolicy {
		if len(positional) < 1 {
			if cfg.MintToken {
				return nil, fmt.Errorf("usage: agent-run --mint-token <owner/repo>")
			}
			return nil, fmt.Errorf("usage: agent-run --generate-policy <owner/repo>")
		}
		cfg.Repo = positional[0]
		if _, _, err := ParseRepo(cfg.Repo); err != nil {
			return nil, fmt.Errorf("invalid repository: %w", err)
		}
		return cfg, nil
	}

	if len(positional) == 0 {
		cfg.Help = true
		printUsage()
		return cfg, nil
	}

	if len(positional) < 2 {
		return nil, fmt.Errorf("usage: agent-run <owner/repo> <harness> [options]")
	}

	cfg.Repo = positional[0]
	cfg.Harness = positional[1]

	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

// Validate checks the configuration for validity.
func (c *Config) Validate() error {
	if c.Repo == "" {
		return fmt.Errorf("repository is required")
	}

	if _, _, err := ParseRepo(c.Repo); err != nil {
		return fmt.Errorf("invalid repository: %w", err)
	}

	if c.Harness == "" {
		return fmt.Errorf("harness is required")
	}

	// Validate harness
	switch c.Harness {
	case HarnessClaude, HarnessPi, HarnessShell:
		// valid
	default:
		return fmt.Errorf("unknown harness %q; supported: %s", c.Harness, strings.Join([]string{HarnessClaude, HarnessPi, HarnessShell}, ", "))
	}

	// Set default provider if not specified
	if c.Provider == "" {
		c.Provider = harnessDefaultProvider(c.Harness)
	}

	// Validate provider
	switch c.Provider {
	case ProviderLiteLLM, ProviderVertex, ProviderAPI, ProviderNone:
		// valid
	default:
		return fmt.Errorf("unknown provider %q; supported: %s", c.Provider, strings.Join([]string{ProviderLiteLLM, ProviderVertex, ProviderAPI, ProviderNone}, ", "))
	}

	// Check harness/provider compatibility
	if !harnessSupportsProvider(c.Harness, c.Provider) {
		return fmt.Errorf("harness %q does not support provider %q", c.Harness, c.Provider)
	}

	// Check approved repos
	if !isApprovedRepo(c.Repo) {
		return fmt.Errorf("repository %q is not in the approved list; use --list-repos to see available repos", c.Repo)
	}

	// Validate --max flag
	if c.Max && c.Provider != ProviderLiteLLM {
		return fmt.Errorf("--max is only valid with --provider litellm")
	}

	return nil
}

func isApprovedRepo(repo string) bool {
	for _, approved := range ApprovedRepos {
		if repo == approved {
			return true
		}
	}
	return false
}

func printUsage() {
	fmt.Println("Usage: agent-run <owner/repo> <harness> [--provider <provider>] [--model <model>] [--max]")
	fmt.Println()
	fmt.Printf("  Harnesses:  %s, %s, %s\n", HarnessClaude, HarnessPi, HarnessShell)
	fmt.Printf("  Providers:  %s (default), %s, %s\n", ProviderLiteLLM, ProviderVertex, ProviderAPI)
	fmt.Println("  Repos:     ", strings.Join(ApprovedRepos, ", "))
	fmt.Println()
	fmt.Println("  Harness/provider compatibility:")
	fmt.Println("    claude:  litellm (default), vertex, api")
	fmt.Println("    pi:      litellm (default)")
	fmt.Println("    shell:   none")
	fmt.Println()
	fmt.Println("  --provider <p>  Select inference provider (default: litellm)")
	fmt.Println("  --model <m>     Override model (passed to harness CLI as --model)")
	fmt.Println("  --max           Claude Max subscription via LiteLLM (litellm only)")
	fmt.Println("  --diag          Print diagnostic info")
	fmt.Println("  --list-repos    List approved repositories")
}

func printRepos() {
	fmt.Println("Approved repositories:")
	for _, repo := range ApprovedRepos {
		fmt.Printf("  %s\n", repo)
	}
}
