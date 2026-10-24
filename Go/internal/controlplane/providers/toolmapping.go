package providers

import (
	"encoding/json"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"
)

// ToolMapping is ToolMapping: how the control plane reads a provider's tools, the
// contract's own (contracts/provider-contract.md), or another server's through a tool map
// (contracts/tool-map.md).
type ToolMapping struct {
	List  Call
	Start Call
	Stop  Call
	// Making and deleting (US5), when the provider can.
	Options *Call
	Create  *Call
	Delete  *Call
	// A map's create: whether the server runs {firstBoot} on the new machine.
	FirstBootRuns bool
	Listing       Listing
	// The contract's own tools, read as the contract says; false for a map.
	Native bool
}

// Call is ToolMapping.Call: one contract tool and what stands for it.
type Call struct {
	Tool string
	// A template for its arguments; {id} is the workspace's id.
	Arguments any
}

// Listing is ToolMapping.Listing: where a list's workspaces are in the result.
type Listing struct {
	// The array: a path, droplets[] or droplets; empty for the result itself.
	Items string
	ID    string
	Name  string
	State string
	SSH   string
	// "" for none.
	Tunnel        string
	HostKeyRenews string
	Cost          string
	// Its words for a state, lower-cased, to a contract state.
	States map[string]string
}

// ContractMapping is ToolMapping.contract: the contract's tools, as a provider that
// follows it offers them.
var ContractMapping = ToolMapping{
	List:    Call{Tool: "workspaces_list"},
	Start:   Call{Tool: "workspace_start", Arguments: map[string]any{"id": "{id}"}},
	Stop:    Call{Tool: "workspace_stop", Arguments: map[string]any{"id": "{id}"}},
	Options: &Call{Tool: "workspace_options"},
	Create: &Call{Tool: "workspace_create", Arguments: map[string]any{
		"name": "{name}", "options": "{options}", "firstBoot": "{firstBoot}"}},
	Delete: &Call{Tool: "workspace_delete", Arguments: map[string]any{"id": "{id}"}},
	Listing: Listing{Items: "workspaces", ID: "id", Name: "name", State: "state", SSH: "ssh", Tunnel: "tunnel",
		HostKeyRenews: "hostKeyRenews", Cost: "cost", States: map[string]string{}},
	Native: true,
}

// RequiredTools is ToolMapping.required.
var RequiredTools = []string{"workspaces_list", "workspace_start", "workspace_stop"}

// optionalTools is ToolMapping.optional.
var optionalTools = map[string]string{"workspace_options": "options", "workspace_create": "create", "workspace_delete": "delete"}

// ContractStates is ToolMapping.states.
var ContractStates = []string{"running", "starting", "stopping", "stopped", "unknown"}

func isContractState(s string) bool {
	for _, c := range ContractStates {
		if c == s {
			return true
		}
	}
	return false
}

// MapFrom is ToolMapping.map: a map as the provider's record keeps it, or what is wrong
// with it.
func MapFrom(m any) (ToolMapping, error) {
	call := func(key string) (Call, error) {
		tool, _ := str(get(get(m, key), "tool"))
		if tool == "" {
			return Call{}, providerFailure("The tool map has no %s.tool.", key)
		}
		return Call{Tool: tool, Arguments: get(get(m, key), "arguments")}, nil
	}
	list := get(m, "list")
	path := func(key string, required bool) (string, error) {
		value, _ := str(get(list, key))
		if required && value == "" {
			return "", providerFailure("The tool map has no list.%s.", key)
		}
		return value, nil
	}
	states := map[string]string{}
	if given, ok := obj(get(list, "states")); ok {
		for word, state := range given {
			s, ok := str(state)
			if !ok || !isContractState(s) {
				return ToolMapping{}, providerFailure("list.states.%s must be one of %s.", word, strings.Join(ContractStates, ", "))
			}
			states[strings.ToLower(word)] = s
		}
	}
	optional := func(key string) (*Call, error) {
		if !has(m, key) {
			return nil, nil
		}
		c, err := call(key)
		return &c, err
	}
	var out ToolMapping
	var err error
	if out.List, err = call("list"); err != nil {
		return out, err
	}
	if out.Start, err = call("start"); err != nil {
		return out, err
	}
	if out.Stop, err = call("stop"); err != nil {
		return out, err
	}
	if out.Options, err = optional("options"); err != nil {
		return out, err
	}
	if out.Create, err = optional("create"); err != nil {
		return out, err
	}
	if out.Delete, err = optional("delete"); err != nil {
		return out, err
	}
	out.FirstBootRuns, _ = boolean(get(get(m, "create"), "firstBootRuns"))
	l := Listing{States: states}
	for _, p := range []struct {
		key      string
		into     *string
		required bool
	}{{"items", &l.Items, false}, {"id", &l.ID, true}, {"name", &l.Name, true}, {"state", &l.State, true},
		{"ssh", &l.SSH, false}, {"tunnel", &l.Tunnel, false},
		{"hostKeyRenews", &l.HostKeyRenews, false}, {"cost", &l.Cost, false}} {
		if *p.into, err = path(p.key, p.required); err != nil {
			return out, err
		}
	}
	out.Listing = l
	return out, nil
}

