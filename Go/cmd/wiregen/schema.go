package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Schema is the part of JSON Schema draft-07 the wire uses, with its properties in the
// order they are written: the generated types keep that order.
type Schema struct {
	Ref         string
	Types       []string
	Enum        []any
	Const       any
	HasConst    bool
	Properties  []Property
	Required    []string
	NoMore      bool    // additionalProperties: false
	More        *Schema // additionalProperties: a schema
	AnyOf       []*Schema
	Items       *Schema
	MinItems    *int
	MaxItems    *int
	Not         *Schema
	Description string
	Default     any
	HasDefault  bool

	GoType   string // x-go-type: a type written by hand in Go/wire
	TSType   string // x-ts-type: the TypeScript, written out
	Fallback string // x-fallback: what a value this build does not know reads as
}

// Property is one named property of an object.
type Property struct {
	Name   string
	Schema *Schema
}

// IsRequired says whether the object requires the property.
func (s *Schema) IsRequired(name string) bool {
	for _, r := range s.Required {
		if r == name {
			return true
		}
	}
	return false
}

// Is says whether the schema has exactly this one type.
func (s *Schema) Is(t string) bool { return len(s.Types) == 1 && s.Types[0] == t }

// RefName is the definition a $ref names.
func (s *Schema) RefName() string { return s.Ref[strings.LastIndex(s.Ref, "/")+1:] }

// Nullable splits `X | null` into X; ok is false for anything else.
func (s *Schema) Nullable() (inner *Schema, ok bool) {
	if len(s.AnyOf) == 2 {
		for i, m := range s.AnyOf {
			if m.Is("null") {
				return s.AnyOf[1-i], true
			}
		}
	}
	if len(s.Types) == 2 && s.Enum == nil {
		for i, t := range s.Types {
			if t == "null" {
				return &Schema{Types: []string{s.Types[1-i]}}, true
			}
		}
	}
	return nil, false
}

// Cases reads `anyOf` of one-key objects, a Swift enum with associated values: each
// case's name and its payload. ok is false for any other anyOf.
func (s *Schema) Cases() (names []string, payloads []*Schema, ok bool) {
	if len(s.AnyOf) < 1 {
		return nil, nil, false
	}
	for _, m := range s.AnyOf {
		if !m.Is("object") || len(m.Properties) != 1 || len(m.Required) != 1 || m.Required[0] != m.Properties[0].Name {
			return nil, nil, false
		}
		names = append(names, m.Properties[0].Name)
		payloads = append(payloads, m.Properties[0].Schema)
	}
	return names, payloads, true
}

// Tagged reads `anyOf` of objects told apart by one constant string property (a `type`).
func (s *Schema) Tagged() (tag string, ok bool) {
	if len(s.AnyOf) < 2 {
		return "", false
	}
	for _, m := range s.AnyOf {
		if !m.Is("object") || len(m.Properties) == 0 {
			return "", false
		}
		first := m.Properties[0]
		if !first.Schema.HasConst || !m.IsRequired(first.Name) || (tag != "" && first.Name != tag) {
			return "", false
		}
		tag = first.Name
	}
	return tag, true
}

// Strings says whether the schema is only string values: a string, string enums or
// constants, or anyOf of those.
func (s *Schema) Strings() bool {
	if s.AnyOf != nil {
		for _, m := range s.AnyOf {
			if !m.Strings() {
				return false
			}
		}
		return true
	}
	return s.Is("string") && s.Properties == nil
}

