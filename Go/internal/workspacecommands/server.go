package workspacecommands

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"sort"
	"strings"
	"sync"
	"unicode/utf8"
)

// The MCP server, as the Swift MCPServerKit served it: newline-delimited JSON-RPC 2.0 on
// stdio, each line answered as it finishes and written whole, one at a time. It answers
// initialize, ping, the tool methods, and empty lists of resources and events. No SDK: the
// methods are few, and their errors and words stay as a provider map written for the Swift
// server knows them.

// ProtocolVersions are newest first; the first is offered to a client that asks for one not
// here.
var ProtocolVersions = []string{"2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"}

// MaxLine is the longest line read; a longer one is refused unread.
const MaxLine = 1 << 20

// Instructions are the server's words.
var Instructions = fmt.Sprintf("A machine provider (contract %d): lists, starts and stops workspaces by running the shell commands it was configured with.", Contract)

// RPCError is a JSON-RPC error answer.
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *RPCError) Error() string { return e.Message }

func invalidParams(message string) *RPCError { return &RPCError{-32602, message} }

// Property is one argument of a tool.
type Property struct {
	Name        string
	Kind        string // "string" or "object"
	Description string
	MaxLength   int
}

// Tool is a tool as tools/list gives it.
type Tool struct {
	Name        string
	Title       string
	Description string
	Properties  []Property
	Required    []string
	Annotations map[string]any
}

// JSON is the tool as tools/list gives it.
func (t Tool) JSON() map[string]any {
	properties := map[string]any{}
	for _, p := range t.Properties {
		o := map[string]any{"type": p.Kind}
		if p.Description != "" {
			o["description"] = p.Description
		}
		if p.MaxLength > 0 {
			o["maxLength"] = p.MaxLength
		}
		properties[p.Name] = o
	}
	required := t.Required
	if required == nil {
		required = []string{}
	}
	o := map[string]any{"name": t.Name, "title": t.Title, "description": t.Description,
		"inputSchema": map[string]any{"type": "object", "properties": properties, "required": required,
			"additionalProperties": false}}
	if t.Annotations != nil {
		o["annotations"] = t.Annotations
	}
	return o
}

