// Package diskjson writes and reads the daemon's records as the Swift store does
// (StoreCoding.swift), so a host that changes language keeps every agent (#1134).
//
// The wire and the disk carry the same shapes, from the same generated types (Go/wire),
// and differ only in how a Date is written: the wire's plain JSONEncoder writes seconds
// since 2001 (wire.Date), the store writes ISO 8601 in UTC with milliseconds,
// "2026-10-16T09:57:40.123Z". The store also sorts keys and does not escape slashes.
// Marshal and Unmarshal convert at the boundary, guided by the Go type: a value is
// encoded the wire's way, then every wire.Date in it is rewritten (and the reverse).
package diskjson

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

var dateType = reflect.TypeOf(wire.Date(0))

// Marshal is v as the Swift store writes it.
func Marshal(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	tree, err := decodeTree(b)
	if err != nil {
		return nil, err
	}
	tree, err = walk(reflect.TypeOf(v), tree, toDisk)
	if err != nil {
		return nil, err
	}
	return encodeTree(tree)
}

// Unmarshal reads a record the Swift store wrote into v, a pointer.
func Unmarshal(data []byte, v any) error {
	t := reflect.TypeOf(v)
	if t == nil || t.Kind() != reflect.Pointer {
		return fmt.Errorf("diskjson: Unmarshal needs a pointer, not %v", t)
	}
	tree, err := decodeTree(data)
	if err != nil {
		return err
	}
	tree, err = walk(t.Elem(), tree, fromDisk)
	if err != nil {
		return err
	}
	b, err := json.Marshal(tree)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func decodeTree(b []byte) (any, error) {
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var tree any
	if err := d.Decode(&tree); err != nil {
		return nil, err
	}
	return tree, nil
}

// encodeTree writes keys sorted (encoding/json sorts a map's), without escaping slashes
// or HTML, as Swift's .withoutEscapingSlashes and .sortedKeys do.
func encodeTree(tree any) ([]byte, error) {
	var buf bytes.Buffer
	e := json.NewEncoder(&buf)
	e.SetEscapeHTML(false)
	if err := e.Encode(tree); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

type convert func(v any) (any, error)

// toDisk turns seconds since 2001 into the store's ISO 8601.
func toDisk(v any) (any, error) {
	n, ok := v.(json.Number)
	if !ok {
		return v, nil
	}
	f, err := n.Float64()
	if err != nil {
		return nil, err
	}
	return FormatDate(wire.Date(f)), nil
}

// fromDisk turns the store's ISO 8601 into seconds since 2001.
func fromDisk(v any) (any, error) {
	s, ok := v.(string)
	if !ok {
		return v, nil // a number already (a record a spike wrote): taken as it is
	}
	d, err := ParseDate(s)
	if err != nil {
		return nil, err
	}
	return json.Number(formatSeconds(float64(d))), nil
}

func formatSeconds(f float64) string {
	b, _ := json.Marshal(f)
	return string(b)
}

// FormatDate is a Date as StoreCoding.encoder writes it: half a millisecond added, then
// the fraction cut at the millisecond, in UTC.
func FormatDate(d wire.Date) string {
	t := d.Time().Add(500 * time.Microsecond).UTC()
	return t.Truncate(time.Millisecond).Format("2006-01-02T15:04:05.000Z07:00")
}

// ParseDate reads a store date: with or without the fraction, any zone.
func ParseDate(s string) (wire.Date, error) {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return 0, fmt.Errorf("diskjson: not an ISO 8601 date: %q", s)
	}
	return wire.DateOf(t), nil
}

// walk rewrites every value of type wire.Date in tree, which is t encoded the wire's way.
func walk(t reflect.Type, tree any, f convert) (any, error) {
	if tree == nil {
		return nil, nil
	}
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == dateType {
		return f(tree)
	}
	switch t.Kind() {
	case reflect.Struct:
		obj, ok := tree.(map[string]any)
		if !ok {
			return tree, nil
		}
		for name, field := range fieldsOf(t) {
			v, ok := obj[name]
			if ok && v == nil && field.required && field.t.Kind() == reflect.Slice && field.t.Elem().Kind() != reflect.Uint8 {
				// A list Swift always has: a nil slice is written [], as Swift writes it.
				obj[name] = []any{}
				continue
			}
			if ok {
				nv, err := walk(field.t, v, f)
				if err != nil {
					return nil, fmt.Errorf("%s: %w", name, err)
				}
				obj[name] = nv
			}
		}
		return obj, nil
	case reflect.Slice, reflect.Array:
		if t.Elem().Kind() == reflect.Uint8 {
			return tree, nil // []byte is base64 text; json.RawMessage is any JSON
		}
		arr, ok := tree.([]any)
		if !ok {
			return tree, nil
		}
		for i, v := range arr {
			nv, err := walk(t.Elem(), v, f)
			if err != nil {
				return nil, err
			}
			arr[i] = nv
		}
		return arr, nil
	case reflect.Map:
		obj, ok := tree.(map[string]any)
		if !ok {
			return tree, nil
		}
		for k, v := range obj {
			nv, err := walk(t.Elem(), v, f)
			if err != nil {
				return nil, err
			}
			obj[k] = nv
		}
		return obj, nil
	}
	return tree, nil
}

var fields sync.Map // reflect.Type → map[string]field

type field struct {
	t reflect.Type
	// required: no omitempty or omitzero, so Swift's type has it always.
	required bool
}

// fieldsOf is each JSON key of a struct and the type under it, embedded structs flattened.
func fieldsOf(t reflect.Type) map[string]field {
	if m, ok := fields.Load(t); ok {
		return m.(map[string]field)
	}
	m := map[string]field{}
	for i := 0; i < t.NumField(); i++ {
		sf := t.Field(i)
		tag := sf.Tag.Get("json")
		if tag == "-" {
			continue
		}
		name, opts, _ := strings.Cut(tag, ",")
		if sf.Anonymous && name == "" {
			et := sf.Type
			for et.Kind() == reflect.Pointer {
				et = et.Elem()
			}
			if et.Kind() == reflect.Struct {
				for k, v := range fieldsOf(et) {
					m[k] = v
				}
				continue
			}
		}
		if !sf.IsExported() {
			continue
		}
		if name == "" {
			name = sf.Name
		}
		m[name] = field{t: sf.Type, required: !strings.Contains(opts, "omitempty") && !strings.Contains(opts, "omitzero")}
	}
	fields.Store(t, m)
	return m
}

// Pretty is a tree (from encoding/json, numbers as json.Number) as Swift's JSONEncoder
// writes it with [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]: two spaces a
// level, `"key" : value`, keys sorted, slashes and non-ASCII as they are.
func Pretty(tree any) ([]byte, error) {
	var b bytes.Buffer
	if err := pretty(&b, tree, ""); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func pretty(b *bytes.Buffer, v any, indent string) error {
	switch t := v.(type) {
	case map[string]any:
		if len(t) == 0 {
			b.WriteString("{}")
			return nil
		}
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		b.WriteString("{\n")
		for i, k := range keys {
			b.WriteString(indent + "  ")
			if err := scalar(b, k); err != nil {
				return err
			}
			b.WriteString(" : ")
			if err := pretty(b, t[k], indent+"  "); err != nil {
				return err
			}
			if i < len(keys)-1 {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString(indent + "}")
	case []any:
		if len(t) == 0 {
			b.WriteString("[]")
			return nil
		}
		b.WriteString("[\n")
		for i, e := range t {
			b.WriteString(indent + "  ")
			if err := pretty(b, e, indent+"  "); err != nil {
				return err
			}
			if i < len(t)-1 {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString(indent + "]")
	default:
		return scalar(b, v)
	}
	return nil
}

func scalar(b *bytes.Buffer, v any) error {
	var s bytes.Buffer
	enc := json.NewEncoder(&s)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return err
	}
	b.Write(bytes.TrimRight(s.Bytes(), "\n"))
	return nil
}

// Compact is JSON as StoreCoding.encoder writes it: keys sorted, slashes and HTML as
// they are, no spaces.
func Compact(b []byte) ([]byte, error) {
	tree, err := decodeTree(b)
	if err != nil {
		return nil, err
	}
	return encodeTree(tree)
}
