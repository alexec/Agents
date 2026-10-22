package agentsd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// #2019, M5: what a machine reports is each server and skill from a catalogue, personal
// and in its projects, once each, with no project folder.
func TestTheGovernanceReportIsTheCatalogueSidecars(t *testing.T) {
	d, _ := start(t, t.TempDir())
	root := d.Store.Loc.Root
	os.WriteFile(filepath.Join(root, "catalog-mcp.json"), []byte(`{"version":1,"servers":{
		"personal/github":{"registryName":"io.github/github","version":"1.2.0","run":"remote","addedAt":"2026-10-01T00:00:00Z"},
		"/Users/sam/app/github":{"registryName":"io.github/github","version":"1.2.0","run":"remote","addedAt":"2026-10-01T00:00:00Z"},
		"/Users/sam/app/linear":{"registryName":"","version":"","run":"remote","addedAt":"2026-10-01T00:00:00Z","byHand":true}}}`), 0o600)
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
