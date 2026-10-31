// Package workspacecommands is the command provider (#691, FR-070; in Go since #1364): a
// machine provider whose workspaces are shell commands. It follows the provider contract
// (specs/691-workspace-providers/contracts/provider-contract.md) and its own
// (contracts/command-provider.md), so the control plane uses it as it uses any other
// provider, and a configuration written for the Swift one works unchanged.
package workspacecommands

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// State is a workspace's state, as the contract names them.
type State string

// The contract's states.
const (
	Running  State = "running"
	Starting State = "starting"
	Stopping State = "stopping"
	Stopped  State = "stopped"
	Unknown  State = "unknown"
)

// States is every state, in the order a refusal names them.
var States = []State{Running, Starting, Stopping, Stopped, Unknown}

func stateNamed(word string) (State, bool) {
	for _, s := range States {
		if string(s) == word {
			return s, true
		}
	}
	return "", false
}

// Commands are the commands and details of one workspace, or shared by every workspace a
// listing gives, as templates.
type Commands struct {
	Start string
	Stop  string
	// StartRequest and StopRequest are HTTP actions in place of Start and Stop (#1119).
	StartRequest *Request
	StopRequest  *Request
	// Status prints the workspace's state; "" when only a listing (or nothing) says.
	Status string
	// SSH is not a command: filled in without shell quoting. Nil for none.
	SSH    *string
	Tunnel bool
	// HostKeyRenews: the workspace's ssh host key is made again at each start (#1701).
	HostKeyRenews bool
	Cost          *string
}

// Entry is one workspace written out: its commands are run as they are, with ${id} and
// ${name} filled in.
type Entry struct {
	ID       string
	Name     string
	Commands Commands
}

// Shape is how a listing's output is read: columns, or JSON.
type Shape struct {
	// Columns: one workspace per line, split on whitespace into these names; the last
	// takes what is left of the line.
	Columns []string
	// JSON: the array at Items ("" for the whole output), and a path within each item for
	// each field (id, name, state, and any other a template names). Nil for columns.
	Fields map[string]string
	Items  string
}

// Listing is many workspaces from one command.
type Listing struct {
	Command string
	// Request is an HTTP action in place of Command (#1119): its answer is read as JSON.
	Request  *Request
	Shape    Shape
	Commands Commands
	// Defaults are values for a row that leaves a column or field empty, such as a
	// preset's ssh line.
	Defaults map[string]string
}

// Making is making and deleting workspaces (US5): only beside a listing, which finds what
// was made.
type Making struct {
	// Create makes one: ${name}, ${firstBoot} and each option's key are filled in.
	Create string
	// Delete deletes one: ${id} and its listing's values are filled in.
	Delete string
	// CreateRequest and DeleteRequest are HTTP actions in place of Create and Delete (#1119).
	CreateRequest *Request
	DeleteRequest *Request
	// Options is the New Machine form, as a flat JSON Schema object (workspace_options).
	Options map[string]any
}

// FirstBootRuns is whether a made workspace runs the first-boot install itself.
func (m Making) FirstBootRuns() bool {
	if m.CreateRequest != nil {
		data, _ := json.Marshal(m.CreateRequest.Body)
		return strings.Contains(string(data), "${firstBoot}")
	}
	return strings.Contains(m.Create, "${firstBoot}")
}

// CanCreate is whether it makes workspaces.
func (m Making) CanCreate() bool { return m.Create != "" || m.CreateRequest != nil }

// CanDelete is whether it deletes them.
func (m Making) CanDelete() bool { return m.Delete != "" || m.DeleteRequest != nil }

// Config is the command provider's whole configuration, from WORKSPACE_COMMANDS_CONFIG.
//
// Workspaces are either written out, each with its own commands, or listed by one command
// whose rows fill in shared templates. A preset is a set of these, compiled in.
type Config struct {
	Workspaces []Entry
	Listing    *Listing
	// States are the CLI's words for a state, lower-cased, to a contract state.
	States map[string]State
	Making Making
}

func newConfig(workspaces []Entry, listing *Listing, states map[string]State, making Making) Config {
	lowered := map[string]State{}
	for word, state := range states {
		if _, taken := lowered[strings.ToLower(word)]; !taken {
			lowered[strings.ToLower(word)] = state
		}
	}
	return Config{Workspaces: workspaces, Listing: listing, States: lowered, Making: making}
}

// StateFor is the contract state for what a status command or a listing said.
func (c Config) StateFor(said string) State {
	word := strings.ToLower(strings.TrimSpace(said))
	if s, ok := c.States[word]; ok {
		return s
	}
	if s, ok := stateNamed(word); ok {
		return s
	}
	return Unknown
}

// ConfigError is why a configuration can't be used, in words for the person who wrote it.
type ConfigError string

func (e ConfigError) Error() string { return string(e) }

// Parse reads WORKSPACE_COMMANDS_CONFIG's text.
func Parse(text string) (Config, error) {
	value, err := decode([]byte(text))
	if err != nil {
		return Config{}, ConfigError("WORKSPACE_COMMANDS_CONFIG isn't JSON")
	}
	return From(value)
}

