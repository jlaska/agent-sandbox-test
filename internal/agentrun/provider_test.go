package agentrun

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// mockCmd records calls and returns a configurable error.
type mockCmd struct {
	calls [][]string
	err   error
}

func (m *mockCmd) exec(name string, args ...string) error {
	m.calls = append(m.calls, append([]string{name}, args...))
	return m.err
}

func (m *mockCmd) execOutput(name string, args ...string) (string, error) {
	m.calls = append(m.calls, append([]string{name}, args...))
	return "", m.err
}

func withMockExec(t *testing.T, fn func(mock *mockCmd)) {
	t.Helper()
	origCmd := execCmdFn
	origSilent := execCmdSilentFn
	origOutput := execCmdOutputFn
	defer func() {
		execCmdFn = origCmd
		execCmdSilentFn = origSilent
		execCmdOutputFn = origOutput
	}()

	m := &mockCmd{}
	execCmdFn = m.exec
	execCmdSilentFn = m.exec
	execCmdOutputFn = m.execOutput
	fn(m)
}

// withMockKeychain sets up mock keychain responses for testing.
type keychainMock struct {
	values map[string]string
}

func withMockKeychain(t *testing.T, values map[string]string, fn func()) {
	t.Helper()
	origCmd := execCmdFn
	origSilent := execCmdSilentFn
	origOutput := execCmdOutputFn
	defer func() {
		execCmdFn = origCmd
		execCmdSilentFn = origSilent
		execCmdOutputFn = origOutput
	}()

	km := &keychainMock{values: values}

	mockExec := func(name string, args ...string) error {
		if name == "security" && len(args) >= 4 && args[0] == "find-generic-password" {
			svc := ""
			for i, a := range args {
				if a == "-s" && i+1 < len(args) {
					svc = args[i+1]
				}
			}
			if _, ok := km.values[svc]; ok {
				return nil
			}
			return fmt.Errorf("not found")
		}
		return nil
	}

	mockOutput := func(name string, args ...string) (string, error) {
		if name == "security" && len(args) >= 4 && args[0] == "find-generic-password" {
			svc := ""
			for i, a := range args {
				if a == "-s" && i+1 < len(args) {
					svc = args[i+1]
				}
			}
			if v, ok := km.values[svc]; ok {
				return v, nil
			}
			return "", fmt.Errorf("not found")
		}
		if name == "openshell" && len(args) > 0 && args[0] == "provider" {
			return "litellm-inference\n", nil
		}
		return "", nil
	}

	execCmdFn = mockExec
	execCmdSilentFn = mockExec
	execCmdOutputFn = mockOutput
	fn()
}

func TestSetupProvider(t *testing.T) {
	tests := []struct {
		name     string
		provider string
		harness  string
		max      bool
		wantHook string
		wantErr  bool
	}{
		{
			name:     "unknown provider",
			provider: "unknown",
			harness:  "claude",
			wantErr:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			withMockExec(t, func(mock *mockCmd) {
				hook, _, _, err := setupProvider(tt.provider, tt.harness, tt.max)
				if (err != nil) != tt.wantErr {
					t.Errorf("setupProvider() error = %v, wantErr %v", err, tt.wantErr)
					return
				}
				if !tt.wantErr && hook != tt.wantHook {
					t.Errorf("setupProvider() hook = %v, want %v", hook, tt.wantHook)
				}
			})
		})
	}
}

