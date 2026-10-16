// Package sandbox confines a runtime (064): on Linux with Landlock, by a launcher that
// restricts itself and then execs the runtime, so every child it starts inherits it; on
// macOS with sandbox-exec and a generated profile (stage 5).
package sandbox

import (
	"fmt"
	"os"
	"runtime"
	"path/filepath"
	"strings"
)

// Policy is what a sandboxed runtime may touch.
type Policy struct {
	// Write: the agent's folder and what the runtime keeps of its own.
	Write []string
	// Network is not confined here: a runtime has to reach its provider.
}

// For is the policy for one runtime in one folder.
func For(runtimeID, dir string) Policy {
	home, _ := os.UserHomeDir()
	p := Policy{Write: []string{dir, os.TempDir()}}
	if runtime.GOOS == "linux" {
		p.Write = append(p.Write, "/dev/shm")
	}
	switch runtimeID {
	case "claude":
		p.Write = append(p.Write, filepath.Join(home, ".claude"), filepath.Join(home, ".claude.json"),
			filepath.Join(home, ".claude.json.backup"), filepath.Join(home, ".cache"), filepath.Join(home, ".npm"))
		if runtime.GOOS == "darwin" {
			// Claude Code's Bash keeps its shells' state here on a Mac.
			p.Write = append(p.Write, filepath.Join(home, "Library", "Caches", "claude-cli-nodejs"),
				fmt.Sprintf("/private/tmp/claude-%d", os.Getuid()))
		}
	case "codex":
		p.Write = append(p.Write, filepath.Join(home, ".codex"), filepath.Join(home, ".cache"))
	}
	if extra := os.Getenv("AGENTS_SANDBOX_WRITE"); extra != "" {
		p.Write = append(p.Write, strings.Split(extra, ":")...)
	}
	return p
}

// Argv is how agentsd starts a runtime under the policy: itself, as the launcher.
func Argv(self string, p Policy, argv []string) []string {
	out := []string{self, "sandbox-exec"}
	for _, w := range p.Write {
		out = append(out, "--write", w)
	}
	return append(append(out, "--"), argv...)
}
