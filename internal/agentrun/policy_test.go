package agentrun

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseRepo(t *testing.T) {
	tests := []struct {
		input     string
		wantOwner string
		wantName  string
		wantErr   bool
	}{
		{"jlaska/agent-sandbox", "jlaska", "agent-sandbox", false},
		{"jlaska/homelab", "jlaska", "homelab", false},
		{"org/repo-name", "org", "repo-name", false},
		{"org/repo.name", "org", "repo.name", false},
		{"org/repo_name", "org", "repo_name", false},
		{"Org-123/Repo-456", "Org-123", "Repo-456", false},
		// Invalid
		{"", "", "", true},
		{"noslash", "", "", true},
		{"/leadingslash", "", "", true},
		{"trailingslash/", "", "", true},
		{"../traversal", "", "", true},
		{"owner/../traversal", "", "", true},
		{"owner/repo/../other", "", "", true},
		{"owner/repo/extra", "", "", true},
		{"owner//repo", "", "", true},
		{"-invalid/repo", "", "", true},
		{"owner/-invalid", "", "", true},
		{"invalid-/repo", "", "", true},
		{"owner/invalid-", "", "", true},
		{"own er/repo", "", "", true},
		{"owner/re po", "", "", true},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			owner, name, err := ParseRepo(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseRepo(%q) error = %v, wantErr %v", tt.input, err, tt.wantErr)
				return
			}
			if !tt.wantErr {
				if owner != tt.wantOwner {
					t.Errorf("owner = %q, want %q", owner, tt.wantOwner)
				}
				if name != tt.wantName {
					t.Errorf("name = %q, want %q", name, tt.wantName)
				}
			}
		})
	}
}

// setupPolicyTemplate creates a temp directory with the sandbox-policy.yaml template.
func setupPolicyTemplate(t *testing.T) string {
	t.Helper()
	tmpDir := t.TempDir()
	policyDir := filepath.Join(tmpDir, "openshell")
	if err := os.MkdirAll(policyDir, 0o755); err != nil {
		t.Fatal(err)
	}

	template := `network_policies:
  github_git:
    rules:
      - path: "/{{.Owner}}/{{.Repo}}.git/info/refs"
      - path: "/{{.Owner}}/{{.Repo}}.git/git-upload-pack"
      - path: "/{{.Owner}}/{{.Repo}}.git/git-receive-pack"
  github_api:
    rules:
      - path: "/repos/{{.Owner}}/{{.Repo}}"
      - path: "/repos/{{.Owner}}/{{.Repo}}/**"
      - path: "/repos/{{.Owner}}/{{.Repo}}/pulls"
  github_graphql:
    deny_rules:
      - fields: [mergePullRequest, enablePullRequestAutoMerge]
`
	if err := os.WriteFile(filepath.Join(policyDir, "sandbox-policy.yaml"), []byte(template), 0o644); err != nil {
		t.Fatal(err)
	}
	return tmpDir
}

func TestGeneratePolicy_SandboxTest(t *testing.T) {
	repoRoot := setupPolicyTemplate(t)

	result, err := GeneratePolicy("jlaska/agent-sandbox", repoRoot)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer func() { _ = os.Remove(result) }()

	content, err := os.ReadFile(result)
	if err != nil {
		t.Fatal(err)
	}
	policy := string(content)

	if !strings.Contains(policy, "jlaska/agent-sandbox") {
		t.Error("policy must contain jlaska/agent-sandbox")
	}
	if strings.Contains(policy, "jlaska/homelab") {
		t.Error("policy must NOT contain jlaska/homelab")
	}
	if strings.Contains(policy, "{{.Owner}}") || strings.Contains(policy, "{{.Repo}}") {
		t.Error("policy contains unresolved template placeholders")
	}
}