// Missing is ToolMapping.missing: the tool its server lacks, first in the order list,
// start, stop, then the optional ones it names; "" for none.
func (m ToolMapping) Missing(tools []string) string {
	names := []string{m.List.Tool, m.Start.Tool, m.Stop.Tool}
	for _, c := range []*Call{m.Options, m.Create, m.Delete} {
		if c != nil {
			names = append(names, c.Tool)
		}
	}
	for _, n := range names {
		found := false
		for _, t := range tools {
			found = found || t == n
		}
		if !found {
			return n
		}
	}
	return ""
}

// Capabilities is ToolMapping.capabilities: what a map can do besides list, start and stop.
func (m ToolMapping) Capabilities() []string {
	out := []string{}
	for _, c := range []struct {
		name string
		call *Call
	}{{"options", m.Options}, {"create", m.Create}, {"delete", m.Delete}} {
		if c.call != nil {
			out = append(out, c.name)
		}
	}
	return out
}

// ArgumentsFor is ToolMapping.arguments(_:id:): a call's arguments, {id} filled in.
func (m ToolMapping) ArgumentsFor(c Call, id string) any {
	return m.Arguments(c, map[string]any{"id": id})
}

// Arguments is ToolMapping.arguments(_:values:): a call's arguments, with each {key}
// filled in. A string that is only {key} becomes the value itself; a key with no value
// leaves it out.
func (m ToolMapping) Arguments(c Call, values map[string]any) any {
	if c.Arguments == nil {
		return map[string]any{}
	}
	if filled := fill(c.Arguments, values); filled != nil {
		return filled
	}
	return map[string]any{}
}

// Content is ToolMapping.content(of:): what a tool answered, as JSON: structuredContent,
// or its first text parsed. A result with isError is its text, cut to 1 KB.
func Content(result any) (any, error) {
	var text *string
	if items, ok := arr(get(result, "content")); ok {
		for _, item := range items {
			if strOr(get(item, "type")) == "text" {
				if t, ok := str(get(item, "text")); ok {
					text = &t
				}
				break
			}
		}
	}
	if b, _ := boolean(get(result, "isError")); b {
		said := ""
		if text != nil {
			said = strings.TrimSpace(*text)
		}
		if said == "" {
			return nil, providerFailure("The provider said no, and not why.")
		}
		if len(said) > 1024 {
			said = strings.ToValidUTF8(said[:1024], "�")
		}
		return nil, &ProviderFailure{said}
	}
	if has(result, "structuredContent") {
		return get(result, "structuredContent"), nil
	}
	if text != nil {
		if parsed, err := parseJSON([]byte(*text)); err == nil {
			return parsed, nil
		}
	}
	return nil, providerFailure("The provider’s answer isn’t JSON.")
}

// Workspaces is ToolMapping.workspaces: the workspaces a list result holds, at most 200.
// One with no id or name is left out.
func (m ToolMapping) Workspaces(content any) []MachineInfo {
	items, _ := arr(pathValue(m.Listing.Items, content))
	if len(items) > 200 {
		items = items[:200]
	}
	out := []MachineInfo{}
	listed := map[string]bool{}
	for _, item := range items {
		// A second workspace with an id already listed is left out: a link and a start name
		// one workspace by its id (#857).
		if w := m.Workspace(item); w != nil && !listed[w.ID] {
			listed[w.ID] = true
			out = append(out, *w)
		}
	}
	return out
}

// Workspace is ToolMapping.workspace: one workspace, from an item of a list, or a start's
// or stop's workspace.
func (m ToolMapping) Workspace(item any) *MachineInfo {
	id, ok := pathText(m.Listing.ID, item)
	if !ok || id == "" {
		return nil
	}
	name, ok := pathText(m.Listing.Name, item)
	if !ok || name == "" {
		return nil
	}
	said := "unknown"
	if s, ok := pathText(m.Listing.State, item); ok {
		said = strings.ToLower(s)
	}
	state, ok := m.Listing.States[said]
	if !ok {
		state = "unknown"
		if isContractState(said) {
			state = said
		}
	}
	w := &MachineInfo{ID: id, Name: name, State: state}
	if m.Listing.SSH != "" {
		ssh, _ := pathText(m.Listing.SSH, item)
		w.SSH = optional(ssh)
	}
	if m.Listing.Tunnel != "" {
		if b, ok := boolean(pathValue(m.Listing.Tunnel, item)); ok {
			w.Tunnel = &b
		}
	}
	if m.Listing.HostKeyRenews != "" {
		if b, ok := boolean(pathValue(m.Listing.HostKeyRenews, item)); ok && b {
			w.HostKeyRenews = &b
		}
	}
	if m.Listing.Cost != "" {
		if cost, ok := pathText(m.Listing.Cost, item); ok {
			if utf8.RuneCountInString(cost) > 120 {
				cost = string([]rune(cost)[:120])
			}
			w.Cost = optional(cost)
		}
	}
	return w
}

