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

// Config holds parsed command-line arguments and configuration.
type Config struct {
	// Positional arguments
	Repo    string
	Harness string

	// Optional flags
	Model          string
	EnvVars        []string
	GitHubToken    string
	Diag           bool
	ListRepos      bool
	Help           bool
	MintToken      bool
	RevokeToken    string
	GeneratePolicy bool

	// Passthrough args (everything after --)
	PassthroughArgs []string
}

// harnessCommands maps harness names to their shell commands.
var harnessCommands = map[string]string{
	HarnessClaude: "claude",
	HarnessPi:     "pi",
	HarnessShell:  "bash",
}

// envVarCollector implements flag.Value for repeatable --env flags.
type envVarCollector struct {
	values *[]string
}

func (e *envVarCollector) String() string { return "" }
func (e *envVarCollector) Set(val string) error {
	if !strings.Contains(val, "=") {
		return fmt.Errorf("env var must be in KEY=VALUE format: %q", val)
	}
	*e.values = append(*e.values, val)
	return nil
}

// ParseArgs parses command-line arguments into a Config.
// Flags may appear before, after, or between positional arguments.
func ParseArgs(args []string) (*Config, error) {
	cfg := &Config{}

	fs := flag.NewFlagSet("agent-run", flag.ContinueOnError)
	fs.StringVar(&cfg.Model, "model", "", "override model name")
	fs.Var(&envVarCollector{values: &cfg.EnvVars}, "env", "pass env var to sandbox (KEY=VAL, repeatable)")
	fs.StringVar(&cfg.GitHubToken, "github-token", "", "GitHub PAT (alternative to App token)")
	fs.BoolVar(&cfg.Diag, "diag", false, "print diagnostic information")
	fs.BoolVar(&cfg.ListRepos, "list-repos", false, "list approved repositories")
	fs.BoolVar(&cfg.Help, "help", false, "print usage")
	fs.BoolVar(&cfg.MintToken, "mint-token", false, "mint a repo-scoped token and print it")
	fs.StringVar(&cfg.RevokeToken, "revoke-token", "", "revoke a previously minted token")
	fs.BoolVar(&cfg.GeneratePolicy, "generate-policy", false, "generate a repo-scoped policy file and print its path")

	// Split at -- separator: everything after becomes passthrough args.
	for i, a := range args {
		if a == "--" {
			cfg.PassthroughArgs = args[i+1:]
			args = args[:i]
			break
		}
	}

	// Separate flags from positional args so flags work in any position.
	var flagArgs, positional []string
	flagsWithValue := map[string]bool{"--model": true, "--revoke-token": true, "--env": true, "--github-token": true}
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
		return nil, fmt.Errorf("usage: agent-run <owner/repo> <harness> [options] [-- <harness-args>...]")
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

	switch c.Harness {
	case HarnessClaude, HarnessPi, HarnessShell:
		// valid
	default:
		return fmt.Errorf("unknown harness %q; supported: %s", c.Harness, strings.Join([]string{HarnessClaude, HarnessPi, HarnessShell}, ", "))
	}

	return nil
}

func printUsage() {
	fmt.Println("Usage: agent-run <owner/repo> <harness> [options] [-- <harness-args>...]")
	fmt.Println()
	fmt.Printf("  Harnesses:  %s, %s, %s\n", HarnessClaude, HarnessPi, HarnessShell)
	fmt.Println()
	fmt.Println("  Inference auth is configured via environment variables:")
	fmt.Println("    ANTHROPIC_API_KEY          Direct API key")
	fmt.Println("    CLAUDE_CODE_OAUTH_TOKEN    Max/Pro subscription (from claude setup-token)")
	fmt.Println("    ANTHROPIC_BASE_URL         Custom endpoint (e.g. LiteLLM proxy)")
	fmt.Println("    CLAUDE_CODE_USE_VERTEX=1   Vertex AI mode")
	fmt.Println()
	fmt.Println("  --model <m>     Override model (passed to harness CLI)")
	fmt.Println("  --env KEY=VAL   Pass env var to sandbox (repeatable)")
	fmt.Println("  --diag          Print diagnostic info")
	fmt.Println("  --list-repos    List approved repositories")
}

func printRepos() {
	repos, err := ListAppRepos()
	if err != nil {
		fmt.Printf("Could not list repos: %v\n", err)
		fmt.Println("(Requires GitHub App credentials in Keychain)")
		return
	}
	fmt.Println("Accessible repositories (via GitHub App):")
	for _, repo := range repos {
		fmt.Printf("  %s\n", repo)
	}
}
