package agentrun

import (
	"strings"
	"testing"
)

// mockCmd records calls and returns a configurable error.
type mockCmd struct {
	calls      [][]string
	err        error
	execOutput func(string, ...string) (string, error)
}

func (m *mockCmd) exec(name string, args ...string) error {
	m.calls = append(m.calls, append([]string{name}, args...))
	return m.err
}

func (m *mockCmd) defaultExecOutput(name string, args ...string) (string, error) {
	m.calls = append(m.calls, append([]string{name}, args...))
	if m.execOutput != nil {
		return m.execOutput(name, args...)
	}
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
	execCmdOutputFn = m.defaultExecOutput
	fn(m)
}

func TestResolveInferenceEnv(t *testing.T) {
	t.Run("auto-forwards host env vars", func(t *testing.T) {
		t.Setenv("ANTHROPIC_API_KEY", "sk-test-key")
		t.Setenv("ANTHROPIC_BASE_URL", "https://example.com")

		flags := resolveInferenceEnv(HarnessClaude, nil)

		found := map[string]bool{}
		for i := 0; i < len(flags)-1; i += 2 {
			if flags[i] == "--env" {
				k, _, _ := strings.Cut(flags[i+1], "=")
				found[k] = true
			}
		}
		if !found["ANTHROPIC_API_KEY"] {
			t.Error("expected ANTHROPIC_API_KEY to be forwarded")
		}
		if !found["ANTHROPIC_BASE_URL"] {
			t.Error("expected ANTHROPIC_BASE_URL to be forwarded")
		}
	})

	t.Run("explicit env overrides host", func(t *testing.T) {
		t.Setenv("ANTHROPIC_API_KEY", "sk-from-host")

		flags := resolveInferenceEnv(HarnessClaude, []string{"ANTHROPIC_API_KEY=sk-explicit"})

		// Should have only the explicit value, not the host value
		count := 0
		for i := 0; i < len(flags)-1; i += 2 {
			if flags[i] == "--env" && strings.HasPrefix(flags[i+1], "ANTHROPIC_API_KEY=") {
				count++
				if flags[i+1] != "ANTHROPIC_API_KEY=sk-explicit" {
					t.Errorf("expected explicit value, got %s", flags[i+1])
				}
			}
		}
		if count != 1 {
			t.Errorf("expected exactly 1 ANTHROPIC_API_KEY entry, got %d", count)
		}
	})

	t.Run("unset host vars not forwarded", func(t *testing.T) {
		// Clear all known inference vars to ensure clean state
		for _, key := range inferenceEnvVars[HarnessClaude] {
			t.Setenv(key, "")
		}

		flags := resolveInferenceEnv(HarnessClaude, nil)
		if len(flags) != 0 {
			t.Errorf("expected no flags when no env vars set, got %v", flags)
		}
	})

	t.Run("pi harness forwards pi vars", func(t *testing.T) {
		t.Setenv("LITELLM_API_KEY", "sk-litellm")
		t.Setenv("LITELLM_BASE_URL", "https://litellm.example.com")

		flags := resolveInferenceEnv(HarnessPi, nil)

		found := map[string]bool{}
		for i := 0; i < len(flags)-1; i += 2 {
			if flags[i] == "--env" {
				k, _, _ := strings.Cut(flags[i+1], "=")
				found[k] = true
			}
		}
		if !found["LITELLM_API_KEY"] {
			t.Error("expected LITELLM_API_KEY forwarded for pi")
		}
		if !found["LITELLM_BASE_URL"] {
			t.Error("expected LITELLM_BASE_URL forwarded for pi")
		}
	})

	t.Run("shell harness forwards nothing", func(t *testing.T) {
		t.Setenv("ANTHROPIC_API_KEY", "sk-test")

		flags := resolveInferenceEnv(HarnessShell, nil)
		if len(flags) != 0 {
			t.Errorf("expected no auto-forward for shell, got %v", flags)
		}
	})

	t.Run("explicit env always included for any harness", func(t *testing.T) {
		flags := resolveInferenceEnv(HarnessShell, []string{"CUSTOM_VAR=val"})

		if len(flags) != 2 || flags[1] != "CUSTOM_VAR=val" {
			t.Errorf("expected explicit env for shell, got %v", flags)
		}
	})
}

func TestCreateInferenceProviders(t *testing.T) {
	t.Run("claude creates claude-code provider", func(t *testing.T) {
		withMockExec(t, func(mock *mockCmd) {
			flags, names, err := createInferenceProviders(HarnessClaude)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(names) != 1 || names[0] != "claude-code" {
				t.Errorf("names = %v, want [claude-code]", names)
			}
			if len(flags) != 2 || flags[0] != "--provider" || flags[1] != "claude-code" {
				t.Errorf("flags = %v, want [--provider claude-code]", flags)
			}
			// Should have called delete then create
			if len(mock.calls) != 2 {
				t.Errorf("expected 2 calls (delete + create), got %d", len(mock.calls))
			}
		})
	})

	t.Run("pi creates litellm-inference provider", func(t *testing.T) {
		withMockExec(t, func(mock *mockCmd) {
			mock.execOutput = func(name string, args ...string) (string, error) {
				if name == "openshell" && len(args) > 0 && args[0] == "provider" {
					return "litellm-inference\n", nil
				}
				return "", nil
			}
			execCmdOutputFn = mock.execOutput

			flags, names, err := createInferenceProviders(HarnessPi)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(names) != 1 || names[0] != "litellm-inference" {
				t.Errorf("names = %v, want [litellm-inference]", names)
			}
			if len(flags) != 2 || flags[0] != "--provider" || flags[1] != "litellm-inference" {
				t.Errorf("flags = %v, want [--provider litellm-inference]", flags)
			}
		})
	})

	t.Run("shell creates no providers", func(t *testing.T) {
		withMockExec(t, func(mock *mockCmd) {
			flags, names, err := createInferenceProviders(HarnessShell)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(names) != 0 {
				t.Errorf("expected no providers for shell, got %v", names)
			}
			if len(flags) != 0 {
				t.Errorf("expected no flags for shell, got %v", flags)
			}
		})
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

func TestShellQuote(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"hello", "'hello'"},
		{"fix the bug", "'fix the bug'"},
		{"it's a test", `'it'\''s a test'`},
		{"", "''"},
		{"--model=opus", "'--model=opus'"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := shellQuote(tt.input)
			if got != tt.want {
				t.Errorf("shellQuote(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
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
