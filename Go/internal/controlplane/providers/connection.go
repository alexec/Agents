package providers

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Provider is WorkspaceProvider: what the control plane asks of a provider, a Connection
// or a stand-in in tests.
type Provider interface {
	Check() (Checked, error)
	List() ([]MachineInfo, error)
	// Start starts the workspace; its state after, when the provider said.
	Start(id string) (*MachineInfo, error)
	Stop(id string) (*MachineInfo, error)
	// Options is the New Machine form, a JSON Schema object (US5).
	Options() (any, error)
	// Create makes one: what it made when the provider said, and whether firstBoot will run.
	Create(name string, options any, firstBoot *string) (*MachineInfo, bool, error)
	Delete(id string) error
	// Tools is every tool the server offers, as it described them (#858).
	Tools() ([]any, error)
	End()
}

// CannotMake is WorkspaceProvider's defaults, for a stand-in to embed: it cannot make,
// delete or list its tools.
type CannotMake struct{}

func (CannotMake) Options() (any, error) { return nil, providerFailure("It can’t make workspaces.") }
func (CannotMake) Create(string, any, *string) (*MachineInfo, bool, error) {
	return nil, false, providerFailure("It can’t make workspaces.")
}
func (CannotMake) Delete(string) error   { return providerFailure("It can’t delete workspaces.") }
func (CannotMake) Tools() ([]any, error) { return nil, providerFailure("It can’t list its tools.") }

// Checked is ProviderConnection.Checked: what Check found.
type Checked struct {
	Capabilities []string
	Contract     int
	Workspaces   []MachineInfo
	// For a tool map: how many items were at list.items, and the first, so a writer can see
	// what a map that reads none of them missed (#858). Items is -1 when not said.
	Items     int
	FirstItem any
}

// CallTiming is ProviderConnection.Timing: how long a call may take, a list, then a start
// or stop.
type CallTiming struct {
	Quick time.Duration
	Long  time.Duration
}

// StandardCalls is ProviderConnection.Timing.standard.
var StandardCalls = CallTiming{Quick: 30 * time.Second, Long: 600 * time.Second}

// Contracts is ProviderConnection.contracts: the contract versions this control plane reads.
var Contracts = []int{1}

// Connection is ProviderConnection: one provider's MCP server, reached as its record says,
// the command provider, a server the control plane runs, or one at an address. It checks
// the server is a provider, and calls its tools with the contract's timeouts (FR-005).
type Connection struct {
	Record  ProviderRecord
	server  mcpServer
	mapping ToolMapping
	cwd     string
	timing  CallTiming
	log     func(string)

	connecting sync.Mutex
	mu         sync.Mutex
	client     *mcpClient
}

// NewConnection is ProviderConnection.init: an error when the record cannot be reached as
// it is, a map that does not parse or no command provider to run. commandProvider is
// CommandProvider's answer, "" for none.
func NewConnection(record ProviderRecord, secrets map[string]string, cwd string, timing CallTiming,
	commandProvider string, log func(string)) (*Connection, error) {
	mapping := ContractMapping
	if record.Map != nil {
		m, err := MapFrom(record.Map)
		if err != nil {
			return nil, err
		}
		mapping = m
	}
	server, err := serverFor(record, secrets, commandProvider)
	if err != nil {
		return nil, err
	}
	if log == nil {
		log = func(string) {}
	}
	return &Connection{Record: record, server: server, mapping: mapping, cwd: cwd, timing: timing, log: log}, nil
}

// serverFor is ProviderConnection.server(for:): the MCP server a record stands for, with
// its secrets as environment for one it runs, in its headers for one at an address.
func serverFor(record ProviderRecord, secrets map[string]string, commandProvider string) (mcpServer, error) {
	name := "provider " + record.ID
	switch record.Kind {
	case KindCommands:
		if commandProvider == "" {
			return mcpServer{}, providerFailure("workspace-commands isn’t installed beside the control plane.")
		}
		commands := record.Commands
		if commands == nil {
			commands = map[string]any{}
		}
		config, _ := json.Marshal(commands)
		env := map[string]string{}
		for k, v := range secrets {
			env[k] = v
		}
		env["WORKSPACE_COMMANDS_CONFIG"] = string(config)
		return mcpServer{Name: name, Command: commandProvider, Args: []string{}, Env: env}, nil
	case KindStdio:
		command := ""
		if record.Command != nil {
			command = *record.Command
		}
		return mcpServer{Name: name, Command: command, Args: record.Args, Env: secrets}, nil
	case KindHTTP:
		headers := map[string]string{}
		for k, v := range record.Headers {
			for secret, value := range secrets {
				v = strings.ReplaceAll(v, "${"+secret+"}", value)
			}
			headers[k] = v
		}
		address := ""
		if record.URL != nil {
			address = *record.URL
		}
		return mcpServer{Name: name, HTTP: true, URL: address, Headers: headers}, nil
	}
	return mcpServer{}, providerFailure("It is no kind of provider this control plane knows.")
}

