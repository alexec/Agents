package mcpevents

import (
	"encoding/json"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// Property is one argument of an event, by its Kind:
//   - "string": a string, which matches Pattern when there is one (LooksLike says how it looks);
//   - "integer": a positive integer;
//   - "boolean": true or false;
//   - "integers": a positive integer, or a list of them;
//   - "refs": a list of references, each matching Pattern (LooksLike names them and gives an
//     example, as `issues, as "#12" or "owner/name#12"`);
//   - "ids": a string id matching Pattern, or a list of them (LooksLike is one, as
//     "a work item's id, as 12").
type Property struct {
	Name        string
	Kind        string
	Description string
	Pattern     *regexp.Regexp
	LooksLike   string
}

// JSON is the property in an event's inputSchema.
func (p Property) JSON() map[string]any {
	switch p.Kind {
	case "integers":
		return map[string]any{"type": []string{"integer", "array"}, "items": map[string]any{"type": "integer"}, "description": p.Description}
	case "refs":
		items := map[string]any{"type": "string"}
		if p.Pattern != nil {
			items["pattern"] = p.Pattern.String()
		}
		return map[string]any{"type": "array", "items": items, "description": p.Description}
	case "ids":
		item := map[string]any{"type": "string", "pattern": p.Pattern.String()}
		return map[string]any{"type": []string{"string", "array"}, "pattern": p.Pattern.String(), "items": item, "description": p.Description}
	}
	o := map[string]any{"type": p.Kind, "description": p.Description}
	if p.Pattern != nil {
		o["pattern"] = p.Pattern.String()
	}
	return o
}

// Schema is an event's arguments, as CIWatcher's Schema: named properties in the order errors
// list them, none required, no others allowed.
type Schema []Property

// JSON is the schema as an event's inputSchema.
func (s Schema) JSON() map[string]any {
	props := map[string]any{}
	for _, p := range s {
		props[p.Name] = p.JSON()
	}
	return map[string]any{"type": "object", "properties": props, "required": []string{}, "additionalProperties": false}
}

// Lookup is the property named name.
func (s Schema) Lookup(name string) (Property, bool) {
	for _, p := range s {
		if p.Name == name {
			return p, true
		}
	}
	return Property{}, false
}

// Values are an event's checked arguments by name: a string, an int, a bool, an []int
// ("integers") or a []string ("refs" and "ids"). An argument not given is not there.
type Values map[string]any

// String is the string argument name, or "".
func (v Values) String(name string) string { s, _ := v[name].(string); return s }

// Int is the integer argument name, or 0.
func (v Values) Int(name string) int { i, _ := v[name].(int); return i }

// Bool is the boolean argument name, or false.
func (v Values) Bool(name string) bool { b, _ := v[name].(bool); return b }

// Ints is the argument name as a list of integers: one integer is a list of one.
func (v Values) Ints(name string) []int {
	switch x := v[name].(type) {
	case []int:
		return x
	case int:
		return []int{x}
	}
	return nil
}

// Strings is the "refs" or "ids" argument name, or nil.
func (v Values) Strings(name string) []string { s, _ := v[name].([]string); return s }

// Check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes. What
// is wrong is -32602 with the words CIWatcher used, for the first key, by name, that is.
func (s Schema) Check(raw json.RawMessage) (Values, *Error) {
	given := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &given); err != nil {
			return nil, InvalidParams("arguments must be an object")
		}
	}
	keys := make([]string, 0, len(given))
	for k := range given {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	v := Values{}
	for _, key := range keys {
		value := given[key]
		p, ok := s.Lookup(key)
		if !ok {
			names := make([]string, len(s))
			for i, p := range s {
				names[i] = p.Name
			}
			return nil, InvalidParams("unknown argument %s; takes %s", key, strings.Join(names, ", "))
		}
		switch p.Kind {
		case "integers":
			var list []json.RawMessage
			if strings.HasPrefix(strings.TrimSpace(string(value)), "[") {
				if json.Unmarshal(value, &list) != nil || len(list) == 0 {
					return nil, InvalidParams("%s must be a positive integer or a list of them", key)
				}
			} else {
				list = []json.RawMessage{value}
			}
			var ints []int
			for _, item := range list {
				n, ok := Positive(item)
				if !ok {
					return nil, InvalidParams("%s must be a positive integer or a list of them", key)
				}
				ints = append(ints, n)
			}
			v[key] = ints
		case "refs":
			var list []string
			if json.Unmarshal(value, &list) != nil || len(list) == 0 {
				return nil, InvalidParams(`%s must be a list of %s`, key, p.LooksLike)
			}
			var refs []string
			for _, ref := range list {
				if p.Pattern != nil && !p.Pattern.MatchString(strings.TrimSpace(ref)) {
					return nil, InvalidParams(`%s must be a list of %s, not %q`, key, p.LooksLike, ref)
				}
				refs = append(refs, strings.TrimSpace(ref))
			}
			v[key] = refs
		case "ids":
			// One id, or a list of them (#3797): a lead waits on all its open children at once.
			var list []string
			if strings.HasPrefix(strings.TrimSpace(string(value)), "[") {
				if json.Unmarshal(value, &list) != nil || len(list) == 0 {
					return nil, InvalidParams("%s must be %s, or a list of them", key, p.LooksLike)
				}
			} else {
				var text string
				if json.Unmarshal(value, &text) != nil || string(value) == "null" {
					return nil, InvalidParams("%s must be %s, or a list of them", key, p.LooksLike)
				}
				list = []string{text}
			}
			for _, text := range list {
				if !p.Pattern.MatchString(text) {
					return nil, InvalidParams("%s must be %s, or a list of them", key, p.LooksLike)
				}
			}
			v[key] = list
		case "integer":
			i, ok := Positive(value)
			if !ok {
				return nil, InvalidParams("%s must be a positive integer", key)
			}
			v[key] = i
		case "boolean":
			var b bool
			if err := json.Unmarshal(value, &b); err != nil || string(value) == "null" {
				return nil, InvalidParams("%s must be true or false", key)
			}
			v[key] = b
		default:
			var text string
			if err := json.Unmarshal(value, &text); err != nil || string(value) == "null" {
				return nil, InvalidParams("%s must be a string", key)
			}
			if p.Pattern != nil && !p.Pattern.MatchString(text) {
				return nil, InvalidParams("%s must look like %s", key, p.LooksLike)
			}
			v[key] = text
		}
	}
	return v, nil
}

