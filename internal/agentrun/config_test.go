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
			name:    "valid claude with litellm",
			args:    []string{"jlaska/agent-sandbox-test", "claude"},
			wantErr: false,
			want: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "claude",
				Provider: "litellm",
			},
		},
		{
			name:    "valid pi with default provider",
			args:    []string{"jlaska/agent-sandbox-test", "pi"},
			wantErr: false,
			want: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "pi",
				Provider: "litellm",
			},
		},
		{
			name:    "valid shell with explicit none",
			args:    []string{"jlaska/agent-sandbox-test", "shell", "--provider", "none"},
			wantErr: false,
			want: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "shell",
				Provider: "none",
			},
		},
		{
			name:    "claude with vertex",
			args:    []string{"jlaska/agent-sandbox-test", "claude", "--provider", "vertex"},
			wantErr: false,
			want: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "claude",
				Provider: "vertex",
			},
		},
		{
			name:    "claude with api",
			args:    []string{"jlaska/agent-sandbox-test", "claude", "--provider", "api"},
			wantErr: false,
			want: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "claude",
				Provider: "api",
			},
		},
		{
			name:    "with model override",
			args:    []string{"jlaska/agent-sandbox-test", "claude", "--model", "claude-3-opus"},
			wantErr: false,
			want: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "claude",
				Provider: "litellm",
				Model:    "claude-3-opus",
			},
		},
		{
			name:    "with max flag",
			args:    []string{"jlaska/agent-sandbox-test", "claude", "--max"},
			wantErr: false,
			want: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "claude",
				Provider: "litellm",
				Max:      true,
			},
		},
		{
			name:    "missing repository",
			args:    []string{"claude"},
			wantErr: true,
		},
		{
			name:    "unknown harness",
			args:    []string{"jlaska/agent-sandbox-test", "unknown"},
			wantErr: true,
		},
		{
			name:    "unknown provider",
			args:    []string{"jlaska/agent-sandbox-test", "claude", "--provider", "unknown"},
			wantErr: true,
		},
		{
			name:    "incompatible harness/provider",
			args:    []string{"jlaska/agent-sandbox-test", "pi", "--provider", "vertex"},
			wantErr: true,
		},
		{
			name:    "unapproved repository",
			args:    []string{"unknown/repo", "claude"},
			wantErr: true,
		},
		{
			name:    "max with non-litellm",
			args:    []string{"jlaska/agent-sandbox-test", "claude", "--provider", "vertex", "--max"},
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
			if cfg.Provider != tt.want.Provider {
				t.Errorf("Provider = %v, want %v", cfg.Provider, tt.want.Provider)
			}
			if cfg.Model != tt.want.Model {
				t.Errorf("Model = %v, want %v", cfg.Model, tt.want.Model)
			}
			if cfg.Max != tt.want.Max {
				t.Errorf("Max = %v, want %v", cfg.Max, tt.want.Max)
			}
		})
	}
}

func TestHarnessSupportsProvider(t *testing.T) {
	tests := []struct {
		harness  string
		provider string
		want     bool
	}{
		{HarnessClaude, ProviderLiteLLM, true},
		{HarnessClaude, ProviderVertex, true},
		{HarnessClaude, ProviderAPI, true},
		{HarnessClaude, ProviderNone, false},
		{HarnessPi, ProviderLiteLLM, true},
		{HarnessPi, ProviderVertex, false},
		{HarnessPi, ProviderAPI, false},
		{HarnessPi, ProviderNone, false},
		{HarnessShell, ProviderLiteLLM, false},
		{HarnessShell, ProviderVertex, false},
		{HarnessShell, ProviderAPI, false},
		{HarnessShell, ProviderNone, true},
	}

	for _, tt := range tests {
		t.Run(tt.harness+"_"+tt.provider, func(t *testing.T) {
			got := harnessSupportsProvider(tt.harness, tt.provider)
			if got != tt.want {
				t.Errorf("harnessSupportsProvider(%v, %v) = %v, want %v", tt.harness, tt.provider, got, tt.want)
			}
		})
	}
}

func TestHarnessDefaultProvider(t *testing.T) {
	tests := []struct {
		harness string
		want    string
	}{
		{HarnessClaude, ProviderLiteLLM},
		{HarnessPi, ProviderLiteLLM},
		{HarnessShell, ProviderNone},
	}

	for _, tt := range tests {
		t.Run(tt.harness, func(t *testing.T) {
			got := harnessDefaultProvider(tt.harness)
			if got != tt.want {
				t.Errorf("harnessDefaultProvider(%v) = %v, want %v", tt.harness, got, tt.want)
			}
		})
	}
}

func TestIsApprovedRepo(t *testing.T) {
	tests := []struct {
		repo string
		want bool
	}{
		{"jlaska/agent-sandbox-test", true},
		{"jlaska/homelab", true},
		{"unknown/repo", false},
		{"", false},
	}

	for _, tt := range tests {
		t.Run(tt.repo, func(t *testing.T) {
			got := isApprovedRepo(tt.repo)
			if got != tt.want {
				t.Errorf("isApprovedRepo(%v) = %v, want %v", tt.repo, got, tt.want)
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
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "claude",
				Provider: "litellm",
			},
			wantErr: false,
		},
		{
			name: "missing repo",
			cfg: &Config{
				Harness:  "claude",
				Provider: "litellm",
			},
			wantErr: true,
		},
		{
			name: "missing harness",
			cfg: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Provider: "litellm",
			},
			wantErr: true,
		},
		{
			name: "unknown harness",
			cfg: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "invalid",
				Provider: "litellm",
			},
			wantErr: true,
		},
		{
			name: "unknown provider",
			cfg: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "claude",
				Provider: "invalid",
			},
			wantErr: true,
		},
		{
			name: "incompatible provider",
			cfg: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "pi",
				Provider: "vertex",
			},
			wantErr: true,
		},
		{
			name: "unapproved repo",
			cfg: &Config{
				Repo:     "unknown/repo",
				Harness:  "claude",
				Provider: "litellm",
			},
			wantErr: true,
		},
		{
			name: "max with non-litellm",
			cfg: &Config{
				Repo:     "jlaska/agent-sandbox-test",
				Harness:  "claude",
				Provider: "vertex",
				Max:      true,
			},
			wantErr: true,
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
