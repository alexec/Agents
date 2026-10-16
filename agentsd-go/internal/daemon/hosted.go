package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// hostedServers is "hosted": true stdio entries (#488, HostedMCPServers.swift): one process
// per entry, shared by every session, started on the first request. Both ends are
// modelcontextprotocol/go-sdk: a Client speaks to the stdio process, and a Server offers its
// tools to sessions at /mcp/hosted/<route> on the app tools port, with the session's bearer.
type hostedServers struct {
	d       *Daemon
	mu      sync.Mutex
	entries map[string]*hostedEntry // route → entry
	handler http.Handler
}

type hostedEntry struct {
	Name    string
	Scope   string // a project folder, or "personal"
	Command string
	Args    []string
	Env     map[string]string
	route   string

	mu      sync.Mutex
	session *mcp.ClientSession
	server  *mcp.Server
	state   string
	since   Date
	err     string
}

type mcpFile struct {
	MCPServers map[string]struct {
		Command string            `json:"command"`
		Args    []string          `json:"args"`
		Env     map[string]string `json:"env"`
		Hosted  bool              `json:"hosted"`
	} `json:"mcpServers"`
}

func (d *Daemon) hostedFor() *hostedServers {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.hosted == nil {
		h := &hostedServers{d: d, entries: map[string]*hostedEntry{}}
		h.handler = mcp.NewStreamableHTTPHandler(func(r *http.Request) *mcp.Server {
			return h.serverFor(r)
		}, &mcp.StreamableHTTPOptions{JSONResponse: true})
		d.hosted = h
	}
	return d.hosted
}

// scan reads ~/.agents/mcp.json and every project's .agents/mcp.json for hosted entries.
// A project's entries need no approval in this spike (the Swift host approves by digest).
func (h *hostedServers) scan() {
	home, _ := os.UserHomeDir()
	files := map[string]string{"personal": filepath.Join(home, ".agents", "mcp.json")}
	for _, p := range h.d.store.Projects() {
		files[folderPath(p.Folder)] = filepath.Join(folderPath(p.Folder), ".agents", "mcp.json")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for scope, file := range files {
		b, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		var f mcpFile
		if err := json.Unmarshal(b, &f); err != nil {
			log.Printf("hosted: %s: %v", file, err)
			continue
		}
		for name, e := range f.MCPServers {
			if !e.Hosted || e.Command == "" {
				continue
			}
			sum := sha256.Sum256([]byte(scope + "\x00" + name + "\x00" + e.Command + "\x00" + strings.Join(e.Args, "\x00")))
			route := hex.EncodeToString(sum[:16])
			if h.entries[route] == nil {
				h.entries[route] = &hostedEntry{Name: name, Scope: scope, Command: e.Command, Args: e.Args, Env: e.Env, route: route, state: "idle"}
				log.Printf("hosted: %s (%s) at /mcp/hosted/%s", name, scope, route)
			}
		}
	}
}

// routes are the entries a session in folder is given: the personal ones and its project's.
func (h *hostedServers) routesFor(folder string) []*hostedEntry {
	h.scan()
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []*hostedEntry
	for _, e := range h.entries {
		if e.Scope == "personal" || e.Scope == folder {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (h *hostedServers) routes() []string { return nil }

func (h *hostedServers) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		w.Header().Set("Allow", "POST, DELETE")
		http.Error(w, "", http.StatusMethodNotAllowed)
		return
	}
	h.handler.ServeHTTP(w, r)
}

func (h *hostedServers) serverFor(r *http.Request) *mcp.Server {
	route := strings.TrimPrefix(r.URL.Path, "/mcp/hosted/")
	h.mu.Lock()
	e := h.entries[route]
	h.mu.Unlock()
	if e == nil {
		return nil
	}
	s, err := e.start(h.d)
	if err != nil {
		log.Printf("hosted: %s: %v", e.Name, err)
		return nil
	}
	return s
}

// start runs the process once and makes the server sessions see, with its tools.
func (e *hostedEntry) start(d *Daemon) (*mcp.Server, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.server != nil {
		return e.server, nil
	}
	e.state = "starting"
	cmd := exec.Command("/usr/bin/env", append([]string{e.Command}, e.Args...)...)
	cmd.Dir = e.Scope
	if e.Scope == "personal" {
		cmd.Dir, _ = os.UserHomeDir()
	}
	cmd.Env = os.Environ()
	for k, v := range e.Env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "Agents", Version: "1"}, nil)
	ctx, cancel := context.WithTimeout(d.ctx, 60*time.Second)
	defer cancel()
	cs, err := client.Connect(d.ctx, &mcp.CommandTransport{Command: cmd}, nil)
	if err != nil {
		e.state, e.err = "restarting", err.Error()
		return nil, err
	}
	tools, err := cs.ListTools(ctx, nil)
	if err != nil {
		cs.Close()
		e.state, e.err = "restarting", err.Error()
		return nil, err
	}
	server := mcp.NewServer(&mcp.Implementation{Name: e.Name, Version: "hosted"}, nil)
	for _, t := range tools.Tools {
		name := t.Name
		server.AddTool(t, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			var args any
			if len(req.Params.Arguments) > 0 {
				json.Unmarshal(req.Params.Arguments, &args)
			}
			return cs.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
		})
	}
	e.session, e.server, e.state, e.since = cs, server, "running", Now()
	log.Printf("hosted: %s running, %d tools, pid %d", e.Name, len(tools.Tools), cmd.Process.Pid)
	return server, nil
}

func (h *hostedServers) snapshot() map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()
	servers := []map[string]any{}
	for _, e := range h.entries {
		e.mu.Lock()
		s := map[string]any{"name": e.Name, "state": e.state, "restarts": 0, "users": 0}
		if e.Scope != "personal" {
			s["project"] = e.Scope
		}
		if e.state == "running" {
			s["since"] = e.since
		}
		if e.err != "" {
			s["lastError"] = e.err
		}
		e.mu.Unlock()
		servers = append(servers, s)
	}
	return map[string]any{"servers": servers, "at": Now()}
}

func (d *Daemon) registerHosted() {
	d.Handle("mcp/hosted", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		h := d.hostedFor()
		h.scan()
		return h.snapshot(), nil
	})
	d.Handle("mcp/health", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		h := d.hostedFor()
		h.scan()
		servers := []map[string]any{}
		for _, s := range h.snapshot()["servers"].([]map[string]any) {
			row := map[string]any{"name": s["name"], "transport": "stdio", "hosted": true, "check": "unchecked", "live": s}
			if p, ok := s["project"]; ok {
				row["project"] = p
			}
			servers = append(servers, row)
		}
		return map[string]any{"servers": servers, "problems": []any{}, "at": Now()}, nil
	})
}

var _ = fmt.Sprintf
