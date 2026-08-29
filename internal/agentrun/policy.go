package agentrun

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"text/template"
)

// repoPattern validates owner/repo format: alphanumeric, hyphens, underscores, dots.
var repoPattern = regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?/[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$`)

// ParseRepo splits "owner/repo" into its components with validation.
func ParseRepo(repo string) (owner, name string, err error) {
	if repo == "" {
		return "", "", fmt.Errorf("repository cannot be empty")
	}

	parts := strings.SplitN(repo, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", fmt.Errorf("repository must be in owner/repo format: %q", repo)
	}

	owner, name = parts[0], parts[1]

	if !repoPattern.MatchString(repo) {
		return "", "", fmt.Errorf("invalid repository name %q: must contain only alphanumeric, hyphens, underscores, dots", repo)
	}

	if strings.Contains(owner, "..") || strings.Contains(name, "..") {
		return "", "", fmt.Errorf("repository name contains path traversal: %q", repo)
	}

	if strings.Contains(name, "/") {
		return "", "", fmt.Errorf("repository name contains extra path separator: %q", repo)
	}

	return owner, name, nil
}

// policyData is passed to the sandbox policy template.
type policyData struct {
	Owner string
	Repo  string
}

// GeneratePolicy generates a repository-scoped sandbox policy from the template.
// Returns the path to a temporary file containing the generated policy.
func GeneratePolicy(repo, repoRoot string) (string, error) {
	owner, name, err := ParseRepo(repo)
	if err != nil {
		return "", fmt.Errorf("invalid repository: %w", err)
	}

	templatePath := filepath.Join(repoRoot, "openshell", "sandbox-policy.yaml")
	content, err := os.ReadFile(templatePath)
	if err != nil {
		return "", fmt.Errorf("failed to read policy template: %w", err)
	}

	tmpl, err := template.New("policy").Parse(string(content))
	if err != nil {
		return "", fmt.Errorf("failed to parse policy template: %w", err)
	}

	var buf strings.Builder
	if err := tmpl.Execute(&buf, policyData{Owner: owner, Repo: name}); err != nil {
		return "", fmt.Errorf("failed to execute policy template: %w", err)
	}

	result := buf.String()

	// Validate: the generated policy must contain exactly the requested repo
	// and no other well-known repos.
	fullRepo := owner + "/" + name
	if !strings.Contains(result, fullRepo) {
		return "", fmt.Errorf("generated policy does not contain target repository %q", fullRepo)
	}

	// Check that no other known repos leaked into the policy.
	for _, approved := range ApprovedRepos {
		if approved != fullRepo && strings.Contains(result, approved) {
			return "", fmt.Errorf("generated policy contains unauthorized repository %q", approved)
		}
	}

	// Write to temp file
	tmpfile, err := os.CreateTemp("", "agent-run-policy.*.yaml")
	if err != nil {
		return "", fmt.Errorf("failed to create temp policy file: %w", err)
	}

	if _, err := tmpfile.WriteString(result); err != nil {
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