func (s *Schema) UnmarshalJSON(b []byte) error {
	keys, raw, err := ordered(b)
	if err != nil {
		return err
	}
	for _, k := range keys {
		v := raw[k]
		switch k {
		case "$ref":
			err = json.Unmarshal(v, &s.Ref)
		case "type":
			if bytes.HasPrefix(bytes.TrimSpace(v), []byte("[")) {
				err = json.Unmarshal(v, &s.Types)
			} else {
				var t string
				err = json.Unmarshal(v, &t)
				s.Types = []string{t}
			}
		case "enum":
			err = json.Unmarshal(v, &s.Enum)
		case "const":
			s.HasConst = true
			err = json.Unmarshal(v, &s.Const)
		case "properties":
			var names []string
			var props map[string]json.RawMessage
			if names, props, err = ordered(v); err == nil {
				s.Properties = []Property{}
				for _, n := range names {
					p := &Schema{}
					if err = json.Unmarshal(props[n], p); err != nil {
						return fmt.Errorf("%s: %w", n, err)
					}
					s.Properties = append(s.Properties, Property{n, p})
				}
			}
		case "required":
			err = json.Unmarshal(v, &s.Required)
		case "additionalProperties":
			switch strings.TrimSpace(string(v)) {
			case "false":
				s.NoMore = true
			case "true":
				s.More = &Schema{}
			default:
				s.More = &Schema{}
				err = json.Unmarshal(v, s.More)
			}
		case "anyOf", "oneOf":
			err = json.Unmarshal(v, &s.AnyOf)
		case "items":
			s.Items = &Schema{}
			err = json.Unmarshal(v, s.Items)
		case "minItems":
			err = json.Unmarshal(v, &s.MinItems)
		case "maxItems":
			err = json.Unmarshal(v, &s.MaxItems)
		case "not":
			s.Not = &Schema{}
			err = json.Unmarshal(v, s.Not)
		case "description":
			err = json.Unmarshal(v, &s.Description)
		case "default":
			s.HasDefault = true
			err = json.Unmarshal(v, &s.Default)
		case "x-go-type":
			err = json.Unmarshal(v, &s.GoType)
		case "x-ts-type":
			err = json.Unmarshal(v, &s.TSType)
		case "x-fallback":
			err = json.Unmarshal(v, &s.Fallback)
		case "format", "pattern", "contentEncoding", "x-swift-type", "title":
			// Said for people and validators; no generator reads them.
		default:
			return fmt.Errorf("unknown keyword %q", k)
		}
		if err != nil {
			return fmt.Errorf("%s: %w", k, err)
		}
	}
	return nil
}

// inNameOrder refuses a list that is not in name order. A new definition or method goes
// where its name sorts, not at the end, so that two features that each add one touch
// different lines (#2020).
func inNameOrder(what string, names []string) error {
	for i := 1; i < len(names); i++ {
		if names[i] < names[i-1] {
			return fmt.Errorf("%s: %s is not in name order; put it before %s (#2020)", what, names[i], names[i-1])
		}
	}
	return nil
}

// ordered reads an object's keys in the order they are written.
func ordered(b []byte) ([]string, map[string]json.RawMessage, error) {
	d := json.NewDecoder(bytes.NewReader(b))
	if t, err := d.Token(); err != nil || t != json.Delim('{') {
		return nil, nil, fmt.Errorf("not an object: %.40s", b)
	}
	var keys []string
	values := map[string]json.RawMessage{}
	for d.More() {
		t, err := d.Token()
		if err != nil {
			return nil, nil, err
		}
		k := t.(string)
		var v json.RawMessage
		if err := d.Decode(&v); err != nil {
			return nil, nil, err
		}
		keys = append(keys, k)
		values[k] = v
	}
	return keys, values, nil
}

// Document is daemon.schema.json: the definitions, by name.
type Document struct {
	Names       []string // sorted
	Definitions map[string]*Schema
}

func readDocument(b []byte) (*Document, error) {
	var top struct {
		Definitions json.RawMessage `json:"definitions"`
	}
	if err := json.Unmarshal(b, &top); err != nil {
		return nil, err
	}
	names, definitions, err := ordered(top.Definitions)
	if err != nil {
		return nil, fmt.Errorf("definitions: %w", err)
	}
	if err := inNameOrder("definitions", names); err != nil {
		return nil, err
	}
	doc := &Document{Definitions: map[string]*Schema{}}
	for name, raw := range definitions {
		s := &Schema{}
		if err := json.Unmarshal(raw, s); err != nil {
			return nil, fmt.Errorf("definitions/%s: %w", name, err)
		}
		doc.Names = append(doc.Names, name)
		doc.Definitions[name] = s
	}
	sort.Strings(doc.Names)
	for _, name := range doc.Names {
		if err := doc.checkRefs(doc.Definitions[name], name); err != nil {
			return nil, err
		}
	}
	return doc, nil
}

