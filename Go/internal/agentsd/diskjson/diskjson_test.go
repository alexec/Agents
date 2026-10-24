package diskjson

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// The Swift store's own records, written by the shipped app (Packages/AgentsKit's
// fixtures): each is read into the generated types and written again the same.
var fixtures = filepath.Join("..", "..", "..", "..", "Packages", "AgentsKit", "Tests", "AgentsKitTests", "Fixtures")

func tree(t *testing.T, b []byte) any {
	t.Helper()
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func roundTrip[T any](t *testing.T, name string, b []byte) {
	t.Helper()
	var v T
	if err := Unmarshal(b, &v); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	out, err := Marshal(v)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	// A list an older build left out is written [], as Swift writes it now.
	if want, got := withoutEmptyLists(tree(t, b)), withoutEmptyLists(tree(t, out)); !reflect.DeepEqual(want, got) {
		t.Errorf("%s does not round-trip:\n was %s\n now %s", name, compact(b), out)
	}
}

func withoutEmptyLists(v any) any {
	switch v := v.(type) {
	case map[string]any:
		for k, e := range v {
			if a, ok := e.([]any); ok && len(a) == 0 {
				delete(v, k)
				continue
			}
			v[k] = withoutEmptyLists(e)
		}
	case []any:
		for i, e := range v {
			v[i] = withoutEmptyLists(e)
		}
	}
	return v
}

func compact(b []byte) string {
	var buf bytes.Buffer
	json.Compact(&buf, b)
	return buf.String()
}

func TestTheStoresAgentsRoundTrip(t *testing.T) {
	for _, f := range []string{"archived-agent.json", "legacy-agent/agent.json"} {
		b, err := os.ReadFile(filepath.Join(fixtures, f))
		if err != nil {
			t.Fatal(err)
		}
		roundTrip[wire.Agent](t, f, b)
	}
}

func TestTheStoresTranscriptRoundTrips(t *testing.T) {
	f, err := os.Open(filepath.Join(fixtures, "legacy-agent", "transcript.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 1<<20), 16<<20)
	n := 0
	for s.Scan() {
		n++
		roundTrip[wire.TranscriptEntry](t, "transcript line", append([]byte(nil), s.Bytes()...))
	}
	if n == 0 {
		t.Fatal("no lines")
	}
}

func TestDatesAreTheStoresAndTheWires(t *testing.T) {
	// 2026-10-16T09:57:40.123Z
	d, err := ParseDate("2026-10-16T09:57:40.123Z")
	if err != nil {
		t.Fatal(err)
	}
	if got := FormatDate(d); got != "2026-10-16T09:57:40.123Z" {
		t.Fatalf("FormatDate = %s", got)
	}
	// A whole-second stamp, as an older build wrote, reads too.
	if _, err := ParseDate("2026-10-16T09:57:40Z"); err != nil {
		t.Fatal(err)
	}
	// The half millisecond: 0.1236 s is written .124, as Swift's encoder rounds it.
	if got := FormatDate(wire.Date(float64(d) + 0.0006)); got != "2026-10-16T09:57:40.124Z" {
		t.Fatalf("rounded = %s", got)
	}
	p := wire.Folder{Folder: "file:///home/a/src/x/", AddedAt: d}
	b, err := Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"addedAt":"2026-10-16T09:57:40.123Z","folder":"file:///home/a/src/x/"}` {
		t.Fatalf("folder %s", b)
	}
	var back wire.Folder
	if err := Unmarshal(b, &back); err != nil || back.AddedAt != d || back.Folder != p.Folder {
		t.Fatalf("back %+v %v", back, err)
	}
	// The wire keeps its number.
	w, _ := json.Marshal(p)
	if !strings.Contains(string(w), `"addedAt":813837460.123`) {
		t.Fatalf("wire %s", w)
	}
}

func TestDatesInsideListsMapsAndCases(t *testing.T) {
	asked := wire.TranscriptEntry{ID: "A", At: 1, Kind: wire.TranscriptEntryKind{
		PermissionAsked: &wire.TranscriptEntryKindPermissionAsked{Value: wire.PermissionRequest{ID: "P", AgentID: "A", AskedAt: 2, Options: []wire.PermissionOption{}}},
	}}
	b, err := Marshal(asked)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"askedAt":"2001-01-01T00:00:02.000Z"`) || !strings.Contains(string(b), `"at":"2001-01-01T00:00:01.000Z"`) {
		t.Fatalf("disk %s", b)
	}
	list := []wire.Folder{{Folder: "file:///a/", AddedAt: 3}}
	b, _ = Marshal(list)
	if !strings.Contains(string(b), `"addedAt":"2001-01-01T00:00:03.000Z"`) {
		t.Fatalf("list %s", b)
	}
}