// decode is JSON with its numbers kept as written.
func decode(data []byte) (any, error) {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	if d.More() {
		return nil, fmt.Errorf("more than one value")
	}
	return v, nil
}

// From reads a configuration already decoded (numbers as json.Number).
func From(value any) (Config, error) {
	o, ok := value.(map[string]any)
	if !ok {
		return Config{}, ConfigError("the configuration must be a JSON object")
	}
	if preset, ok := o["preset"].(string); ok {
		return expandPreset(preset, o)
	}
	states, err := stateMap(o)
	if err != nil {
		return Config{}, err
	}
	if given, present := o["list"]; present {
		list, isLine := given.(string)
		var request *Request
		if !isLine {
			r, err := requestFrom(given, "list")
			if err != nil {
				return Config{}, err
			}
			request = r
		} else if list == "" {
			return Config{}, ConfigError("list is empty")
		}
		var shape Shape
		if fields, ok := o["json"].(map[string]any); ok {
			paths := map[string]string{}
			for key, value := range fields {
				if key == "items" {
					continue
				}
				path, ok := value.(string)
				if !ok {
					return Config{}, ConfigError("json." + key + " must be a path")
				}
				paths[key] = path
			}
			if _, ok := paths["id"]; !ok {
				return Config{}, ConfigError("json needs an id path")
			}
			items, _ := fields["items"].(string)
			shape = Shape{Fields: paths, Items: items}
		} else if columns := strings_(o["columns"]); len(columns) > 0 {
			if !contains(columns, "id") {
				return Config{}, ConfigError("columns must name an id column")
			}
			shape = Shape{Columns: columns}
		} else if request != nil {
			return Config{}, ConfigError("a list request needs json paths")
		} else {
			return Config{}, ConfigError("a list needs columns, or json paths")
		}
		if request != nil && shape.Fields == nil {
			return Config{}, ConfigError("a list request needs json paths")
		}
		commands, err := commandsFrom(o, "")
		if err != nil {
			return Config{}, err
		}
		making, err := makingFrom(o)
		if err != nil {
			return Config{}, err
		}
		return newConfig(nil, &Listing{Command: list, Request: request, Shape: shape, Commands: commands}, states, making), nil
	}
	if _, ok := o["create"]; ok {
		return Config{}, ConfigError("create and delete need a list command, which finds what they made")
	}
	if _, ok := o["delete"]; ok {
		return Config{}, ConfigError("create and delete need a list command, which finds what they made")
	}
	items, _ := o["workspaces"].([]any)
	if len(items) == 0 {
		return Config{}, ConfigError("give workspaces, a list command, or a preset")
	}
	var entries []Entry
	for n, item := range items {
		fields, _ := item.(map[string]any)
		name, ok := fields["name"].(string)
		if !ok {
			name, _ = fields["id"].(string)
		}
		if name == "" {
			return Config{}, ConfigError(fmt.Sprintf("workspace %d has no name", n+1))
		}
		id, ok := fields["id"].(string)
		if !ok {
			id = name
		}
		for _, e := range entries {
			if e.ID == id {
				return Config{}, ConfigError("two workspaces are called " + id)
			}
		}
		commands, err := commandsFrom(fields, name+": ")
		if err != nil {
			return Config{}, err
		}
		entries = append(entries, Entry{ID: id, Name: name, Commands: commands})
	}
	return newConfig(entries, nil, states, Making{}), nil
}

// action is a command or a request at key: the line, the request, or neither.
func action(o map[string]any, key, whose string) (string, *Request, error) {
	given, present := o[key]
	if !present {
		return "", nil, nil
	}
	if line, ok := given.(string); ok {
		return line, nil, nil
	}
	r, err := requestFrom(given, whose+key)
	return "", r, err
}

func commandsFrom(o map[string]any, whose string) (Commands, error) {
	start, startRequest, err := action(o, "start", whose)
	if err != nil {
		return Commands{}, err
	}
	if start == "" && startRequest == nil {
		return Commands{}, ConfigError(whose + "no start command")
	}
	stop, stopRequest, err := action(o, "stop", whose)
	if err != nil {
		return Commands{}, err
	}
	if stop == "" && stopRequest == nil {
		return Commands{}, ConfigError(whose + "no stop command")
	}
	status, _ := o["status"].(string)
	tunnel, _ := o["tunnel"].(bool)
	c := Commands{Start: start, Stop: stop, StartRequest: startRequest, StopRequest: stopRequest,
		Status: status, SSH: nonEmpty(o["ssh"]), Tunnel: tunnel}
	if cost, ok := o["cost"].(string); ok {
		cost = prefix(cost, 120)
		c.Cost = &cost
	}
	return c, nil
}

