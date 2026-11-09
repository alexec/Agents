package azuredevopsmcp

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

// property is one argument of an event: a string, a positive integer, a boolean, or a list
// of work item references.
type property struct {
	name        string
	kind        string // "string", "integer", "boolean" or "refs"
	description string
	pattern     *regexp.Regexp
	looksLike   string
}

func (p property) json() map[string]any {
	if p.kind == "refs" {
		return map[string]any{"type": "array", "items": map[string]any{"type": "string", "pattern": workItemRefPattern.String()}, "description": p.description}
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

// args are an event's checked arguments. pr is a pull request's number and run a build's
// id, named as the github server names them; pipeline is a pipeline's name.
type args struct {
	repo, branch, pipeline string
	pr, run                int
	fixes                  []string
	anyone, mine, all      bool
}

// workItemRefPattern is a work item as fixes takes it: "#12" (#3797).
var workItemRefPattern = regexp.MustCompile(`^#[1-9][0-9]*$`)

// closesOne is whether m's description closes one of the work items fixes asks for (#3797):
// any pull request, when fixes is not given.
func (a args) closesOne(m PR) bool {
	if len(a.fixes) == 0 {
		return true
	}
	for _, f := range m.Fixes {
		if contains(a.fixes, f) {
			return true
		}
	}
	return false
}

// byMe is whether m is the token's owner's, when mine asks for only theirs (#3797): one of
// their active pull requests, or one they opened, completed or abandoned now.
func (a args) byMe(m PR, yours *Yours) bool {
	if !a.mine {
		return true
	}
	return yours != nil && (yours.owns(m.Number) || m.AuthorID != "" && strings.EqualFold(m.AuthorID, yours.ID))
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
			if key == "run" {
				a.run = int(i)
			} else {
				a.pr = int(i)
			}
		case "refs":
			var list []string
			if json.Unmarshal(value, &list) != nil || len(list) == 0 {
				return a, invalidParams(`%s must be a list of work items, as "#12"`, key)
			}
			for _, ref := range list {
				if !workItemRefPattern.MatchString(strings.TrimSpace(ref)) {
					return a, invalidParams(`%s must be a list of work items, as "#12", not %q`, key, ref)
				}
				a.fixes = append(a.fixes, strings.TrimSpace(ref))
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
			case "pipeline":
				a.pipeline = text
			default:
				a.branch = text
			}
		}
	}
	return a, nil
}
