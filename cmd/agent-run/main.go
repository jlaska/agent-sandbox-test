package main

import (
	"fmt"
	"os"

	"github.com/jlaska/agent-sandbox/internal/agentrun"
)

func main() {
	cfg, err := agentrun.ParseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if err := agentrun.Run(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
