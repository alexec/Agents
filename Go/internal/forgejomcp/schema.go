package forgejomcp

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

// property is one argument of an event: a string, a positive integer, a boolean, one or
// a list of positive integers, or a list of issue references.
type property struct {
	name        string
	kind        string // "string", "integer", "boolean", "integers" or "refs"
	description string
	pattern     *regexp.Regexp
	looksLike   string
}

func (p property) json() map[string]any {
	switch p.kind {
	case "integers":
		return map[string]any{"type": []string{"integer", "array"}, "items": map[string]any{"type": "integer"}, "description": p.description}
	case "refs":
		return map[string]any{"type": "array", "items": map[string]any{"type": "string", "pattern": issueRefPattern.String()}, "description": p.description}
	}
	o := map[string]any{"type": p.kind, "description": p.description}
	if p.pattern != nil {
		o["pattern"] = p.pattern.String()
	}
	return o
}

// schema is an event's arguments, as the github server's: named properties in the order
// errors list them, none required, no others allowed.
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

// issueRefPattern is an issue as fixes takes it: "#12", or "owner/name#12" (#3797).
var issueRefPattern = regexp.MustCompile(`^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[1-9][0-9]*$`)

// args are an event's checked arguments. pr is a pull request's number, named as
// the github server names it.
type args struct {
	repo, branch, label string
	pr                  int
	issues              []int
	fixes               []string
	anyone, mine, all   bool
}

// wantsIssue is whether the issue numbered n is one asked for: any, when none is.
func (a args) wantsIssue(n int) bool {
	if len(a.issues) == 0 {
		return true
	}
	for _, i := range a.issues {
		if i == n {
			return true
		}
	}
	return false
}

// closesOne is whether p's description closes one of the issues fixes asks for, "#12"
// being the repository's own (#3797): any pull request, when fixes is not given.
func (a args) closesOne(p PR) bool {
	if len(a.fixes) == 0 {
		return true
	}
	full := func(ref string) string {
		if strings.HasPrefix(ref, "#") {
			ref = a.repo + ref
		}
		return strings.ToLower(ref)
	}
	for _, f := range p.Fixes {
		for _, want := range a.fixes {
			if full(f) == full(want) {
				return true
			}
		}
	}
	return false
}

// byMe is whether p is the token's owner's, when mine asks for only theirs (#3797): one
// of their open pull requests, or one they wrote, merged or closed now.
func (a args) byMe(p PR, yours *Yours) bool {
	if !a.mine {
		return true
	}
	return yours != nil && (yours.owns(p.Number) || p.Author != "" && strings.EqualFold(p.Author, yours.Login))
}

// check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes.
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
		case "integers":
			var list []json.RawMessage
			if strings.HasPrefix(strings.TrimSpace(string(value)), "[") {
				if json.Unmarshal(value, &list) != nil || len(list) == 0 {
					return a, invalidParams("%s must be a positive integer or a list of them", key)
				}
			} else {
				list = []json.RawMessage{value}
			}
			for _, item := range list {
				n, ok := positive(item)
				if !ok {
					return a, invalidParams("%s must be a positive integer or a list of them", key)
				}
				a.issues = append(a.issues, n)
			}
		case "refs":
			var list []string
			if json.Unmarshal(value, &list) != nil || len(list) == 0 {
				return a, invalidParams(`%s must be a list of issues, as "#12" or "owner/name#12"`, key)
			}
			for _, ref := range list {
				if !issueRefPattern.MatchString(strings.TrimSpace(ref)) {
					return a, invalidParams(`%s must be a list of issues, as "#12" or "owner/name#12", not %q`, key, ref)
				}
				a.fixes = append(a.fixes, strings.TrimSpace(ref))
			}
		case "integer":
			i, ok := positive(value)
			if !ok {
				return a, invalidParams("%s must be a positive integer", key)
			}
			if key == "pr" {
				a.pr = i
			} else {
				a.issues = []int{i}
			}
		case "boolean":
			var b bool
			if err := json.Unmarshal(value, &b); err != nil || string(value) == "null" {
				return a, invalidParams("%s must be true or false", key)
			}
			switch key {
			case "mine":
				a.mine = b
			case "any":
				a.all = b
			default:
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

// positive is value as a positive integer, never one quoted.
func positive(value json.RawMessage) (int, bool) {
	var n json.Number
	d := json.NewDecoder(strings.NewReader(string(value)))
	d.UseNumber()
	i, err := int64(0), d.Decode(&n)
	if err == nil {
		i, err = n.Int64()
	}
	// json.Number takes "551", a string, too: a number is not quoted.
	if err != nil || i <= 0 || strings.HasPrefix(strings.TrimSpace(string(value)), `"`) {
		return 0, false
	}
	return int(i), true
}