// pathValue is ToolMapping.value(_:in:): the value at a path of dotted keys, [n] indexes
// and a trailing [] (the array itself). Empty is the value.
func pathValue(path string, v any) any {
	path = strings.TrimSuffix(path, "[]")
	current := v
	for _, part := range strings.Split(path, ".") {
		if part == "" {
			continue
		}
		key := part
		var indexes []int
		for strings.HasSuffix(key, "]") {
			open := strings.LastIndexByte(key, '[')
			if open < 0 {
				break
			}
			n, err := strconv.Atoi(key[open+1 : len(key)-1])
			if err != nil {
				return nil
			}
			indexes = append([]int{n}, indexes...)
			key = key[:open]
		}
		if key != "" {
			current = get(current, key)
		}
		for _, n := range indexes {
			a, ok := arr(current)
			if !ok || n < 0 || n >= len(a) {
				return nil
			}
			current = a[n]
		}
		if current == nil {
			return nil
		}
	}
	return current
}

// pathText is ToolMapping.text(_:in:): a path's value as text, or a template's:
// root@{networks.v4[0].ip_address} fills each {path}, and is nothing when any of them
// finds nothing.
func pathText(pathOrTemplate string, v any) (string, bool) {
	if !strings.Contains(pathOrTemplate, "{") {
		return scalar(pathValue(pathOrTemplate, v))
	}
	var out strings.Builder
	rest := pathOrTemplate
	for {
		open := strings.IndexByte(rest, '{')
		if open < 0 {
			break
		}
		close := strings.IndexByte(rest[open:], '}')
		if close < 0 {
			break
		}
		close += open
		out.WriteString(rest[:open])
		found, ok := scalar(pathValue(rest[open+1:close], v))
		if !ok {
			return "", false
		}
		out.WriteString(found)
		rest = rest[close+1:]
	}
	out.WriteString(rest)
	return out.String(), true
}

// scalar is ToolMapping.scalar: a string, a bool or a number as text.
func scalar(v any) (string, bool) {
	switch t := v.(type) {
	case string:
		return t, true
	case bool:
		return strconv.FormatBool(t), true
	case json.Number:
		if i, err := strconv.ParseInt(string(t), 10, 64); err == nil {
			return strconv.FormatInt(i, 10), true
		}
		f, err := t.Float64()
		if err != nil {
			return "", false
		}
		return double(f), true
	case float64:
		return double(t), true
	case int:
		return strconv.Itoa(t), true
	}
	return "", false
}

// double is a Double as Swift's String(d) says it, a whole one as an Int.
func double(f float64) string {
	if f == math.Trunc(f) && math.Abs(f) < 1e15 {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// fill is ToolMapping.fill: a JSON template with each {key} in its strings filled in. A
// string that is only {key} is the value as it is; one whose key has no value is nil, and
// left out of what holds it.
func fill(template any, values map[string]any) any {
	switch t := template.(type) {
	case string:
		if len(t) >= 2 && strings.HasPrefix(t, "{") && strings.HasSuffix(t, "}") && !strings.Contains(t[1:], "{") {
			key := t[1 : len(t)-1]
			// {id:number}: for a server whose ids are numbers (DigitalOcean's).
			if base, ok := strings.CutSuffix(key, ":number"); ok {
				value, found := values[base]
				if !found {
					return nil
				}
				text, ok := str(value)
				if !ok {
					if text, ok = scalar(value); !ok {
						return nil
					}
				}
				if whole, err := strconv.Atoi(text); err == nil {
					return whole
				}
				if number, err := strconv.ParseFloat(text, 64); err == nil && !math.IsInf(number, 0) && !math.IsNaN(number) {
					return number
				}
				return nil
			}
			return values[key]
		}
		out := t
		for key, value := range values {
			text, ok := scalar(value)
			if !ok {
				continue
			}
			out = strings.ReplaceAll(out, "{"+key+"}", text)
		}
		return out
	case []any:
		out := []any{}
		for _, item := range t {
			if f := fill(item, values); f != nil {
				out = append(out, f)
			}
		}
		return out
	case map[string]any:
		out := map[string]any{}
		for k, item := range t {
			if f := fill(item, values); f != nil {
				out[k] = f
			}
		}
		return out
	}
	return template
}
