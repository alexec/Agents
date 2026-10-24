package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// #2019, M5: what a machine reports is each server and skill from a catalogue, personal
// and in its folders, once each, with no folder.
func TestTheGovernanceReportIsTheCatalogueSidecars(t *testing.T) {
	d, _ := start(t, t.TempDir())
	root := d.Store.Loc.Root
	home, app := t.TempDir(), filepath.Join(t.TempDir(), "app")
	d.PersonalHome = home
	writeMCPJSON(t, filepath.Join(home, ".agents", "mcp.json"), "github")
	writeMCPJSON(t, filepath.Join(app, ".agents", "mcp.json"), "github", "linear")
	os.WriteFile(filepath.Join(root, "catalog-mcp.json"), []byte(`{"version":1,"servers":{
		"personal/github":{"registryName":"io.github/github","version":"1.2.0","run":"remote","addedAt":"2026-10-01T00:00:00Z"},
		"`+app+`/github":{"registryName":"io.github/github","version":"1.2.0","run":"remote","addedAt":"2026-10-01T00:00:00Z"},
		"`+app+`/linear":{"registryName":"","version":"","run":"remote","addedAt":"2026-10-01T00:00:00Z","byHand":true}}}`), 0o600)
	os.WriteFile(filepath.Join(root, "catalog-skills.json"), []byte(`{"version":1,"skills":{
		"personal/review":{"commit":"0123456789abcdef0123","treeSHA":"t","catalogue":"anthropics/skills","addedAt":"2026-10-01T00:00:00Z"}}}`), 0o600)
	got := d.governanceItems()
	if len(got) != 3 {
		t.Fatalf("%+v", got)
	}
	if g := got[0]; g.Kind != wire.CatalogKindMCP || g.Name != "github" || deref(g.Version) != "1.2.0" || deref(g.Source) != "io.github/github" {
		t.Fatalf("%+v", g)
	}
	if g := got[1]; g.Name != "linear" || g.Version != nil || g.ByHand == nil || !*g.ByHand {
		t.Fatalf("%+v", g)
	}
	if g := got[2]; g.Kind != wire.CatalogKindSkills || deref(g.Version) != "0123456789ab" || deref(g.Source) != "anthropics/skills" {
		t.Fatalf("%+v", g)
	}
	// A file that does not decode says nothing, and stays where it is.
	os.WriteFile(filepath.Join(root, "catalog-mcp.json"), []byte(`{`), 0o600)
	if got := d.governanceItems(); len(got) != 1 {
		t.Fatalf("%+v", got)
	}
	if _, err := os.Stat(filepath.Join(root, "catalog-mcp.json")); err != nil {
		t.Fatal(err)
	}
}

// #2505: a sidecar entry whose server has left its mcp.json (by hand: the daemon's Remove
// path prunes the sidecar) is not reported, personal or in a folder. An mcp.json that is
// not valid settles nothing, so its entries stay.
func TestTheGovernanceReportDropsAServerGoneFromMCPJSON(t *testing.T) {
	d, _ := start(t, t.TempDir())
	root := d.Store.Loc.Root
	home, app := t.TempDir(), filepath.Join(t.TempDir(), "app")
	d.PersonalHome = home
	writeMCPJSON(t, filepath.Join(home, ".agents", "mcp.json"))
	writeMCPJSON(t, filepath.Join(app, ".agents", "mcp.json"), "linear")
	os.WriteFile(filepath.Join(root, "catalog-mcp.json"), []byte(`{"version":1,"servers":{
		"personal/obsidian":{"registryName":"ai.smithery/obsidian","version":"0.4.0","run":"remote","addedAt":"2026-10-05T00:00:00Z"},
		"`+app+`/github":{"registryName":"io.github/github","version":"1.2.0","run":"remote","addedAt":"2026-10-01T00:00:00Z"},
		"`+app+`/linear":{"registryName":"io.github/linear","version":"2.0.0","run":"remote","addedAt":"2026-10-01T00:00:00Z"}}}`), 0o600)
	got := d.governanceItems()
	if len(got) != 1 || got[0].Name != "linear" {
		t.Fatalf("%+v", got)
	}
	// The personal mcp.json gone altogether: its servers are gone too.
	os.Remove(filepath.Join(home, ".agents", "mcp.json"))
	if got := d.governanceItems(); len(got) != 1 || got[0].Name != "linear" {
		t.Fatalf("%+v", got)
	}
	// One that is not valid JSON settles nothing.
	os.WriteFile(filepath.Join(app, ".agents", "mcp.json"), []byte(`{`), 0o600)
	if got := d.governanceItems(); len(got) != 2 || got[0].Name != "github" || got[1].Name != "linear" {
		t.Fatalf("%+v", got)
	}
}

// writeMCPJSON writes an mcp.json with a remote server of each name.
func writeMCPJSON(t *testing.T, path string, names ...string) {
	t.Helper()
	servers := map[string]any{}
	for _, n := range names {
		servers[n] = map[string]any{"url": "https://example.com/" + n}
	}
	b, _ := json.Marshal(map[string]any{"mcpServers": servers})
	os.MkdirAll(filepath.Dir(path), 0o700)
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
}
