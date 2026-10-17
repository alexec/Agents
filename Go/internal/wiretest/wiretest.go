// Package wiretest proves a change of Go type leaves a wire type's bytes as they were
// (#1313): a golden file holds, for each type, a value with every field set and the zero
// value, as the type of the day wrote them; the test reads each with today's type and
// writes it again, and the bytes must be the same.
package wiretest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

// Types names each wire type and makes a new one of it.
type Types map[string]func() any

// Check reads golden (written from types when update is set) and checks each entry.
func Check(t *testing.T, golden string, types Types, update bool) {
	t.Helper()
	names := make([]string, 0, len(types))
	for name := range types {
		names = append(names, name)
	}
	sort.Strings(names)
	if update {
		var out strings.Builder
		for _, name := range names {
			full := types[name]()
			Fill(reflect.ValueOf(full).Elem())
			for _, sample := range []struct {
				kind  string
				value any
			}{{"full", full}, {"zero", types[name]()}} {
				b, err := json.Marshal(sample.value)
				if err != nil {
					t.Fatalf("%s: %v", name, err)
				}
				fmt.Fprintf(&out, "%s %s\n%s\n", name, sample.kind, b)
			}
		}
		_ = os.MkdirAll(filepath.Dir(golden), 0o755)
		if err := os.WriteFile(golden, []byte(out.String()), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	seen := map[string]bool{}
	for i := 0; i+1 < len(lines); i += 2 {
		name, kind, _ := strings.Cut(lines[i], " ")
		seen[name] = true
		make, ok := types[name]
		if !ok {
			t.Errorf("%s: no type of that name now", name)
			continue
		}
		v := make()
		want := []byte(lines[i+1])
		if err := json.Unmarshal(want, v); err != nil {
			t.Errorf("%s %s: read: %v", name, kind, err)
			continue
		}
		got, err := json.Marshal(v)
		if err != nil {
			t.Errorf("%s %s: write: %v", name, kind, err)
			continue
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s %s:\n got %s\nwant %s", name, kind, got, want)
		}
	}
	for _, name := range names {
		if !seen[name] {
			t.Errorf("%s: not in %s", name, golden)
		}
	}
}

// When is the date every filled date says: a whole number of milliseconds after Swift's
// reference date, so any type of the day reads and writes it exactly.
var When = time.Date(2026, 10, 17, 9, 30, 15, 250_000_000, time.UTC)

var timeType = reflect.TypeOf(time.Time{})

// Fill sets every field of v to a value that is not its zero: strings say their field,
// numbers are 7, booleans true, slices and maps hold one, pointers point. A date (a type
// whose underlying type is time.Time, or a float64 named Date) is When. Raw JSON is an
// object.
func Fill(v reflect.Value) { fill(v, "x", 0) }

func fill(v reflect.Value, name string, depth int) {
	if depth > 6 {
		return
	}
	t := v.Type()
	if t.ConvertibleTo(timeType) && t.Kind() == reflect.Struct {
		v.Set(reflect.ValueOf(When).Convert(t))
		return
	}
	if t.Name() == "Date" && t.Kind() == reflect.Float64 {
		v.SetFloat(When.Sub(time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)).Seconds())
		return
	}
	if t.Name() == "RawMessage" || t.Name() == "JSONValue" {
		v.SetBytes([]byte(`{"k":"v"}`))
		return
	}
	switch t.Kind() {
	case reflect.String:
		if t.Name() == "UUID" {
			v.SetString("6F9619FF-8B86-D011-B42D-00C04FC964FF")
			return
		}
		v.SetString(strings.ToUpper(name))
	case reflect.Bool:
		v.SetBool(true)
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		v.SetInt(7)
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		v.SetUint(7)
	case reflect.Float32, reflect.Float64:
		v.SetFloat(7.5)
	case reflect.Slice:
		if t.Elem().Kind() == reflect.Uint8 {
			v.SetBytes([]byte{1, 2, 3})
			return
		}
		s := reflect.MakeSlice(t, 1, 1)
		fill(s.Index(0), name, depth+1)
		v.Set(s)
	case reflect.Array:
		for i := range v.Len() {
			fill(v.Index(i), name, depth+1)
		}
	case reflect.Map:
		m := reflect.MakeMap(t)
		key := reflect.New(t.Key()).Elem()
		fill(key, "key", depth+1)
		value := reflect.New(t.Elem()).Elem()
		fill(value, name, depth+1)
		m.SetMapIndex(key, value)
		v.Set(m)
	case reflect.Pointer:
		p := reflect.New(t.Elem())
		fill(p.Elem(), name, depth+1)
		v.Set(p)
	case reflect.Interface:
		if v.NumMethod() == 0 {
			v.Set(reflect.ValueOf(map[string]any{"k": "v"}))
		}
	case reflect.Struct:
		for i := range t.NumField() {
			f := t.Field(i)
			if !f.IsExported() {
				continue
			}
			tag, _, _ := strings.Cut(f.Tag.Get("json"), ",")
			if tag == "-" {
				continue
			}
			if tag == "" {
				tag = f.Name
			}
			fill(v.Field(i), tag, depth+1)
		}
	}
}
