package agentrun

import (
	"testing"
)

func TestParseArgs(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		wantErr bool
		want    *Config
	}{
		{
			name:    "valid claude",
			args:    []string{"jlaska/agent-sandbox", "claude"},
			wantErr: false,
			want: &Config{
				Repo:    "jlaska/agent-sandbox",
				Harness: "claude",
			},
		},
		{
			name:    "valid pi",
			args:    []string{"jlaska/agent-sandbox", "pi"},
			wantErr: false,
			want: &Config{
				Repo:    "jlaska/agent-sandbox",
				Harness: "pi",
			},
		},
		{
			name:    "valid shell",
			args:    []string{"jlaska/agent-sandbox", "shell"},
			wantErr: false,
			want: &Config{
				Repo:    "jlaska/agent-sandbox",
				Harness: "shell",
			},
		},
		{
			name:    "with model override",
			args:    []string{"jlaska/agent-sandbox", "claude", "--model", "claude-3-opus"},
			wantErr: false,
			want: &Config{
				Repo:    "jlaska/agent-sandbox",
				Harness: "claude",
				Model:   "claude-3-opus",
			},
		},
		{
			name:    "with env var",
			args:    []string{"jlaska/agent-sandbox", "claude", "--env", "ANTHROPIC_API_KEY=sk-test"},
			wantErr: false,
			want: &Config{
				Repo:    "jlaska/agent-sandbox",
				Harness: "claude",
				EnvVars: []string{"ANTHROPIC_API_KEY=sk-test"},
			},
		},
		{
			name:    "with multiple env vars",
			args:    []string{"jlaska/agent-sandbox", "claude", "--env", "ANTHROPIC_API_KEY=sk-test", "--env", "ANTHROPIC_BASE_URL=https://example.com"},
			wantErr: false,
			want: &Config{
				Repo:    "jlaska/agent-sandbox",
				Harness: "claude",
				EnvVars: []string{"ANTHROPIC_API_KEY=sk-test", "ANTHROPIC_BASE_URL=https://example.com"},
			},
		},
		{
			name:    "env var without equals",
			args:    []string{"jlaska/agent-sandbox", "claude", "--env", "INVALID"},
			wantErr: true,
		},
		{
			name:    "missing repository",
			args:    []string{"claude"},
			wantErr: true,
		},
		{
			name:    "unknown harness",
			args:    []string{"jlaska/agent-sandbox", "unknown"},
			wantErr: true,
		},
		{
			name:    "help flag",
			args:    []string{"--help"},
			wantErr: false,
			want: &Config{
				Help: true,
			},
		},
		{
			name:    "no args shows help",
			args:    []string{},
			wantErr: false,
			want: &Config{
				Help: true,
			},
		},
		{
			name:    "list repos flag",
			args:    []string{"--list-repos"},
			wantErr: false,
			want: &Config{
				ListRepos: true,
			},
		},
		{
			name:    "passthrough args after --",
			args:    []string{"jlaska/agent-sandbox", "claude", "--", "-p", "fix the bug"},
			wantErr: false,
			want: &Config{
				Repo:            "jlaska/agent-sandbox",
				Harness:         "claude",
				PassthroughArgs: []string{"-p", "fix the bug"},
			},
		},
		{
			name:    "passthrough with model and flags",
			args:    []string{"jlaska/agent-sandbox", "claude", "--model", "opus-4-8", "--", "--verbose", "--allowedTools", "Bash"},
			wantErr: false,
			want: &Config{
				Repo:            "jlaska/agent-sandbox",
				Harness:         "claude",
				Model:           "opus-4-8",
				PassthroughArgs: []string{"--verbose", "--allowedTools", "Bash"},
			},
		},
		{
			name:    "bare -- with no passthrough",
			args:    []string{"jlaska/agent-sandbox", "claude", "--"},
			wantErr: false,
			want: &Config{
				Repo:            "jlaska/agent-sandbox",
				Harness:         "claude",
				PassthroughArgs: []string{},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg, err := ParseArgs(tt.args)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseArgs() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if err != nil {
				return
			}
			if cfg.Help != tt.want.Help {
				t.Errorf("Help = %v, want %v", cfg.Help, tt.want.Help)
			}
			if cfg.ListRepos != tt.want.ListRepos {
				t.Errorf("ListRepos = %v, want %v", cfg.ListRepos, tt.want.ListRepos)
			}
			if cfg.Repo != tt.want.Repo {
				t.Errorf("Repo = %v, want %v", cfg.Repo, tt.want.Repo)
			}
			if cfg.Harness != tt.want.Harness {
				t.Errorf("Harness = %v, want %v", cfg.Harness, tt.want.Harness)
			}
			if cfg.Model != tt.want.Model {
				t.Errorf("Model = %v, want %v", cfg.Model, tt.want.Model)
			}
			if tt.want.EnvVars != nil {
				if len(cfg.EnvVars) != len(tt.want.EnvVars) {
					t.Errorf("EnvVars length = %d, want %d", len(cfg.EnvVars), len(tt.want.EnvVars))
				} else {
					for i, v := range cfg.EnvVars {
						if v != tt.want.EnvVars[i] {
							t.Errorf("EnvVars[%d] = %q, want %q", i, v, tt.want.EnvVars[i])
						}
					}
				}
			}
			if tt.want.PassthroughArgs != nil {
				if len(cfg.PassthroughArgs) != len(tt.want.PassthroughArgs) {
					t.Errorf("PassthroughArgs length = %d, want %d", len(cfg.PassthroughArgs), len(tt.want.PassthroughArgs))
				} else {
					for i, a := range cfg.PassthroughArgs {
						if a != tt.want.PassthroughArgs[i] {
							t.Errorf("PassthroughArgs[%d] = %q, want %q", i, a, tt.want.PassthroughArgs[i])
						}
					}
				}
			}
		})
	}
}

func TestValidateMalformedRepos(t *testing.T) {
	malformed := []string{
		"../traversal",
		"owner/../other",
		"-invalid/repo",
		"owner//repo",
		"",
		"noslash",
	}

	for _, repo := range malformed {
		t.Run(repo, func(t *testing.T) {
			cfg := &Config{
				Repo:    repo,
				Harness: "claude",
			}
			err := cfg.Validate()
			if err == nil {
				t.Errorf("Validate() should reject malformed repo %q", repo)
			}
		})
	}
}

func TestConfigValidate(t *testing.T) {
	tests := []struct {
		name    string
		cfg     *Config
		wantErr bool
	}{
		{
			name: "valid config",
			cfg: &Config{
				Repo:    "jlaska/agent-sandbox",
				Harness: "claude",
			},
			wantErr: false,
		},
		{
			name: "missing repo",
			cfg: &Config{
				Harness: "claude",
			},
			wantErr: true,
		},
		{
			name: "missing harness",
			cfg: &Config{
				Repo: "jlaska/agent-sandbox",
			},
			wantErr: true,
		},
		{
			name: "unknown harness",
			cfg: &Config{
				Repo:    "jlaska/agent-sandbox",
				Harness: "invalid",
			},
			wantErr: true,
		},
		{
			name: "any valid repo accepted",
			cfg: &Config{
				Repo:    "unknown/repo",
				Harness: "claude",
			},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cfg.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