// CommandProvider is ProviderConnection.commandProvider: workspace-commands beside the
// running program, then AGENTS_WORKSPACE_COMMANDS, then on PATH; "" for none.
func CommandProvider() string {
	var candidates []string
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "workspace-commands"))
	}
	if given := os.Getenv("AGENTS_WORKSPACE_COMMANDS"); given != "" {
		candidates = append(candidates, given)
	}
	for _, folder := range filepath.SplitList(os.Getenv("PATH")) {
		if folder != "" {
			candidates = append(candidates, filepath.Join(folder, "workspace-commands"))
		}
	}
	for _, c := range candidates {
		if info, err := os.Stat(c); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return c
		}
	}
	return ""
}

// Check is ProviderConnection.check: whether the server is a provider (US2 AS2, AS6), the
// contract's tools or the map's, and a contract this control plane reads. It lists once,
// so the list comes back too.
func (c *Connection) Check() (Checked, error) {
	var tools []string
	if err := c.connected(func(client *mcpClient) (err error) {
		tools, err = client.toolNames()
		return err
	}); err != nil {
		return Checked{}, err
	}
	hasTool := func(name string) bool {
		for _, t := range tools {
			if t == name {
				return true
			}
		}
		return false
	}
	if c.mapping.Native {
		var missing []string
		for _, r := range RequiredTools {
			if !hasTool(r) {
				missing = append(missing, r)
			}
		}
		if len(missing) > 0 {
			return Checked{}, providerFailure("It isn’t a machine provider: it has no %s tool.", orList(missing))
		}
	} else if missing := c.mapping.Missing(tools); missing != "" {
		return Checked{}, providerFailure("The tool map names %s, which the server doesn’t have.", missing)
	}
	content, err := c.call(c.mapping.List, map[string]any{"id": ""}, c.timing.Quick)
	if err != nil {
		return Checked{}, err
	}
	contract := 1
	if c.mapping.Native {
		said, ok := integer(get(content, "contract"))
		if !ok {
			return Checked{}, providerFailure("Its workspaces_list doesn’t say which contract it follows.")
		}
		known := false
		var words []string
		for _, k := range Contracts {
			known = known || k == said
			words = append(words, fmt.Sprint(k))
		}
		if !known {
			return Checked{}, providerFailure("It follows contract %d; this control plane reads %s.", said, strings.Join(words, ", "))
		}
		contract = said
	} else if _, ok := arr(pathValue(c.mapping.Listing.Items, content)); !ok {
		keys := ""
		if o, ok := obj(content); ok {
			var names []string
			for k := range o {
				names = append(names, k)
			}
			sort.Strings(names)
			keys = " Its answer has the keys " + strings.Join(names, ", ") + "."
		}
		return Checked{}, providerFailure("The tool map’s list.items finds no list in what %s answered.%s", c.mapping.List.Tool, keys)
	}
	checked := Checked{Contract: contract, Workspaces: c.mapping.Workspaces(content), Items: -1}
	if c.mapping.Native {
		checked.Capabilities = []string{}
		for tool, capability := range optionalTools {
			if hasTool(tool) {
				checked.Capabilities = append(checked.Capabilities, capability)
			}
		}
		sort.Strings(checked.Capabilities)
	} else {
		checked.Capabilities = c.mapping.Capabilities()
		items, _ := arr(pathValue(c.mapping.Listing.Items, content))
		checked.Items = len(items)
		if len(items) > 0 {
			checked.FirstItem = items[0]
		}
	}
	return checked, nil
}

// Tools is every tool the server offers, as it described them (#858).
func (c *Connection) Tools() ([]any, error) {
	var tools []any
	err := c.connected(func(client *mcpClient) (err error) {
		tools, err = client.listTools()
		return err
	})
	return tools, err
}

func (c *Connection) List() ([]MachineInfo, error) {
	content, err := c.call(c.mapping.List, map[string]any{"id": ""}, c.timing.Quick)
	if err != nil {
		return nil, err
	}
	return c.mapping.Workspaces(content), nil
}

func (c *Connection) Start(id string) (*MachineInfo, error) { return c.act(c.mapping.Start, id) }
func (c *Connection) Stop(id string) (*MachineInfo, error)  { return c.act(c.mapping.Stop, id) }

