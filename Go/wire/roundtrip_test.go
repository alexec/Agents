package wire

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The records today's Swift encoder wrote into AgentsKit's web fixtures each read strictly
// into the types made from the schema and write back the same (#1135).
const fixtures = "../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/web"

// strict reads JSON into a T, refusing a key T does not have, and writes it again.
func strict[T any](b []byte) ([]byte, error) {
	var v T
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	return json.Marshal(v)
}

func has(m map[string]any, keys ...string) bool {
	for _, k := range keys {
		if _, ok := m[k]; !ok {
			return false
		}
	}
	return true
}

// kinds tells the records in a fixture apart by their keys.
var kinds = []struct {
	name  string
	is    func(map[string]any) bool
	check func([]byte) ([]byte, error)
}{
	{"Agent", func(m map[string]any) bool { return has(m, "id", "runtimeID", "cwd", "state", "createdAt") }, strict[Agent]},
	{"TranscriptEntry", func(m map[string]any) bool { return has(m, "id", "at", "kind") && len(m) <= 5 }, strict[TranscriptEntry]},
	{"RuntimeStatus", func(m map[string]any) bool { return has(m, "runtime", "availability") }, strict[RuntimeStatus]},
	{"PermissionRequest", func(m map[string]any) bool { return has(m, "id", "agentID", "toolCall", "options", "askedAt") }, strict[PermissionRequest]},
	{"WorkflowSummary", func(m map[string]any) bool { return has(m, "workflow", "isEnabled", "isRunning") }, strict[WorkflowSummary]},
}

// The types whose Swift encoder is written by hand, by the overrides/ fixture that holds
// samples of each.
var samples = map[string]func([]byte) ([]byte, error){
	"ConfigOption":        strict[ConfigOption],
	"ContentBlock":        strict[ContentBlock],
	"FileReading":         strict[FileReading],
	"GitView":             strict[GitView],
	"NeedID":              strict[NeedID],
	"RuntimeAvailability": strict[RuntimeAvailability],
	"Surface":             strict[Surface],
	"ToolCallContent":     strict[ToolCallContent],
	"WorkflowTrigger":     strict[WorkflowTrigger],
}

func walk(v any, found func(map[string]any)) {
	switch t := v.(type) {
	case map[string]any:
		found(t)
		for _, c := range t {
			walk(c, found)
		}
	case []any:
		for _, c := range t {
			walk(c, found)
		}
	}
}

// same compares as JSON values: key order and number spelling do not matter.
func same(a, b []byte) bool {
	var x, y any
	return json.Unmarshal(a, &x) == nil && json.Unmarshal(b, &y) == nil && reflect.DeepEqual(x, y)
}

func roundTrip(t *testing.T, name, where string, raw []byte, check func([]byte) ([]byte, error)) {
	t.Helper()
	back, err := check(raw)
	if err != nil {
		t.Errorf("%s in %s: %v", name, where, err)
	} else if !same(raw, back) {
		t.Errorf("%s in %s: %.300s came back as %.300s", name, where, raw, back)
	}
}

func TestSwiftFixturesRoundTrip(t *testing.T) {
	found := map[string]int{}
	err := filepath.WalkDir(fixtures, func(path string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() || !strings.HasSuffix(path, ".json") {
			return err
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var v any
		if err := json.Unmarshal(b, &v); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		if filepath.Base(filepath.Dir(path)) == "overrides" {
			name := strings.TrimSuffix(filepath.Base(path), ".json")
			check, ok := samples[name]
			if !ok {
				t.Errorf("overrides/%s.json: no Go type is checked against it", name)
				return nil
			}
			for _, c := range v.([]any) {
				raw, _ := json.Marshal(c.(map[string]any)["input"])
				roundTrip(t, name, path, raw, check)
				found[name]++
			}
			return nil
		}
		walk(v, func(m map[string]any) {
			for _, k := range kinds {
				if k.is(m) {
					raw, _ := json.Marshal(m)
					roundTrip(t, k.name, path, raw, k.check)
					found[k.name]++
					return
				}
			}
		})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range kinds {
		if found[k.name] == 0 {
			t.Errorf("no %s in the fixtures", k.name)
		}
		t.Logf("%-20s %3d", k.name, found[k.name])
	}
	for name := range samples {
		if found[name] == 0 {
			t.Errorf("no samples of %s", name)
		}
	}
}

// The forgiving decoders, as Swift's hand-written init(from:) has them.
func TestForgivingDecoders(t *testing.T) {
	var state AgentState
	if err := json.Unmarshal([]byte(`"hibernating"`), &state); err != nil || state != AgentStateStopped {
		t.Errorf("an unknown state read as %q, %v; want stopped", state, err)
	}
	var reason EndedReason
	if err := json.Unmarshal([]byte(`"meteor"`), &reason); err != nil || reason != EndedReasonUnrecognised {
		t.Errorf("an unknown reason read as %q, %v; want unrecognised", reason, err)
	}

	unknown := []byte(`{"teleported":{"to":"Mars","at":3}}`)
	var kind TranscriptEntryKind
	if err := json.Unmarshal(unknown, &kind); err != nil || kind.Unrecognised == nil {
		t.Fatalf("an unknown kind did not read as unrecognised: %+v, %v", kind, err)
	}
	if back, _ := json.Marshal(kind); !same(back, unknown) {
		t.Errorf("an unknown kind came back as %s", back)
	}

	var summary WorkflowSummary
	if err := json.Unmarshal([]byte(`{"workflow":{}}`), &summary); err != nil || !summary.IsEnabled {
		t.Errorf("a summary with no isEnabled read as %v, %v; want enabled", summary.IsEnabled, err)
	}
}

func TestMeaningTypes(t *testing.T) {
	b, _ := json.Marshal(UUID("0a1b2c3d-0000-4000-8000-00000000abcd"))
	if string(b) != `"0A1B2C3D-0000-4000-8000-00000000ABCD"` {
		t.Errorf("a UUID wrote %s, want upper case", b)
	}
	var d Date
	if err := json.Unmarshal([]byte("812500000.123456"), &d); err != nil {
		t.Fatal(err)
	}
	if b, _ := json.Marshal(d); string(b) != "812500000.123456" {
		t.Errorf("a date came back as %s", b)
	}
	if got := d.Time().UTC().Format("2006-01-02T15:04:05"); got != "2026-09-30T22:26:40" {
		t.Errorf("812500000 seconds after 2001 is %s", got)
	}
	if got := DateOf(reference.Add(1500 * time.Millisecond)); got != 1.5 {
		t.Errorf("a time 1.5 s after 2001 is the Date %v", got)
	}
}
