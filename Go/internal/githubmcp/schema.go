package githubmcp

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// rpcError is a JSON-RPC error answer: its code, message and optional data.
type rpcError struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data,omitempty"`
}

func (e *rpcError) Error() string { return e.Message }

func invalidParams(format string, args ...any) *rpcError {
	return &rpcError{Code: -32602, Message: fmt.Sprintf(format, args...)}
}

// property is one argument of an event: a string, a positive integer or a boolean.
type property struct {
	name        string
	kind        string // "string", "integer" or "boolean"
	description string
	pattern     *regexp.Regexp
	looksLike   string
}

func (p property) json() map[string]any {
	o := map[string]any{"type": p.kind, "description": p.description}
	if p.pattern != nil {
		o["pattern"] = p.pattern.String()
	}
	return o
}

// schema is an event's arguments, as CIWatcher's Schema: named properties in the order errors
// list them, none required, no others allowed.
type schema []property

func (s schema) json() map[string]any {
	props := map[string]any{}
	for _, p := range s {
		props[p.name] = p.json()
	}
	return map[string]any{"type": "object", "properties": props, "required": []string{}, "additionalProperties": false}
}

func (s schema) lookup(name string) (property, bool) {
	for _, p := range s {
		if p.name == name {
			return p, true
		}
	}
	return property{}, false
}

// args are an event's checked arguments.
type args struct {
	repo, branch, label string
	pr, issue           int
	anyone, mine        bool
}

// check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes.
// What is wrong is -32602 with the words CIWatcher used.
func (s schema) check(raw json.RawMessage) (args, *rpcError) {
	var a args
	given := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &given); err != nil {
			return a, invalidParams("arguments must be an object")
		}
	}
	keys := make([]string, 0, len(given))
	for k := range given {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, key := range keys {
		value := given[key]
		p, ok := s.lookup(key)
		if !ok {
			names := make([]string, len(s))
			for i, p := range s {
				names[i] = p.name
			}
			return a, invalidParams("unknown argument %s; takes %s", key, strings.Join(names, ", "))
		}
		switch p.kind {
		case "integer":
			var n json.Number
			d := json.NewDecoder(strings.NewReader(string(value)))
			d.UseNumber()
			i, err := int64(0), d.Decode(&n)
			if err == nil {
				i, err = n.Int64()
			}
			// json.Number takes "551", a string, too: a number is not quoted.
			if err != nil || i <= 0 || strings.HasPrefix(string(value), `"`) {
				return a, invalidParams("%s must be a positive integer", key)
			}
			if key == "pr" {
				a.pr = int(i)
			} else {
				a.issue = int(i)
			}
		case "boolean":
			var b bool
			if err := json.Unmarshal(value, &b); err != nil || string(value) == "null" {
				return a, invalidParams("%s must be true or false", key)
			}
			if key == "mine" {
				a.mine = b
			} else {
				a.anyone = b
			}
		default:
			var text string
			if err := json.Unmarshal(value, &text); err != nil || string(value) == "null" {
				return a, invalidParams("%s must be a string", key)
			}
			if p.pattern != nil && !p.pattern.MatchString(text) {
				return a, invalidParams("%s must look like %s", key, p.looksLike)
			}
			switch key {
			case "repo":
				a.repo = text
			case "branch":
				a.branch = text
			case "label":
				a.label = text
			}
		}
	}
	return a, nil
}
