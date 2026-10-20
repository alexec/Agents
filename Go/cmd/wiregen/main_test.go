package main

import (
	"os"
	"path/filepath"
	"strings"
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

// Each method names its capability, and the generator refuses one that does not (#1748).
func TestEveryMethodNamesACapability(t *testing.T) {
	doc := &Document{Definitions: map[string]*Schema{}}
	method := func(capability string) []byte {
		c := ""
		if capability != "" {
			c = `"x-capability": "` + capability + `",`
		}
		return []byte(`{"methods": [{"name": "agents/find", ` + c + ` "params": [{"name": "params", "schema": {"type": "object"}}], "result": {"schema": {"type": "object"}}}]}`)
	}
	for _, bad := range []string{"", "agents", "agents/0", "Agents/1", "agents/find/1", "agents..find/1"} {
		if _, err := readRPC(method(bad), "host", doc); err == nil || !strings.Contains(err.Error(), "agents/find") {
			t.Errorf("x-capability %q: err = %v, want one that names the method", bad, err)
		}
	}
	for _, good := range []string{"agents/1", "chat.branch/1", "agents.edit-queued/2", "mcp.made-by-agents/10"} {
		rpc, err := readRPC(method(good), "host", doc)
		if err != nil || rpc.Methods[0].Capability != good {
			t.Errorf("x-capability %q: %v", good, err)
		}
	}
}

func TestCapabilityWord(t *testing.T) {
	for in, want := range map[string]string{
		"agents/1": "agents1", "chat.branch/1": "chatBranch1", "agents.edit-queued/1": "agentsEditQueued1",
		"client-permissions/1": "clientPermissions1",
	} {
		if got := capabilityWord(in); got != want {
			t.Errorf("capabilityWord(%q) = %q, want %q", in, got, want)
		}
	}
}

