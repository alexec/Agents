package agentsd

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The person's and the folder's MCP servers, as SessionServers hands them to a session on
// the Swift host: <home>/.agents/mcp.json and <folder>/.agents/mcp.json, read afresh each
// session; ${NAME} filled from <home>/.agents-secrets/secrets.env, a server still missing
// one left out; a folder's server only once the person approved it as it stands
// (<root>/mcp-approvals.json), every entry there at the first start approved. The app's
// own server goes first, then the folder's, then the person's; the first of a name wins.

type mcpEntry struct {
	name   string
	server sdk.McpServer
	raw    json.RawMessage
	kind   wire.MCPTransportName
	hosted bool
}

type mcpBook struct {
	mcpMu        sync.Mutex
	mcpApprovals map[string]json.RawMessage // the file, kept whole
	mcpLoaded    bool
}

// personalHome is StoreLocations.personalHome: AGENTS_PERSONAL_HOME, or the person's
// home on a server.
func (d *Daemon) personalHome() string {
	if h := os.Getenv("AGENTS_PERSONAL_HOME"); h != "" {
		return h
	}
	return d.PersonalHome
}

// orderedKeys is the keys of a JSON object in the file's own order.
func orderedKeys(raw json.RawMessage) []string {
	dec := json.NewDecoder(bytes.NewReader(raw))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return nil
	}
	var keys []string
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			return keys
		}
		k, _ := t.(string)
		keys = append(keys, k)
		var skip json.RawMessage
		if dec.Decode(&skip) != nil {
			return keys
		}
	}
	return keys
}

// readMCPFile is PersonalDotAgents.parseServers: every server, or the file's problem.
func readMCPFile(path string) ([]mcpEntry, string) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) || err == nil && strings.TrimSpace(string(b)) == "" {
		return nil, ""
	}
	if err != nil || !json.Valid(b) {
		return nil, "mcp.json is not valid JSON."
	}
	var top map[string]json.RawMessage
	if json.Unmarshal(b, &top) != nil {
		return nil, "mcp.json should hold one object, with the servers under \"mcpServers\"."
	}
	servers, ok := top["mcpServers"]
	if !ok {
		return nil, ""
	}
	var each map[string]json.RawMessage
	if json.Unmarshal(servers, &each) != nil {
		return nil, "mcp.json should hold one object, with the servers under \"mcpServers\"."
	}
	var out []mcpEntry
	for _, name := range orderedKeys(servers) {
		raw := each[name]
		var e struct {
			Command *string           `json:"command"`
			Args    []string          `json:"args"`
			Env     map[string]string `json:"env"`
			URL     *string           `json:"url"`
			Headers map[string]string `json:"headers"`
			Type    *string           `json:"type"`
			Hosted  *bool             `json:"hosted"`
		}
		if json.Unmarshal(raw, &e) != nil {
			return nil, "The server “" + name + "” is not written as a server."
		}
		entry := mcpEntry{name: name, raw: raw, hosted: e.Hosted != nil && *e.Hosted}
		switch {
		case e.Command != nil:
			var env []sdk.EnvVariable
			keys := make([]string, 0, len(e.Env))
			for k := range e.Env {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				env = append(env, sdk.EnvVariable{Name: k, Value: e.Env[k]})
			}
			if env == nil {
				env = []sdk.EnvVariable{}
			}
			args := e.Args
			if args == nil {
				args = []string{}
			}
			entry.server = sdk.McpServer{Stdio: &sdk.McpServerStdio{Name: name, Command: *e.Command, Args: args, Env: env}}
			entry.kind = wire.MCPTransportNameStdio
		case e.Hosted != nil && *e.Hosted:
			return nil, "The server “" + name + "” is hosted but has no command: only a local server can be hosted."
		case e.URL != nil:
			var headers []sdk.HttpHeader
			keys := make([]string, 0, len(e.Headers))
			for k := range e.Headers {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				headers = append(headers, sdk.HttpHeader{Name: k, Value: e.Headers[k]})
			}
			if headers == nil {
				headers = []sdk.HttpHeader{}
			}
			kind := "http"
			if e.Type != nil {
				kind = *e.Type
			}
			switch kind {
			case "http", "streamable-http", "streamableHttp":
				entry.server = sdk.McpServer{Http: &sdk.McpServerHttpInline{Name: name, Type: "http", Url: *e.URL, Headers: headers}}
				entry.kind = wire.MCPTransportNameHttp
			case "sse":
				entry.server = sdk.McpServer{Sse: &sdk.McpServerSseInline{Name: name, Type: "sse", Url: *e.URL, Headers: headers}}
				entry.kind = wire.MCPTransportNameSse
			default:
				return nil, "The server “" + name + "” has a type that is not http or sse."
			}
		default:
			return nil, "The server “" + name + "” has neither a command nor a url."
		}
		out = append(out, entry)
	}
	return out, ""
}

