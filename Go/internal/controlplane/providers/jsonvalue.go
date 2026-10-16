package providers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"strconv"
	"strings"
)

// JSON values as JSONValue has them: decoded into any, with numbers kept as json.Number so
// an id stays the digits it was.

// parseJSON is JSONValue.parse.
func parseJSON(data []byte) (any, error) {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	if d.More() {
		return nil, fmt.Errorf("more than one JSON value")
	}
	return v, nil
}

// decodeJSON decodes into v with numbers in any kept as json.Number.
func decodeJSON(data []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	return d.Decode(v)
}

// toValue is JSONValue.encoding: v as a generic JSON value.
func toValue(v any) any {
	data, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	out, _ := parseJSON(data)
	return out
}

// get is a JSONValue subscript: nil for anything but an object with that key.
func get(v any, key string) any {
	if o, ok := v.(map[string]any); ok {
		return o[key]
	}
	return nil
}

// has says an object has a key, null or not.
func has(v any, key string) bool {
	o, ok := v.(map[string]any)
	if !ok {
		return false
	}
	_, ok = o[key]
	return ok
}

func str(v any) (string, bool) {
	s, ok := v.(string)
	return s, ok
}

func strOr(v any) string {
	s, _ := v.(string)
	return s
}

func arr(v any) ([]any, bool) {
	a, ok := v.([]any)
	return a, ok
}

func obj(v any) (map[string]any, bool) {
	o, ok := v.(map[string]any)
	return o, ok
}

func boolean(v any) (bool, bool) {
	b, ok := v.(bool)
	return b, ok
}

// integer is JSONValue.intValue: a whole number.
func integer(v any) (int, bool) {
	switch n := v.(type) {
	case json.Number:
		if i, err := strconv.Atoi(string(n)); err == nil {
			return i, true
		}
		if f, err := n.Float64(); err == nil && f == math.Trunc(f) && math.Abs(f) < 1e15 {
			return int(f), true
		}
	case float64:
		if n == math.Trunc(n) && math.Abs(n) < 1e15 {
			return int(n), true
		}
	case int:
		return n, true
	}
	return 0, false
}

// normal is v with every number as a float64, for comparing.
func normal(v any) any {
	switch t := v.(type) {
	case json.Number:
		f, _ := t.Float64()
		return f
	case int:
		return float64(t)
	case []any:
		out := make([]any, len(t))
		for i, x := range t {
			out[i] = normal(x)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, x := range t {
			out[k] = normal(x)
		}
		return out
	}
	return v
}

// jsonEqual is JSONValue's ==: the same JSON, however it was written.
func jsonEqual(a, b any) bool { return reflect.DeepEqual(normal(toValue(a)), normal(toValue(b))) }

// compact is JSONEncoder with .sortedKeys and .withoutEscapingSlashes: one line, keys
// sorted, nothing escaped that need not be.
func compact(v any) string {
	var out bytes.Buffer
	e := json.NewEncoder(&out)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return ""
	}
	return strings.TrimSuffix(out.String(), "\n")
}

// rawOf is v's JSON, or nil.
func rawOf(v any) json.RawMessage {
	data, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return data
}

// requireParams decodes params into v, which must be an object with each of required, as
// Swift's decoder needs a field that is not optional. Otherwise it says they are not a what.
func requireParams(params json.RawMessage, v any, what string, required ...string) error {
	refused := invalid("Those parameters are not a %s.", what)
	if len(params) == 0 || string(params) == "null" {
		return refused
	}
	var all map[string]json.RawMessage
	if json.Unmarshal(params, &all) != nil {
		return refused
	}
	for _, name := range required {
		if raw, ok := all[name]; !ok || string(raw) == "null" {
			return refused
		}
	}
	if decodeJSON(params, v) != nil {
		return refused
	}
	return nil
}

// isUUID says s is a UUID, as Swift's UUID(uuidString:) reads one.
func isUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
				return false
			}
		}
	}
	return true
}

// uuidOf is s as uuidString writes it, or "" when it is not a UUID.
func uuidOf(s string) string {
	if !isUUID(s) {
		return ""
	}
	return strings.ToUpper(s)
}

// shortID is a UUID's first eight characters in lower case, as the log says one.
func shortID(id string) string {
	if len(id) > 8 {
		id = id[:8]
	}
	return strings.ToLower(id)
}
