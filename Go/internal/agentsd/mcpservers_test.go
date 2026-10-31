package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports SessionServersTests and MCPApprovalTests: the person's servers given with their
// secrets filled, one missing a secret left out, and a folder's new server waiting.

func TestASessionsMCPServers(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.MkdirAll(filepath.Join(home, ".agents-secrets"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers":{
		"github": {"command": "npx", "args": ["-y", "gh"], "env": {"GITHUB_TOKEN": "${GH}"}},
		"docs": {"url": "https://docs/${MISSING}"}, "old": {"type": "sse", "url": "https://old"}}}`), 0o644)
	os.WriteFile(filepath.Join(home, ".agents-secrets", "secrets.env"), []byte("# mine\nGH=abc\n"), 0o600)
	dir := folder(t, c, 1)
	// The host's first look approved what the folder had then (nothing); this one waits.
	os.MkdirAll(filepath.Join(dir, ".agents"), 0o755)
	os.WriteFile(filepath.Join(dir, ".agents", "mcp.json"), []byte(`{"mcpServers":{"tool": {"command": "tool"}}}`), 0o644)
	got := d.sessionMCP(dir)
	if len(got) != 2 || got[0].Stdio == nil || got[0].Stdio.Name != "github" || got[0].Stdio.Env[0].Value != "abc" || got[1].Sse == nil {
		b, _ := json.Marshal(got)
		t.Fatalf("%s", b)
	}
	var snap wire.MCPHealthSnapshot
	json.Unmarshal(c.call(t, 2, "mcp/health", nil), &snap)
	checks := map[string]wire.MCPCheckState{}
	for _, s := range snap.Servers {
		checks[s.Name] = s.Check
	}
	if checks["github"] != wire.MCPCheckStateUnchecked || checks["docs"] != wire.MCPCheckStateMissingSecret ||
		checks["old"] != wire.MCPCheckStateOldTransport || checks["tool"] != wire.MCPCheckStateWaiting {
		t.Fatalf("%+v", snap.Servers)
	}
	_ = store.FolderURL
}