// secrets is secrets.env: NAME=value lines.
func (d *Daemon) secrets() map[string]string {
	out := map[string]string{}
	home := d.personalHome()
	if home == "" {
		return out
	}
	b, err := os.ReadFile(filepath.Join(home, ".agents-secrets", "secrets.env"))
	if err != nil {
		return out
	}
	name := regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok && name.MatchString(k) {
			out[k] = v
		}
	}
	return out
}

var secretRef = regexp.MustCompile(`\$\{([^}]*)\}`)

// fill is SecretsEnv.filled: every ${NAME} filled, or the names missing.
func fill(text string, secrets map[string]string, missing *[]string) string {
	return secretRef.ReplaceAllStringFunc(text, func(m string) string {
		n := m[2 : len(m)-1]
		if v, ok := secrets[n]; ok {
			return v
		}
		*missing = append(*missing, n)
		return m
	})
}

func filledServer(s sdk.McpServer, secrets map[string]string) (sdk.McpServer, []string) {
	var missing []string
	switch {
	case s.Stdio != nil:
		c := *s.Stdio
		c.Command = fill(c.Command, secrets, &missing)
		args := make([]string, len(c.Args))
		for i, a := range c.Args {
			args[i] = fill(a, secrets, &missing)
		}
		c.Args = args
		env := make([]sdk.EnvVariable, len(c.Env))
		for i, e := range c.Env {
			env[i] = sdk.EnvVariable{Name: e.Name, Value: fill(e.Value, secrets, &missing)}
		}
		c.Env = env
		return sdk.McpServer{Stdio: &c}, missing
	case s.Http != nil:
		h := *s.Http
		h.Url = fill(h.Url, secrets, &missing)
		hs := make([]sdk.HttpHeader, len(h.Headers))
		for i, x := range h.Headers {
			hs[i] = sdk.HttpHeader{Name: x.Name, Value: fill(x.Value, secrets, &missing)}
		}
		h.Headers = hs
		return sdk.McpServer{Http: &h}, missing
	case s.Sse != nil:
		h := *s.Sse
		h.Url = fill(h.Url, secrets, &missing)
		hs := make([]sdk.HttpHeader, len(h.Headers))
		for i, x := range h.Headers {
			hs[i] = sdk.HttpHeader{Name: x.Name, Value: fill(x.Value, secrets, &missing)}
		}
		h.Headers = hs
		return sdk.McpServer{Sse: &h}, missing
	}
	return s, nil
}