// check is arguments (null or missing as {}) once checked: required keys, no others,
// types and lengths.
func (t Tool) check(arguments any) (map[string]any, error) {
	var given map[string]any
	switch a := arguments.(type) {
	case nil:
		given = map[string]any{}
	case map[string]any:
		given = a
	default:
		return nil, invalidParams("arguments must be an object")
	}
	for _, key := range t.Required {
		if v, ok := given[key]; !ok || v == nil {
			return nil, invalidParams("missing " + key)
		}
	}
	keys := make([]string, 0, len(given))
	for k := range given {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, key := range keys {
		var property *Property
		for i := range t.Properties {
			if t.Properties[i].Name == key {
				property = &t.Properties[i]
			}
		}
		if property == nil {
			names := make([]string, len(t.Properties))
			for i, p := range t.Properties {
				names[i] = p.Name
			}
			return nil, invalidParams("unknown argument " + key + "; takes " + strings.Join(names, ", "))
		}
		switch property.Kind {
		case "object":
			if _, ok := given[key].(map[string]any); !ok {
				return nil, invalidParams(key + " must be an object")
			}
		default:
			s, ok := given[key].(string)
			if !ok {
				return nil, invalidParams(key + " must be a string")
			}
			if property.MaxLength > 0 && utf8.RuneCountInString(s) > property.MaxLength {
				return nil, invalidParams(fmt.Sprintf("%s is over %d characters", key, property.MaxLength))
			}
		}
	}
	return given, nil
}

// Server is the command provider as an MCP server.
type Server struct {
	Provider *Provider
	Version  string
	tools    []Tool
}

// NewServer is the server for a configuration, with its tools.
func NewServer(config Config, timing Timing, run Runner, version string) *Server {
	id := []Property{{Name: "id", Kind: "string", Description: "The workspace's id, as workspaces_list gives it.", MaxLength: 512}}
	readOnly := map[string]any{"readOnlyHint": true}
	tools := []Tool{
		{Name: "workspaces_list", Title: "List workspaces",
			Description: "Every workspace, with its state and how to reach it over ssh.", Annotations: readOnly},
		{Name: "workspace_start", Title: "Start a machine",
			Description: "Starts the workspace and answers once it is running, or with why it isn't.",
			Properties:  id, Required: []string{"id"}},
		{Name: "workspace_stop", Title: "Stop a workspace",
			Description: "Stops the workspace and answers once it is stopped, or with why it isn't.",
			Properties:  id, Required: []string{"id"}},
	}
	if config.Making.CanCreate() {
		tools = append(tools,
			Tool{Name: "workspace_options", Title: "New workspace options",
				Description: "The choices for a new machine, as a JSON Schema object.", Annotations: readOnly},
			Tool{Name: "workspace_create", Title: "Make a workspace",
				Description: "Makes a workspace with the choices given, and answers once it is listed.",
				Properties: []Property{
					{Name: "name", Kind: "string", Description: "The new machine's name.", MaxLength: 128},
					{Name: "options", Kind: "object", Description: "The choices, as workspace_options describes them."},
					{Name: "firstBoot", Kind: "string", Description: "A command to run on its first boot.", MaxLength: 8192},
				}, Required: []string{"name"}})
	}
	if config.Making.CanDelete() {
		tools = append(tools, Tool{Name: "workspace_delete", Title: "Delete a workspace",
			Description: "Deletes the workspace and everything on it.", Properties: id, Required: []string{"id"},
			Annotations: map[string]any{"destructiveHint": true}})
	}
	return &Server{Provider: &Provider{Config: config, Timing: timing, Run: run}, Version: version, tools: tools}
}

// Handle answers one method with its params (decoded, numbers as json.Number).
func (s *Server) Handle(method string, params map[string]any) (any, error) {
	switch method {
	case "initialize":
		version := ProtocolVersions[0]
		if asked, ok := params["protocolVersion"].(string); ok && contains(ProtocolVersions, asked) {
			version = asked
		}
		return map[string]any{
			"protocolVersion": version,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "workspace-commands", "title": "Workspace commands", "version": s.Version},
			"instructions":    Instructions,
		}, nil
	case "ping":
		return map[string]any{}, nil
	case "tools/list":
		tools := make([]any, len(s.tools))
		for i, t := range s.tools {
			tools[i] = t.JSON()
		}
		return map[string]any{"tools": tools}, nil
	case "tools/call":
		name, ok := params["name"].(string)
		for _, t := range s.tools {
			if ok && t.Name == name {
				return s.call(t, params["arguments"])
			}
		}
		if !ok {
			name = "undefined"
		}
		return nil, invalidParams("no tool " + name)
	case "resources/list":
		return map[string]any{"resources": []any{}}, nil
	case "resources/templates/list":
		return map[string]any{"resourceTemplates": []any{}}, nil
	case "resources/read":
		uri, ok := params["uri"].(string)
		if !ok {
			uri = "undefined"
		}
		return nil, &RPCError{-32002, "no resource " + uri}
	case "events/list":
		return map[string]any{"events": []any{}}, nil
	case "events/poll":
		name, ok := params["name"].(string)
		if !ok {
			name = "undefined"
		}
		return nil, &RPCError{-32011, "no event " + name + "; this server offers "}
	}
	return nil, &RPCError{-32601, "no method " + method}
}

func (s *Server) call(tool Tool, arguments any) (any, error) {
	args, err := tool.check(arguments)
	if err != nil {
		return nil, err
	}
	p := s.Provider
	id, _ := args["id"].(string)
	var result map[string]any
	switch tool.Name {
	case "workspaces_list":
		var all []Workspace
		if all, err = p.List(); err == nil {
			listed := make([]any, len(all))
			for i, w := range all {
				listed[i] = w.JSON()
			}
			result = map[string]any{"contract": Contract, "workspaces": listed}
		}
	case "workspace_start", "workspace_stop":
		var w Workspace
		if tool.Name == "workspace_start" {
			w, err = p.Start(id)
		} else {
			w, err = p.Stop(id)
		}
		if err == nil {
			result = map[string]any{"workspace": w.JSON()}
		}
	case "workspace_options":
		schema := any(p.Config.Making.Options)
		if p.Config.Making.Options == nil {
			schema = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		result = map[string]any{"schema": schema}
	case "workspace_create":
		name, _ := args["name"].(string)
		options, _ := args["options"].(map[string]any)
		firstBoot, _ := args["firstBoot"].(string)
		var w Workspace
		if w, err = p.Create(name, options, firstBoot); err == nil {
			result = map[string]any{"workspace": w.JSON(), "firstBootRuns": p.Config.Making.FirstBootRuns()}
		}
	case "workspace_delete":
		if err = p.Delete(id); err == nil {
			result = map[string]any{}
		}
	}
	if err != nil {
		if failure, ok := err.(Failure); ok {
			return map[string]any{"content": []any{map[string]any{"type": "text", "text": failure.Reason}}, "isError": true}, nil
		}
		return nil, err
	}
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": string(encode(result))}},
		"structuredContent": result}, nil
}