func (d *Document) checkRefs(s *Schema, where string) error {
	if s == nil {
		return nil
	}
	if s.Ref != "" {
		if _, ok := d.Definitions[s.RefName()]; !ok {
			return fmt.Errorf("%s: $ref %s names no definition", where, s.Ref)
		}
	}
	for _, p := range s.Properties {
		if err := d.checkRefs(p.Schema, where+"."+p.Name); err != nil {
			return err
		}
	}
	for _, m := range s.AnyOf {
		if err := d.checkRefs(m, where); err != nil {
			return err
		}
	}
	for _, c := range []*Schema{s.More, s.Items, s.Not} {
		if err := d.checkRefs(c, where); err != nil {
			return err
		}
	}
	return nil
}

// RPC is an OpenRPC document: its methods, its notifications and its errors.
type RPC struct {
	Target  string // "host" or "control"
	Methods []Method
	Errors  []RPCError // sorted by name
	// Declared is x-declared-capabilities: the capabilities no method names, which a peer
	// declares by hand (#1748).
	Declared []Declared
}

// Declared is a capability that a peer (host, client or control) declares by hand.
type Declared struct {
	Name, By, Description string
}

// Method is one method or notification. Params is its one `params` value, sent whole.
type Method struct {
	Name         string
	Capability   string // x-capability: the capability that names it (#1748)
	Notification bool
	Web          bool
	Params       *Schema
	Result       *Schema // nil for a notification
}

// RPCError is one of the codes a call can fail with.
type RPCError struct {
	Name string
	Code int
}

func readRPC(b []byte, target string, doc *Document) (*RPC, error) {
	var top struct {
		Methods []struct {
			Name   string `json:"name"`
			Cap    string `json:"x-capability"`
			Tags   []struct{ Name string }
			Note   bool `json:"x-notification"`
			Params []struct {
				Name   string  `json:"name"`
				Schema *Schema `json:"schema"`
			} `json:"params"`
			Result *struct {
				Schema *Schema `json:"schema"`
			} `json:"result"`
		} `json:"methods"`
		Declared []struct {
			Name        string `json:"name"`
			By          string `json:"by"`
			Description string `json:"description"`
		} `json:"x-declared-capabilities"`
		Components struct {
			Errors map[string]struct {
				Code int `json:"code"`
			} `json:"errors"`
		} `json:"components"`
	}
	if err := json.Unmarshal(b, &top); err != nil {
		return nil, err
	}
	var names []string
	for _, m := range top.Methods {
		names = append(names, m.Name)
	}
	if err := inNameOrder("methods", names); err != nil {
		return nil, err
	}
	rpc := &RPC{Target: target}
	for _, d := range top.Declared {
		if !capabilityName.MatchString(d.Name) || (d.By != "host" && d.By != "client" && d.By != "control") {
			return nil, fmt.Errorf("x-declared-capabilities: %q by %q; each is <name>/<n>, by host, client or control (#1748)", d.Name, d.By)
		}
		rpc.Declared = append(rpc.Declared, Declared{d.Name, d.By, d.Description})
	}
	for _, m := range top.Methods {
		if len(m.Params) != 1 || m.Params[0].Name != "params" {
			return nil, fmt.Errorf("%s: a method has one param, `params`, the whole of JSON-RPC's params", m.Name)
		}
		if m.Note == (m.Result != nil) {
			return nil, fmt.Errorf("%s: a notification has no result, and a method has one", m.Name)
		}
		if !capabilityName.MatchString(m.Cap) {
			return nil, fmt.Errorf("%s: x-capability is %q; each method names its capability as <name>/<n>, such as agents/1 (#1748)", m.Name, m.Cap)
		}
		method := Method{Name: m.Name, Capability: m.Cap, Notification: m.Note, Params: m.Params[0].Schema}
		for _, t := range m.Tags {
			method.Web = method.Web || t.Name == "web"
		}
		if m.Result != nil {
			method.Result = m.Result.Schema
		}
		for _, s := range []*Schema{method.Params, method.Result} {
			if err := doc.checkRefs(s, m.Name); err != nil {
				return nil, err
			}
		}
		rpc.Methods = append(rpc.Methods, method)
	}
	sort.Slice(rpc.Methods, func(i, j int) bool {
		a, b := rpc.Methods[i], rpc.Methods[j]
		if a.Notification != b.Notification {
			return b.Notification
		}
		return a.Name < b.Name
	})
	for name, e := range top.Components.Errors {
		rpc.Errors = append(rpc.Errors, RPCError{name, e.Code})
	}
	sort.Slice(rpc.Errors, func(i, j int) bool { return rpc.Errors[i].Name < rpc.Errors[j].Name })
	return rpc, nil
}