// Positive is value as a positive integer, never one quoted.
func Positive(value json.RawMessage) (int, bool) {
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

// MARK: The events

// Event is one event as events/list gives it. A server's own event type embeds it, with what
// else its polls need.
type Event struct {
	Name, Title, Description string
	Input                    Schema
	Payload                  map[string]any
}

// JSON is the event in events/list's answer.
func (e Event) JSON() map[string]any {
	return map[string]any{"name": e.Name, "title": e.Title, "description": e.Description, "delivery": []string{"poll"},
		"inputSchema": e.Input.JSON(), "payloadSchema": e.Payload}
}

// Declared is an Event, or a server's type that embeds one.
type Declared interface{ Declared() Event }

// Declared is e itself.
func (e Event) Declared() Event { return e }

// Named is the event of events named name.
func Named[E Declared](events []E, name string) (E, bool) {
	for _, e := range events {
		if e.Declared().Name == name {
			return e, true
		}
	}
	var none E
	return none, false
}

// Names is events by name, in their order.
func Names[E Declared](events []E) []string {
	names := make([]string, len(events))
	for i, e := range events {
		names[i] = e.Declared().Name
	}
	return names
}

// List is events/list's answer.
func List[E Declared](events []E) map[string]any {
	list := make([]any, len(events))
	for i, e := range events {
		list[i] = e.Declared().JSON()
	}
	return map[string]any{"events": list}
}

// Wants is whether n is one of an "integers" argument's list (#5436): any n, when the list is
// empty because the argument was not given.
func Wants(list []int, n int) bool { return len(list) == 0 || slices.Contains(list, n) }

// One is the one item of an "integers" argument's list, or 0 when it has none or several.
func One(list []int) int {
	if len(list) == 1 {
		return list[0]
	}
	return 0
}