// encode is v as JSON with its keys sorted and nothing escaped for HTML.
func encode(v any) []byte {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return []byte(`{}`)
	}
	return bytes.TrimRight(b.Bytes(), "\n")
}

// Answer is the line to write back for one line read, or nil when there is nothing to
// answer: a request, a notification (answered with nothing), or a batch of them.
func (s *Server) Answer(line []byte) []byte {
	if len(bytes.TrimSpace(line)) == 0 {
		return nil
	}
	if len(line) > MaxLine {
		return encode(failure(nil, &RPCError{-32600, "message too large"}))
	}
	parsed, err := decode(line)
	if err != nil {
		return encode(failure(nil, &RPCError{-32700, "parse error"}))
	}
	if batch, ok := parsed.([]any); ok {
		answers := make([]any, len(batch))
		var wg sync.WaitGroup
		for i, message := range batch {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if a := s.answer(message); a != nil {
					answers[i] = a
				}
			}()
		}
		wg.Wait()
		var out []any
		for _, a := range answers {
			if a != nil {
				out = append(out, a)
			}
		}
		if len(out) == 0 {
			return nil
		}
		return encode(out)
	}
	if a := s.answer(parsed); a != nil {
		return encode(a)
	}
	return nil
}

// answer is the answer to one message, or nil for a notification or a client's response.
func (s *Server) answer(message any) map[string]any {
	m, _ := message.(map[string]any)
	id, hasID := m["id"]
	method, isRequest := m["method"].(string)
	if version, _ := m["jsonrpc"].(string); version != "2.0" || !isRequest {
		_, hasMethod := m["method"]
		_, hasResult := m["result"]
		_, hasError := m["error"]
		if hasID && !hasMethod && (hasResult || hasError) {
			return nil
		}
		return failure(id, &RPCError{-32600, "not a JSON-RPC 2.0 request"})
	}
	params, _ := m["params"].(map[string]any)
	result, err := s.Handle(method, params)
	if !hasID {
		return nil
	}
	if err != nil {
		rpc, ok := err.(*RPCError)
		if !ok {
			log.Printf("workspace-commands: %s failed: %v", method, err)
			rpc = &RPCError{-32603, err.Error()}
		}
		return failure(id, rpc)
	}
	return map[string]any{"jsonrpc": "2.0", "id": id, "result": result}
}

func failure(id any, err *RPCError) map[string]any {
	return map[string]any{"jsonrpc": "2.0", "id": id, "error": err}
}

// Serve answers in until it ends, writing to out, then waits for the answers still being
// worked out.
func (s *Server) Serve(in io.Reader, out io.Writer) error {
	var writeMu sync.Mutex
	var answering sync.WaitGroup
	defer answering.Wait()
	r := bufio.NewReaderSize(in, 64<<10)
	for {
		line, err := readLine(r)
		if len(line) > 0 {
			answering.Add(1)
			go func() {
				defer answering.Done()
				if answer := s.Answer(line); answer != nil {
					writeMu.Lock()
					defer writeMu.Unlock()
					_, _ = out.Write(append(answer, '\n'))
				}
			}()
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// readLine is the next line without its line ending. A line over MaxLine is kept only to
// just past MaxLine, for its answer to refuse; the rest is read and dropped.
func readLine(r *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		part, more, err := r.ReadLine()
		if len(line) <= MaxLine {
			line = append(line, part[:min(len(part), MaxLine+1-len(line))]...)
		}
		if err != nil || !more {
			return line, err
		}
	}
}