// canonicalEntry is OrderedJSON.canonicalJSON: keys sorted, nothing between.
func canonicalEntry(raw json.RawMessage) string {
	var v any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if dec.Decode(&v) != nil {
		return string(raw)
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.Encode(v)
	return strings.TrimSuffix(buf.String(), "\n")
}

func entryDigest(raw json.RawMessage) string {
	sum := sha256.Sum256([]byte(canonicalEntry(raw)))
	return hex.EncodeToString(sum[:])
}

// approvalFolder is the folder a folder's approvals are kept under: a worktree's folder.
func approvalFolder(folder string) string {
	if i := strings.Index(folder, "/.agents/worktrees/"); i >= 0 {
		return folder[:i]
	}
	return folder
}

func mcpApprovalKey(folder, name string) string {
	return approvalFolder(folder) + "|.agents/mcp.json|" + name
}

func (d *Daemon) mcpApprovalsPath() string {
	return filepath.Join(d.Store.Loc.Root, "mcp-approvals.json")
}

// mcpApprovalsLocked is mcp-approvals.json, begun once: every folder entry there at the
// first start is approved as it stands.
func (d *Daemon) mcpApprovalsLocked() (approved map[string]string, begun, unreadable bool) {
	if !d.mcpLoaded {
		d.mcpLoaded = true
		d.mcpApprovals = map[string]json.RawMessage{}
		if b, err := os.ReadFile(d.mcpApprovalsPath()); err == nil {
			if json.Unmarshal(b, &d.mcpApprovals) != nil {
				d.mcpApprovals = nil
			}
		}
		if d.mcpApprovals != nil {
			if _, ok := d.mcpApprovals["approvalsBegan"]; !ok {
				all := map[string]string{}
				for _, p := range d.folders(false) {
					folder := store.FolderPath(p.Folder.Folder)
					entries, _ := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
					for _, e := range entries {
						all[mcpApprovalKey(folder, e.name)] = entryDigest(e.raw)
					}
				}
				b, _ := json.Marshal(all)
				d.mcpApprovals["approved"] = b
				began, _ := json.Marshal(now())
				d.mcpApprovals["approvalsBegan"] = began
				if out, err := json.Marshal(d.mcpApprovals); err == nil {
					store.WriteAtomically(d.mcpApprovalsPath(), out, 0o644)
				}
			}
		}
	}
	if d.mcpApprovals == nil {
		return nil, true, true
	}
	approved = map[string]string{}
	json.Unmarshal(d.mcpApprovals["approved"], &approved)
	return approved, true, false
}

// folderServers is folderContribution: approved entries, with secrets filled; the names
// waiting and those missing a secret.
func (d *Daemon) folderMCP(folder string, secrets map[string]string) (servers []mcpEntry, waiting, missing []string, problem string) {
	entries, problem := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
	d.mcpMu.Lock()
	approved, _, _ := d.mcpApprovalsLocked()
	d.mcpMu.Unlock()
	for _, e := range entries {
		if approved == nil || approved[mcpApprovalKey(folder, e.name)] != entryDigest(e.raw) {
			waiting = append(waiting, e.name)
			continue
		}
		s, gone := filledServer(e.server, secrets)
		if len(gone) > 0 {
			missing = append(missing, e.name)
			log.Printf("session servers: %s left out: missing secret %s", e.name, strings.Join(gone, ", "))
			continue
		}
		e.server = s
		servers = append(servers, e)
	}
	return
}

func (d *Daemon) personalMCP(secrets map[string]string) (servers []mcpEntry, missing []string, problem string) {
	home := d.personalHome()
	if home == "" {
		return nil, nil, ""
	}
	entries, problem := readMCPFile(filepath.Join(home, ".agents", "mcp.json"))
	for _, e := range entries {
		s, gone := filledServer(e.server, secrets)
		if len(gone) > 0 {
			missing = append(missing, e.name)
			log.Printf("session servers: %s left out: missing secret %s", e.name, strings.Join(gone, ", "))
			continue
		}
		e.server = s
		servers = append(servers, e)
	}
	return
}

// sessionEntry is one server a session is given, with where its file is: folder is nil
// for the person's own.
type sessionEntry struct {
	mcpEntry
	folder *string
	cwd    string
}

// sessionMCP is the person's and the folder's servers a session is given, after the app's.
func (d *Daemon) sessionMCP(folder string) []sdk.McpServer {
	entries := d.sessionEntries(folder)
	out := make([]sdk.McpServer, 0, len(entries))
	for _, e := range entries {
		out = append(out, e.server)
	}
	return out
}

// sessionEntries is sessionMCP's servers, signed in, with the file each came from.
func (d *Daemon) sessionEntries(folder string) []sessionEntry {
	secrets := d.secrets()
	folderEntries, _, _, _ := d.folderMCP(folder, secrets)
	personal, _, _ := d.personalMCP(secrets)
	var out []sessionEntry
	seen := map[string]bool{appServerName: true}
	f := folder
	for i, e := range append(folderEntries, personal...) {
		if seen[e.name] {
			continue
		}
		seen[e.name] = true
		if i < len(folderEntries) {
			out = append(out, sessionEntry{mcpEntry: e, folder: &f, cwd: folder})
		} else {
			out = append(out, sessionEntry{mcpEntry: e, cwd: d.personalHome()})
		}
	}
	// A server that needs a sign-in is left out; the others keep their place.
	kept := out[:0]
	for _, e := range out {
		signed := d.withSignIns([]sdk.McpServer{e.server})
		if len(signed) == 0 {
			continue
		}
		e.server = signed[0]
		kept = append(kept, e)
	}
	return kept
}

// beginMCPApprovals is beginMCPApprovalsIfNeeded, at start-up.
func (d *Daemon) beginMCPApprovals() {
	d.mcpMu.Lock()
	d.mcpApprovalsLocked()
	d.mcpMu.Unlock()
}