func (c *Connection) Options() (any, error) {
	if c.mapping.Options == nil {
		return nil, providerFailure("It has no choices for a new machine.")
	}
	content, err := c.call(*c.mapping.Options, map[string]any{}, c.timing.Quick)
	if err != nil {
		return nil, err
	}
	if !c.mapping.Native {
		return content, nil
	}
	if schema := get(content, "schema"); schema != nil {
		return schema, nil
	}
	return map[string]any{}, nil
}

func (c *Connection) Create(name string, options any, firstBoot *string) (*MachineInfo, bool, error) {
	if c.mapping.Create == nil {
		return nil, false, providerFailure("It can’t make workspaces.")
	}
	values := map[string]any{"name": name, "options": options}
	if firstBoot != nil {
		values["firstBoot"] = *firstBoot
	}
	if o, ok := obj(options); ok {
		for k, v := range o {
			if _, taken := values[k]; !taken {
				values[k] = v
			}
		}
	}
	content, err := c.call(*c.mapping.Create, values, c.timing.Long)
	if err != nil {
		return nil, false, err
	}
	if !c.mapping.Native {
		return nil, c.mapping.FirstBootRuns, nil
	}
	runs, _ := boolean(get(content, "firstBootRuns"))
	if w := get(content, "workspace"); w != nil {
		return c.mapping.Workspace(w), runs, nil
	}
	return nil, runs, nil
}

func (c *Connection) Delete(id string) error {
	if c.mapping.Delete == nil {
		return providerFailure("It can’t delete workspaces.")
	}
	_, err := c.call(*c.mapping.Delete, map[string]any{"id": id}, c.timing.Long)
	return err
}

func (c *Connection) act(call Call, id string) (*MachineInfo, error) {
	content, err := c.call(call, map[string]any{"id": id}, c.timing.Long)
	if err != nil {
		return nil, err
	}
	if !c.mapping.Native {
		return nil, nil
	}
	if w := get(content, "workspace"); w != nil {
		return c.mapping.Workspace(w), nil
	}
	return nil, nil
}

// End ends the connection: the server it runs stops.
func (c *Connection) End() {
	c.mu.Lock()
	client := c.client
	c.client = nil
	c.mu.Unlock()
	if client != nil {
		client.end()
	}
}

func (c *Connection) call(call Call, values map[string]any, timeout time.Duration) (any, error) {
	arguments := c.mapping.Arguments(call, values)
	var result any
	if err := c.connected(func(client *mcpClient) (err error) {
		result, err = client.callTool(call.Tool, arguments, timeout)
		return err
	}); err != nil {
		return nil, err
	}
	return Content(result)
}

// connected runs work on a live connection: made when there is none, and made once more
// when the one there has gone (a stdio server that ended, an http session it forgot).
func (c *Connection) connected(work func(*mcpClient) error) error {
	for attempt := range 2 {
		client, err := c.live()
		if err != nil {
			return err
		}
		err = work(client)
		if err == nil {
			return nil
		}
		var failure *mcpFailure
		if !errors.As(err, &failure) {
			return &ProviderFailure{err.Error()}
		}
		// Only a connection that went is tried again: a call the server heard and refused,
		// or ran out of time on, could start a workspace twice.
		c.mu.Lock()
		same := c.client == client
		if attempt == 0 && failure.retriable() && same {
			c.client = nil
		}
		c.mu.Unlock()
		if attempt == 0 && failure.retriable() && same {
			client.end()
			continue
		}
		if failure.kind == "timeout" {
			return providerFailure("It didn’t answer in time.")
		}
		return &ProviderFailure{failure.Error()}
	}
	return providerFailure("It can’t be reached.")
}

// live is the connection's client, connected first when there is none.
func (c *Connection) live() (*mcpClient, error) {
	c.connecting.Lock()
	defer c.connecting.Unlock()
	c.mu.Lock()
	held := c.client
	c.mu.Unlock()
	if held != nil {
		return held, nil
	}
	client := newMCPClient(c.server, c.cwd, c.timing.Quick, c.log)
	if err := client.connect(); err != nil {
		client.end()
		return nil, &ProviderFailure{unreachable(err)}
	}
	c.mu.Lock()
	c.client = client
	c.mu.Unlock()
	return client, nil
}

// unreachable is ProviderConnection.unreachable.
func unreachable(err error) string {
	var failure *mcpFailure
	if errors.As(err, &failure) && failure.kind == "auth" {
		return "It wants a sign-in, which providers can’t do yet: give it a token as a secret."
	}
	return "It can’t be reached: " + err.Error()
}

// orList is ProviderConnection.list: "a", "a or b", "a, b or c".
func orList(names []string) string {
	switch len(names) {
	case 0:
		return ""
	case 1:
		return names[0]
	}
	return strings.Join(names[:len(names)-1], ", ") + " or " + names[len(names)-1]
}
