package scim

import (
	"encoding/json"
	"net/http"
	"strings"
)

// PATCH (RFC 7644 §3.5.2): add, replace and remove, applied to the resource as SCIM
// writes it, which is then read back as a PUT would be. A path is attr, attr.sub,
// attr[filter], attr[filter].sub, each with or without a schema URN in front. With no
// path, the value is an object of attributes (Okta's and Entra's way), whose keys may
// themselves be paths ("name.givenName"). op is not case sensitive: Entra sends Replace.

const mostOperations = 1000

type operation struct {
	Op    string          `json:"op"`
	Path  string          `json:"path"`
	Value json.RawMessage `json:"value"`
}

// patched is the resource with a PatchOp body applied.
func (s *Server) patched(resource map[string]any, body []byte) (map[string]any, *Error) {
	var request struct {
		Operations []operation `json:"Operations"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		return nil, Errorf(http.StatusBadRequest, "invalidSyntax", "A PATCH is {schemas: [PatchOp], Operations: [{op, path, value}]}.")
	}
	if len(request.Operations) == 0 || len(request.Operations) > mostOperations {
		return nil, Errorf(http.StatusBadRequest, "invalidSyntax", "A PATCH has 1 to %d operations.", mostOperations)
	}
	for _, op := range request.Operations {
		var value any
		if len(op.Value) > 0 {
			d := json.NewDecoder(strings.NewReader(string(op.Value)))
			d.UseNumber()
			if d.Decode(&value) != nil {
				return nil, Errorf(http.StatusBadRequest, "invalidSyntax", "An operation's value is not JSON.")
			}
		}
		kind := strings.ToLower(op.Op)
		if kind != "add" && kind != "replace" && kind != "remove" {
			return nil, Errorf(http.StatusBadRequest, "invalidSyntax", "op is add, replace or remove.")
		}
		path := strings.TrimSpace(op.Path)
		if path == "" {
			if kind == "remove" {
				return nil, Errorf(http.StatusBadRequest, "noTarget", "A remove needs a path.")
			}
			fields, ok := value.(map[string]any)
			if !ok {
				return nil, Errorf(http.StatusBadRequest, "invalidValue", "With no path, the value is an object.")
			}
			for k, v := range fields {
				if err := apply(resource, kind, k, v); err != nil {
					return nil, err
				}
			}
			continue
		}
		if err := apply(resource, kind, path, value); err != nil {
			return nil, err
		}
	}
	return resource, nil
}

// target is a parsed path.
type target struct {
	// container is the extension's object, or the resource itself.
	urn    string
	attr   string
	filter []Clause
	sub    string
}

func parsePath(path string) (target, *Error) {
	var t target
	lower := strings.ToLower(path)
	for _, urn := range []string{SchemaEnterprise, SchemaUser, SchemaGroup} {
		prefix := strings.ToLower(urn) + ":"
		if strings.HasPrefix(lower, prefix) {
			if urn == SchemaEnterprise {
				t.urn = urn
			}
			path = path[len(prefix):]
			break
		}
	}
	if open := strings.IndexByte(path, '['); open >= 0 {
		end := strings.IndexByte(path, ']')
		if end < open {
			return t, Errorf(http.StatusBadRequest, "invalidPath", "The path %q has no closing ].", path)
		}
		clauses, err := ParseFilter(path[open+1 : end])
		if err != nil {
			return t, Errorf(http.StatusBadRequest, "invalidPath", "The path's filter: %s", err.Detail)
		}
		t.attr, t.filter = path[:open], clauses
		t.sub = strings.TrimPrefix(path[end+1:], ".")
	} else {
		t.attr, t.sub, _ = strings.Cut(path, ".")
	}
	if t.attr == "" {
		return t, Errorf(http.StatusBadRequest, "invalidPath", "The path %q names no attribute.", path)
	}
	return t, nil
}

// key is the resource's own key for a name, which is not case sensitive.
func key(m map[string]any, name string) string {
	for k := range m {
		if strings.EqualFold(k, name) {
			return k
		}
	}
	return name
}

func apply(resource map[string]any, kind, path string, value any) *Error {
	t, err := parsePath(path)
	if err != nil {
		return err
	}
	container := resource
	if t.urn != "" {
		k := key(resource, t.urn)
		ext, _ := resource[k].(map[string]any)
		if ext == nil {
			if kind == "remove" {
				return nil
			}
			ext = map[string]any{}
			resource[k] = ext
		}
		container = ext
	}
	k := key(container, t.attr)
	current, there := container[k]
	switch {
	case t.filter == nil && t.sub == "":
		switch kind {
		case "remove":
			list, isList := current.([]any)
			drop, dropping := value.([]any)
			if isList && dropping {
				// Entra takes members out by value: remove only those.
				container[k] = without(list, drop)
			} else {
				delete(container, k)
			}
		case "add":
			list, isList := current.([]any)
			if isList && there {
				container[k] = merged(list, value)
			} else {
				container[k] = value
			}
		default:
			container[k] = value
		}
	case t.filter == nil:
		object, _ := current.(map[string]any)
		if object == nil {
			if kind == "remove" {
				return nil
			}
			object = map[string]any{}
			container[k] = object
		}
		if kind == "remove" {
			delete(object, key(object, t.sub))
		} else {
			object[key(object, t.sub)] = value
		}
	default:
		list, _ := current.([]any)
		found := false
		var kept []any
		for _, item := range list {
			element, ok := item.(map[string]any)
			if !ok || !elementMatches(element, t.filter) {
				kept = append(kept, item)
				continue
			}
			found = true
			switch {
			case kind == "remove" && t.sub == "":
				continue
			case kind == "remove":
				delete(element, key(element, t.sub))
			case t.sub == "":
				if replacement, ok := value.(map[string]any); ok {
					for vk, vv := range replacement {
						element[key(element, vk)] = vv
					}
				}
			default:
				element[key(element, t.sub)] = value
			}
			kept = append(kept, element)
		}
		// emails[type eq "work"].value with no work email makes one (Entra).
		if !found && kind != "remove" && t.sub != "" {
			element := map[string]any{t.sub: value}
			for _, c := range t.filter {
				element[c.Attr] = c.Value
			}
			kept = append(kept, element)
		}
		if kept == nil {
			kept = []any{}
		}
		container[k] = kept
	}
	return nil
}

func elementMatches(element map[string]any, clauses []Clause) bool {
	for _, c := range clauses {
		v, ok := element[key(element, c.Attr)]
		if !ok {
			return false
		}
		switch x := v.(type) {
		case string:
			if !strings.EqualFold(x, c.Value) {
				return false
			}
		case bool:
			if (c.Value == "true") != x {
				return false
			}
		case json.Number:
			if x.String() != c.Value {
				return false
			}
		default:
			return false
		}
	}
	return true
}

// valueOf is a list element's value, for members and the like.
func valueOf(item any) string {
	if m, ok := item.(map[string]any); ok {
		if v, ok := m[key(m, "value")].(string); ok {
			return v
		}
	}
	return ""
}

// merged adds to a list, skipping an element whose value it has.
func merged(list []any, value any) []any {
	adding, ok := value.([]any)
	if !ok {
		adding = []any{value}
	}
	seen := map[string]bool{}
	for _, item := range list {
		if v := valueOf(item); v != "" {
			seen[v] = true
		}
	}
	for _, item := range adding {
		if v := valueOf(item); v != "" {
			if seen[v] {
				continue
			}
			seen[v] = true
		}
		list = append(list, item)
	}
	return list
}

func without(list, drop []any) []any {
	gone := map[string]bool{}
	for _, item := range drop {
		gone[valueOf(item)] = true
	}
	out := []any{}
	for _, item := range list {
		if !gone[valueOf(item)] {
			out = append(out, item)
		}
	}
	return out
}