func makingFrom(o map[string]any) (Making, error) {
	m := Making{}
	var err error
	if m.Create, m.CreateRequest, err = action(o, "create", ""); err != nil {
		return Making{}, err
	}
	if m.Delete, m.DeleteRequest, err = action(o, "delete", ""); err != nil {
		return Making{}, err
	}
	if options, present := o["options"]; present {
		object, ok := options.(map[string]any)
		if !ok {
			return Making{}, ConfigError("options must be a JSON Schema object")
		}
		if !m.CanCreate() {
			return Making{}, ConfigError("options are for a create command, and there is none")
		}
		m.Options = object
	}
	return m, nil
}

func stateMap(o map[string]any) (map[string]State, error) {
	given, present := o["states"]
	if !present {
		return map[string]State{}, nil
	}
	words, ok := given.(map[string]any)
	if !ok {
		return nil, ConfigError("states must map words to states")
	}
	out := map[string]State{}
	for word, value := range words {
		said, _ := value.(string)
		state, ok := stateNamed(said)
		if !ok {
			names := make([]string, len(States))
			for i, s := range States {
				names[i] = string(s)
			}
			return nil, ConfigError("states." + word + " must be one of " + strings.Join(names, ", "))
		}
		out[word] = state
	}
	return out, nil
}

// nonEmpty is a string value that is not empty, or nil.
func nonEmpty(v any) *string {
	if s, ok := v.(string); ok && s != "" {
		return &s
	}
	return nil
}

// strings_ is an array's strings, leaving out anything else.
func strings_(v any) []string {
	array, _ := v.([]any)
	var out []string
	for _, item := range array {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// prefix is the first n characters of s.
func prefix(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// Fill is template with each ${key} replaced by its value, quoted for /bin/sh when quoted.
// A key with no value is left as it is, so the shell can read a variable of that name (a
// secret, such as $TOKEN written ${TOKEN}).
func Fill(template string, values map[string]string, quoted bool) string {
	var out strings.Builder
	rest := template
	for {
		open := strings.Index(rest, "${")
		if open < 0 {
			break
		}
		out.WriteString(rest[:open])
		closing := strings.IndexByte(rest[open+2:], '}')
		if closing < 0 {
			rest = rest[open:]
			break
		}
		closing += open + 2
		key := rest[open+2 : closing]
		if value, ok := values[key]; ok {
			if quoted {
				value = ShellQuoted(value)
			}
			out.WriteString(value)
		} else {
			out.WriteString(rest[open : closing+1])
		}
		rest = rest[closing+1:]
	}
	out.WriteString(rest)
	return out.String()
}

// ShellQuoted is one word to /bin/sh, whatever it holds.
func ShellQuoted(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

// PathValue is the value at a path into JSON: dotted keys, [n] indexes, [key=value] (the
// first item whose key is that value, as in networks.v4[type=public].ip_address), and []
// (the rest of the path for each item, and the lists it finds joined into one, as in
// reservationSet[].instancesSet). Empty is the value itself; nil when there is none.
func PathValue(path string, value any) any {
	var steps []string
	for _, part := range strings.Split(path, ".") {
		if part == "" {
			continue
		}
		key := part
		var selectors []string
		for strings.HasSuffix(key, "]") {
			open := strings.LastIndexByte(key, '[')
			if open < 0 {
				break
			}
			selectors = append([]string{"[" + key[open+1:len(key)-1]}, selectors...)
			key = key[:open]
		}
		if key != "" {
			steps = append(steps, key)
		}
		steps = append(steps, selectors...)
	}
	return walk(steps, value)
}

// walk follows the steps of a path: a key, or "[" and what was between the brackets.
func walk(steps []string, current any) any {
	for i, step := range steps {
		if current == nil {
			return nil
		}
		if !strings.HasPrefix(step, "[") {
			o, _ := current.(map[string]any)
			current = o[step]
			continue
		}
		array, _ := current.([]any)
		selector := step[1:]
		if selector == "" {
			joined := []any{}
			for _, item := range array {
				switch found := walk(steps[i+1:], item).(type) {
				case nil:
				case []any:
					joined = append(joined, found...)
				default:
					joined = append(joined, found)
				}
			}
			return joined
		}
		current = nil
		if field, want, ok := strings.Cut(selector, "="); ok {
			for _, item := range array {
				if text, ok := PathText(field, item); ok && text == want {
					current = item
					break
				}
			}
			continue
		}
		n, err := strconv.Atoi(selector)
		if err != nil {
			return nil
		}
		if n >= 0 && n < len(array) {
			current = array[n]
		}
	}
	return current
}

// PathText is the value at path as text: strings as they are, numbers and booleans written
// out; "" and false when it is none of those.
func PathText(path string, value any) (string, bool) {
	switch v := PathValue(path, value).(type) {
	case string:
		return v, true
	case json.Number:
		return v.String(), true
	case float64:
		return fmt.Sprint(v), true
	case bool:
		if v {
			return "true", true
		}
		return "false", true
	}
	return "", false
}

// isBlank is CharacterSet.whitespaces: spaces and tabs, not newlines.
func isBlank(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) }
