package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The generated files are what Packages/Wire makes now: a schema change was followed by
// scripts/wire.sh gen, and nobody edited a generated file by hand.
func TestGeneratedFilesAreFresh(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	files, err := generate(root)
	if err != nil {
		t.Fatal(err)
	}
	for path, made := range files {
		current, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			t.Fatal(err)
		}
		if string(current) != made {
			t.Errorf("%s is not what Packages/Wire makes; run scripts/wire.sh gen", path)
		}
	}
}

func TestGoName(t *testing.T) {
	for in, want := range map[string]string{
		"agentID": "AgentID", "_0": "Value", "_meta": "Meta", "resource_link": "ResourceLink",
		"mcp/health/check": "MCPHealthCheck", "url": "URL", "agents/start": "AgentsStart",
	} {
		if got := goName(in); got != want {
			t.Errorf("goName(%q) = %q, want %q", in, got, want)
		}
	}
}
