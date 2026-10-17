package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

func TestPersonIsKeptAsGiven(t *testing.T) {
	d, c := start(t, t.TempDir())
	if r := c.call(t, 1, "person/state", nil); string(r) != `{}` {
		t.Fatalf("empty: %s", r)
	}
	if r := c.call(t, 2, "person/set", map[string]any{"name": " Sam ", "pronouns": "they/them"}); !strings.Contains(string(r), `"name":" Sam "`) {
		t.Fatalf("set: %s", r)
	}
	b, _ := os.ReadFile(filepath.Join(d.SettingsDir, "person.json"))
	if string(b) != `{"name":" Sam ","pronouns":"they/them"}` {
		t.Fatalf("person.json: %s", b)
	}
	if r := c.call(t, 3, "person/state", nil); !strings.Contains(string(r), `"pronouns":"they/them"`) {
		t.Fatalf("state: %s", r)
	}
}

func TestMacVerbsWantAPathThatIsThere(t *testing.T) {
	_, c := start(t, t.TempDir())
	for i, m := range []string{"mac/reveal", "mac/open"} {
		if e := c.callError(t, i+1, m, map[string]any{"path": "/no/such/file"}); e.Code != wire.FailureFileGone {
			t.Fatalf("%s: %+v", m, e)
		}
	}
}