func TestGeneratePolicy_Homelab(t *testing.T) {
	repoRoot := setupPolicyTemplate(t)

	result, err := GeneratePolicy("jlaska/homelab", repoRoot)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer func() { _ = os.Remove(result) }()

	content, err := os.ReadFile(result)
	if err != nil {
		t.Fatal(err)
	}
	policy := string(content)

	if !strings.Contains(policy, "jlaska/homelab") {
		t.Error("policy must contain jlaska/homelab")
	}
	if strings.Contains(policy, "agent-sandbox") {
		t.Error("policy must NOT contain agent-sandbox")
	}
}

func TestGeneratePolicy_ContainsExpectedRules(t *testing.T) {
	repoRoot := setupPolicyTemplate(t)
	result, err := GeneratePolicy("jlaska/agent-sandbox", repoRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Remove(result) }()

	content, err := os.ReadFile(result)
	if err != nil {
		t.Fatal(err)
	}
	policy := string(content)

	// Allowed Git operations
	for _, expected := range []string{
		"git-upload-pack",
		"git-receive-pack",
		"info/refs",
	} {
		if !strings.Contains(policy, expected) {
			t.Errorf("policy missing expected Git operation: %s", expected)
		}
	}

	// Allowed PR/comment/review operations
	for _, expected := range []string{
		"/pulls",
	} {
		if !strings.Contains(policy, expected) {
			t.Errorf("policy missing expected API path: %s", expected)
		}
	}

	// Merge operations must be denied
	if !strings.Contains(policy, "mergePullRequest") {
		t.Error("policy must contain mergePullRequest denial")
	}
	if !strings.Contains(policy, "enablePullRequestAutoMerge") {
		t.Error("policy must contain enablePullRequestAutoMerge denial")
	}
}

func TestGeneratePolicy_MalformedRepo(t *testing.T) {
	repoRoot := setupPolicyTemplate(t)

	malformed := []string{
		"",
		"noslash",
		"../traversal",
		"owner/../other",
		"-bad/repo",
		"owner/-bad",
	}

	for _, repo := range malformed {
		t.Run(repo, func(t *testing.T) {
			_, err := GeneratePolicy(repo, repoRoot)
			if err == nil {
				t.Errorf("GeneratePolicy(%q) should fail for malformed repo", repo)
			}
		})
	}
}

func TestGeneratePolicy_NoDuplicateRepos(t *testing.T) {
	repoRoot := setupPolicyTemplate(t)
	result, err := GeneratePolicy("jlaska/agent-sandbox", repoRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Remove(result) }()

	content, err := os.ReadFile(result)
	if err != nil {
		t.Fatal(err)
	}
	policy := string(content)

	count := strings.Count(policy, "jlaska/agent-sandbox")
	// Count how many unique path entries reference the repo
	lines := strings.Split(policy, "\n")
	repoLines := 0
	for _, line := range lines {
		if strings.Contains(line, "jlaska/agent-sandbox") {
			repoLines++
		}
	}
	if count != repoLines {
		t.Errorf("unexpected repo reference count mismatch: total=%d lines=%d", count, repoLines)
	}
}

func TestGeneratePolicy_MissingTemplate(t *testing.T) {
	emptyDir := t.TempDir()
	_, err := GeneratePolicy("jlaska/agent-sandbox", emptyDir)
	if err == nil {
		t.Error("expected error for missing policy template")
	}
}

func TestGeneratePolicy_NoWildcardRepoWrite(t *testing.T) {
	repoRoot := setupPolicyTemplate(t)
	result, err := GeneratePolicy("jlaska/agent-sandbox", repoRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Remove(result) }()

	content, err := os.ReadFile(result)
	if err != nil {
		t.Fatal(err)
	}
	policy := string(content)

	// Ensure no wildcard write rule for /repos/**
	lines := strings.Split(policy, "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == `path: "/repos/**"` {
			// Check if the preceding lines indicate a write method
			for j := i - 1; j >= 0 && j >= i-3; j-- {
				prev := strings.TrimSpace(lines[j])
				if prev == "method: POST" || prev == "method: PUT" || prev == "method: PATCH" || prev == "method: DELETE" {
					t.Errorf("found wildcard /repos/** with write method %s at line %d", prev, j+1)
				}
			}
		}
	}
}
