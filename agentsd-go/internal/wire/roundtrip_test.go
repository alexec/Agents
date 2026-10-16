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
)

// Every object in the Swift-encoded fixtures (Packages/AgentsKit/Tests/…/Fixtures/web,
// written by today's Swift encoder) that is one of the subset's records is decoded into
// the types generated from the schema, encoded again, and must come back the same.

type kind struct {
	name  string
	is    func(map[string]any) bool
	check func([]byte) ([]byte, error)
}

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

var kinds = []kind{
	{"Agent", func(m map[string]any) bool { return has(m, "id", "runtimeID", "cwd", "state", "createdAt") }, strict[Agent]},
	{"TranscriptEntry", func(m map[string]any) bool { return has(m, "id", "at", "kind") && len(m) <= 5 }, strict[TranscriptEntry]},
	{"RuntimeStatus", func(m map[string]any) bool { return has(m, "runtime", "availability") }, strict[RuntimeStatus]},
	{"ProjectSummary", func(m map[string]any) bool { return has(m, "project", "counts", "name") }, strict[ProjectSummary]},
	{"PermissionRequest", func(m map[string]any) bool { return has(m, "id", "agentID", "toolCall", "options", "askedAt") }, strict[PermissionRequest]},
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
	json.Unmarshal(a, &x)
	json.Unmarshal(b, &y)
	return reflect.DeepEqual(x, y)
}

func TestSwiftFixturesRoundTrip(t *testing.T) {
	counts := map[string][2]int{}
	var failures []string
	filepath.WalkDir("testdata/web", func(path string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() || !strings.HasSuffix(path, ".json") {
			return nil
		}
		b, _ := os.ReadFile(path)
		var v any
		if json.Unmarshal(b, &v) != nil {
			return nil
		}
		walk(v, func(m map[string]any) {
			for _, k := range kinds {
				if !k.is(m) {
					continue
				}
				raw, _ := json.Marshal(m)
				c := counts[k.name]
				c[0]++
				back, err := k.check(raw)
				if err == nil && same(raw, back) {
					c[1]++
				} else if len(failures) < 12 {
					why := "differs"
					if err != nil {
						why = err.Error()
					} else {
						why = diff(raw, back)
					}
					failures = append(failures, fmt.Sprintf("%s in %s: %s", k.name, path, why))
				}
				counts[k.name] = c
				break
			}
		})
		return nil
	})
	for _, k := range kinds {
		c := counts[k.name]
		t.Logf("%-18s %3d found, %3d round-trip", k.name, c[0], c[1])
	}
	for _, f := range failures {
		t.Log(f)
	}
	for _, k := range kinds {
		if c := counts[k.name]; c[0] != c[1] {
			t.Errorf("%s: %d of %d did not round-trip", k.name, c[0]-c[1], c[0])
		}
	}
}

func diff(a, b []byte) string {
	var x, y map[string]any
	json.Unmarshal(a, &x)
	json.Unmarshal(b, &y)
	var out []string
	for k, v := range x {
		if w, ok := y[k]; !ok {
			out = append(out, "lost "+k)
		} else if !reflect.DeepEqual(v, w) {
			vb, _ := json.Marshal(v)
			wb, _ := json.Marshal(w)
			out = append(out, fmt.Sprintf("%s: %.120s → %.120s", k, vb, wb))
		}
	}
	for k := range y {
		if _, ok := x[k]; !ok {
			out = append(out, "added "+k)
		}
	}
	return strings.Join(out, "; ")
}
