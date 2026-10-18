package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A shipped MCP server named by its bare name (`github-mcp`) is the one beside agentsd,
// first on PATH, though the login shell's PATH has no such folder (#1389).
func TestAShippedMCPServerIsFoundBesideTheHost(t *testing.T) {
	dir := t.TempDir()
	server := filepath.Join(dir, "github-mcp")
	if err := os.WriteFile(server, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := shippedServers
	shippedServers = func() string { return dir }
	defer func() { shippedServers = old }()
	env := mcpEnvironment()
	var path string
	for _, kv := range env {
		if p, ok := strings.CutPrefix(kv, "PATH="); ok {
			path = p
		}
	}
	if !strings.HasPrefix(path, dir+":") || !strings.Contains(path, "/usr/bin") {
		t.Fatalf("PATH %q", path)
	}
	if cmd := loginCommand(env, "github-mcp"); cmd.Path != server {
		t.Fatalf("%s", cmd.Path)
	}
	// A runtime's PATH is not changed: the folder stays last there.
	for _, kv := range loginEnvironment() {
		if p, ok := strings.CutPrefix(kv, "PATH="); ok && strings.HasPrefix(p, dir) {
			t.Fatal(p)
		}
	}
}
