package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// What agents call the person is person.json in the person's settings, said to windows.
func TestThePersonIsKeptInTheirSettings(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var p wire.PersonSettings
	json.Unmarshal(c.call(t, 1, "person/state", nil), &p)
	if p.Name != nil {
		t.Fatalf("%+v", p)
	}
	c.call(t, 2, "person/set", map[string]any{"name": "Sam", "pronouns": "they/them"})
	b, _ := os.ReadFile(filepath.Join(d.SettingsDir, "person.json"))
	if !strings.Contains(string(b), `"Sam"`) {
		t.Fatalf("%s", b)
	}
	p = wire.PersonSettings{}
	json.Unmarshal(c.call(t, 3, "person/state", nil), &p)
	if p.Name == nil || *p.Name != "Sam" || p.Pronouns == nil || *p.Pronouns != "they/them" {
		t.Fatalf("%+v", p)
	}
}