func TestSetupProviderLiteLLM(t *testing.T) {
	t.Run("missing litellm-api-key", func(t *testing.T) {
		withMockKeychain(t, map[string]string{}, func() {
			_, _, _, err := setupProviderLiteLLM("claude", false)
			if err == nil || !strings.Contains(err.Error(), "litellm-api-key") {
				t.Errorf("expected litellm-api-key error, got %v", err)
			}
		})
	})

	t.Run("missing anthropic-base-url", func(t *testing.T) {
		withMockKeychain(t, map[string]string{
			"litellm-api-key": "test-key",
		}, func() {
			_, _, _, err := setupProviderLiteLLM("claude", false)
			if err == nil || !strings.Contains(err.Error(), "anthropic-base-url") {
				t.Errorf("expected anthropic-base-url error, got %v", err)
			}
		})
	})

	t.Run("claude with max but no bearer token", func(t *testing.T) {
		withMockKeychain(t, map[string]string{
			"litellm-api-key":    "test-key",
			"anthropic-base-url": "https://test.example.com",
		}, func() {
			_, _, _, err := setupProviderLiteLLM("claude", true)
			if err == nil || !strings.Contains(err.Error(), "litellm-bearer-token") {
				t.Errorf("expected bearer-token error, got %v", err)
			}
		})
	})

	t.Run("claude success", func(t *testing.T) {
		withMockKeychain(t, map[string]string{
			"litellm-api-key":    "test-key",
			"anthropic-base-url": "https://test.example.com",
		}, func() {
			hook, providers, envFlags, err := setupProviderLiteLLM("claude", false)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if hook != "setup_sandbox_litellm" {
				t.Errorf("hook = %v, want setup_sandbox_litellm", hook)
			}
			if len(providers) != 2 {
				t.Errorf("expected 2 providers (litellm-inference, claude-code), got %d", len(providers))
			}
			hasBaseURL := false
			for _, f := range envFlags {
				if strings.Contains(f, "ANTHROPIC_BASE_URL") {
					hasBaseURL = true
				}
			}
			if !hasBaseURL {
				t.Error("missing ANTHROPIC_BASE_URL in envFlags")
			}
		})
	})

	t.Run("pi success", func(t *testing.T) {
		withMockKeychain(t, map[string]string{
			"litellm-api-key":    "test-key",
			"anthropic-base-url": "https://test.example.com",
		}, func() {
			_, providers, envFlags, err := setupProviderLiteLLM("pi", false)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(providers) != 1 {
				t.Errorf("expected 1 provider (litellm-inference), got %d", len(providers))
			}
			hasLiteLLMURL := false
			for _, f := range envFlags {
				if strings.Contains(f, "LITELLM_BASE_URL") {
					hasLiteLLMURL = true
				}
			}
			if !hasLiteLLMURL {
				t.Error("missing LITELLM_BASE_URL in envFlags")
			}
		})
	})

	t.Run("claude with max success", func(t *testing.T) {
		withMockKeychain(t, map[string]string{
			"litellm-api-key":      "test-key",
			"anthropic-base-url":   "https://test.example.com",
			"litellm-bearer-token": "bearer-val",
		}, func() {
			_, _, envFlags, err := setupProviderLiteLLM("claude", true)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			hasCustomHeader := false
			for _, f := range envFlags {
				if strings.Contains(f, "ANTHROPIC_CUSTOM_HEADERS") {
					hasCustomHeader = true
				}
			}
			if !hasCustomHeader {
				t.Error("missing ANTHROPIC_CUSTOM_HEADERS in envFlags for --max")
			}
		})
	})
}

func TestSetupProviderVertex(t *testing.T) {
	t.Run("non-claude harness rejected", func(t *testing.T) {
		withMockExec(t, func(_ *mockCmd) {
			_, _, _, err := setupProviderVertex("pi", false)
			if err == nil || !strings.Contains(err.Error(), "only supports the claude harness") {
				t.Errorf("expected harness error, got %v", err)
			}
		})
	})

	t.Run("max rejected", func(t *testing.T) {
		withMockExec(t, func(_ *mockCmd) {
			_, _, _, err := setupProviderVertex("claude", true)
			if err == nil || !strings.Contains(err.Error(), "--max") {
				t.Errorf("expected max error, got %v", err)
			}
		})
	})

	t.Run("missing ADC", func(t *testing.T) {
		withMockExec(t, func(_ *mockCmd) {
			origHome := os.Getenv("HOME")
			t.Setenv("HOME", t.TempDir())
			defer func() { _ = os.Setenv("HOME", origHome) }()
			_, _, _, err := setupProviderVertex("claude", false)
			if err == nil || !strings.Contains(err.Error(), "gcloud ADC") {
				t.Errorf("expected ADC error, got %v", err)
			}
		})
	})
}

func TestSetupProviderAPI(t *testing.T) {
	t.Run("non-claude harness rejected", func(t *testing.T) {
		withMockExec(t, func(_ *mockCmd) {
			_, _, _, err := setupProviderAPI("pi", false)
			if err == nil || !strings.Contains(err.Error(), "only supports the claude harness") {
				t.Errorf("expected harness error, got %v", err)
			}
		})
	})

	t.Run("max rejected", func(t *testing.T) {
		withMockExec(t, func(_ *mockCmd) {
			_, _, _, err := setupProviderAPI("claude", true)
			if err == nil || !strings.Contains(err.Error(), "--max") {
				t.Errorf("expected max error, got %v", err)
			}
		})
	})

	t.Run("missing credentials", func(t *testing.T) {
		withMockKeychain(t, map[string]string{}, func() {
			_, _, _, err := setupProviderAPI("claude", false)
			if err == nil || !strings.Contains(err.Error(), "missing Keychain") {
				t.Errorf("expected missing keychain error, got %v", err)
			}
		})
	})

	t.Run("success with direct key", func(t *testing.T) {
		withMockKeychain(t, map[string]string{
			"anthropic-api-key-direct": "sk-test",
		}, func() {
			hook, providers, _, err := setupProviderAPI("claude", false)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if hook != "setup_sandbox_api" {
				t.Errorf("hook = %v, want setup_sandbox_api", hook)
			}
			if len(providers) != 1 || providers[0] != "claude-code" {
				t.Errorf("providers = %v, want [claude-code]", providers)
			}
		})
	})

	t.Run("fallback to litellm key", func(t *testing.T) {
		withMockKeychain(t, map[string]string{
			"litellm-api-key": "sk-fallback",
		}, func() {
			_, providers, _, err := setupProviderAPI("claude", false)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(providers) != 1 || providers[0] != "claude-code" {
				t.Errorf("providers = %v, want [claude-code]", providers)
			}
		})
	})
}

