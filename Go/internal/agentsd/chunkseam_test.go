package agentsd

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// US1 (#1001, slice a2): a GitHub token the runtime streams in two chunks is redacted
// whole, on disk and to the clients; the word the turn ends on is not lost.
func TestATokenSplitOverTwoChunksIsRedacted(t *testing.T) {
	fakeRuntimes(t)
	root, work := t.TempDir(), t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	var heard strings.Builder
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + work,
		"prompt": "split a token", "startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []string{}}}), &id)
	c.until(t, "the turn's end", func(method string, params json.RawMessage) bool {
		heard.Write(params)
		return ended(id, wire.AgentStateFinished)(method, params)
	})
	entries, _, err := d.Store.Transcript(id, 0)
	if err != nil {
		t.Fatal(err)
	}
	var said strings.Builder
	for _, e := range entries {
		if m := e.Kind.AgentMessage; m != nil {
			said.WriteString(m.Text)
		}
	}
	if said.String() != "Your token is [redacted:github] so keep it. Done" {
		t.Fatalf("said %q", said.String())
	}
	disk, _ := os.ReadFile(d.Store.Loc.Transcript(string(id)))
	for where, b := range map[string]string{"the transcript": string(disk), "the clients": heard.String()} {
		if strings.Contains(b, "a1B2a1B2") {
			t.Fatalf("a piece of the token is in %s", where)
		}
	}
}

func TestSplitHeld(t *testing.T) {
	for in, want := range map[string][2]string{
		"":                       {"", ""},
		"Hello there.":           {"Hello ", "there."},
		"token ghp_abc":          {"token ", "ghp_abc"},
		"ends in a space ":       {"ends in a space ", ""},
		"é" + "x":                {"é", "x"},
		strings.Repeat("a", 300): {strings.Repeat("a", 44), strings.Repeat("a", 256)},
	} {
		if send, hold := splitHeld(in); send != want[0] || hold != want[1] {
			t.Errorf("%q: %q + %q", in, send, hold)
		}
	}
}
