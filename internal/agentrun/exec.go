package agentrun

import (
	"os"
	"os/exec"
	"strings"
)

// Command execution functions, replaceable in tests.
var (
	execCmdFn       = defaultExecCmd
	execCmdSilentFn = defaultExecCmdSilent
	execCmdOutputFn = defaultExecCmdOutput
)

func execCmd(name string, args ...string) error {
	return execCmdFn(name, args...)
}

func execCmdSilent(name string, args ...string) error {
	return execCmdSilentFn(name, args...)
}

func execCmdOutput(name string, args ...string) (string, error) {
	return execCmdOutputFn(name, args...)
}

func defaultExecCmd(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func defaultExecCmdSilent(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	return cmd.Run()
}

func defaultExecCmdOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// shellQuote wraps a string in single quotes for safe embedding in bash -c.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