func TestRunSandboxInitHook(t *testing.T) {
	tests := []struct {
		name    string
		hook    string
		wantErr bool
	}{
		{"litellm hook", "setup_sandbox_litellm", false},
		{"vertex hook", "setup_sandbox_vertex", false},
		{"api hook", "setup_sandbox_api", false},
		{"unknown hook", "unknown", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			withMockExec(t, func(_ *mockCmd) {
				err := runSandboxInitHook(tt.hook, "claude", "test-sandbox")
				if (err != nil) != tt.wantErr {
					t.Errorf("runSandboxInitHook() error = %v, wantErr %v", err, tt.wantErr)
				}
			})
		})
	}
}

func TestSetupSandboxLiteLLM(t *testing.T) {
	t.Run("claude configures ANTHROPIC_API_KEY", func(t *testing.T) {
		withMockExec(t, func(mock *mockCmd) {
			err := setupSandboxLiteLLM("claude", "test-sb")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(mock.calls) != 1 {
				t.Fatalf("expected 1 call, got %d", len(mock.calls))
			}
			cmd := strings.Join(mock.calls[0], " ")
			if !strings.Contains(cmd, "ANTHROPIC_API_KEY") {
				t.Error("expected ANTHROPIC_API_KEY in sandbox init")
			}
		})
	})

	t.Run("pi configures LITELLM_API_KEY", func(t *testing.T) {
		withMockExec(t, func(mock *mockCmd) {
			err := setupSandboxLiteLLM("pi", "test-sb")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			cmd := strings.Join(mock.calls[0], " ")
			if !strings.Contains(cmd, "LITELLM_API_KEY") {
				t.Error("expected LITELLM_API_KEY in sandbox init")
			}
		})
	})

	t.Run("shell is noop", func(t *testing.T) {
		withMockExec(t, func(mock *mockCmd) {
			err := setupSandboxLiteLLM("shell", "test-sb")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(mock.calls) != 0 {
				t.Errorf("expected 0 calls for shell, got %d", len(mock.calls))
			}
		})
	})
}

func TestSetupSandboxVertex(t *testing.T) {
	withMockExec(t, func(_ *mockCmd) {
		err := setupSandboxVertex("claude", "test-sb")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	})
}

func TestSetupSandboxAPI(t *testing.T) {
	withMockExec(t, func(mock *mockCmd) {
		err := setupSandboxAPI("claude", "test-sb")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(mock.calls) != 1 {
			t.Fatalf("expected 1 call, got %d", len(mock.calls))
		}
		cmd := strings.Join(mock.calls[0], " ")
		if !strings.Contains(cmd, "ANTHROPIC_API_KEY") {
			t.Error("expected ANTHROPIC_API_KEY in sandbox init")
		}
	})
}

func TestInstallHarness(t *testing.T) {
	t.Run("pi installs npm package", func(t *testing.T) {
		withMockExec(t, func(mock *mockCmd) {
			err := installHarness("pi", "test-sb")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(mock.calls) < 2 {
				t.Fatalf("expected at least 2 calls (install + path setup), got %d", len(mock.calls))
			}
		})
	})

	t.Run("claude is noop", func(t *testing.T) {
		withMockExec(t, func(mock *mockCmd) {
			err := installHarness("claude", "test-sb")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(mock.calls) != 0 {
				t.Errorf("expected 0 calls for claude, got %d", len(mock.calls))
			}
		})
	})

	t.Run("shell is noop", func(t *testing.T) {
		withMockExec(t, func(mock *mockCmd) {
			err := installHarness("shell", "test-sb")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(mock.calls) != 0 {
				t.Errorf("expected 0 calls for shell, got %d", len(mock.calls))
			}
		})
	})
}

func TestOrDefault(t *testing.T) {
	tests := []struct {
		s, def, want string
	}{
		{"value", "default", "value"},
		{"", "default", "default"},
		{"", "", ""},
	}

	for _, tt := range tests {
		got := orDefault(tt.s, tt.def)
		if got != tt.want {
			t.Errorf("orDefault(%q, %q) = %q, want %q", tt.s, tt.def, got, tt.want)
		}
	}
}

func TestFindRepoRoot(t *testing.T) {
	t.Run("finds openshell directory", func(t *testing.T) {
		root := findRepoRoot()
		if root == "" {
			t.Error("findRepoRoot returned empty")
		}
	})
}
