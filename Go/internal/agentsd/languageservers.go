package agentsd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Language servers for the file editor (#844): files/diagnostics asks the language server
// for a file's language what it finds in the file, as the editor holds it. A server is
// started for a folder and language on the first ask, kept for the next, and stopped once
// it has been idle for languageServerIdle; at most languageServersMax run at once.

const (
	languageServersMax = 4
	languageServerIdle = 10 * time.Minute
	languageServerWait = 5 * time.Second
	// languageServerStarting is how long a server that has said nothing yet is taken to be
	// starting (#1687): an empty list then is not "no problems".
	languageServerStarting = time.Minute
	diagnosticsMax         = 200
	diagnosticsTextLimit   = 1 << 20
)

// languageServerSpec is a language's server: its name for the person, the commands tried
// in order, and the LSP languageId by file extension.
type languageServerSpec struct {
	name     string
	commands [][]string
	ids      map[string]string
}

var languageServerSpecs = []languageServerSpec{
	{"gopls", [][]string{{"gopls"}}, map[string]string{".go": "go"}},
	{"sourcekit-lsp", [][]string{{"sourcekit-lsp"}, {"xcrun", "sourcekit-lsp"}}, map[string]string{".swift": "swift"}},
	{"typescript-language-server", [][]string{{"typescript-language-server", "--stdio"}},
		map[string]string{".ts": "typescript", ".tsx": "typescriptreact", ".js": "javascript", ".jsx": "javascriptreact", ".mjs": "javascript", ".cjs": "javascript"}},
	{"pyright", [][]string{{"pyright-langserver", "--stdio"}, {"pylsp"}}, map[string]string{".py": "python"}},
	{"rust-analyzer", [][]string{{"rust-analyzer"}}, map[string]string{".rs": "rust"}},
}

// languageServerFor is the spec and languageId for a file, or false for a language with none.
func languageServerFor(path string) (languageServerSpec, string, bool) {
	ext := strings.ToLower(filepath.Ext(path))
	for _, s := range languageServerSpecs {
		if id, ok := s.ids[ext]; ok {
			return s, id, true
		}
	}
	return languageServerSpec{}, "", false
}

// installedCommand is the first of a spec's commands found in the login shell's folders.
var installedCommand = func(s languageServerSpec) []string {
	for _, c := range s.commands {
		for _, dir := range searchPaths() {
			if info, err := os.Stat(filepath.Join(dir, c[0])); err == nil && !info.IsDir() {
				return append([]string{filepath.Join(dir, c[0])}, c[1:]...)
			}
		}
	}
	return nil
}

type languageServers struct {
	mu      sync.Mutex
	running map[string]*languageServer
	// starting holds the servers that are starting, by key. A start takes up to 20 s, so it
	// runs without mu: the servers that run already answer in the meantime (#1652).
	starting map[string]*serverStart
}

// serverStart is one server's start; done closes when it has started or failed.
type serverStart struct {
	done   chan struct{}
	server *languageServer
	err    error
}

var languageServerPool = &languageServers{running: map[string]*languageServer{}}

func (d *Daemon) registerLanguageServers() {
	On(d, wire.CallFilesDiagnostics, func(ctx context.Context, _ *Client, r wire.FileDiagnosticsRequest) (wire.FileDiagnostics, error) {
		path, err := d.scoped(r.AgentID, r.Path)
		if err != nil {
			return wire.FileDiagnostics{}, err
		}
		root := filepath.Dir(path)
		if a := d.Store.Agent(r.AgentID); a != nil {
			root = folderPath(a)
		}
		return languageServerPool.diagnose(root, path, r.Text), nil
	})
	On(d, wire.CallFilesComplete, func(ctx context.Context, _ *Client, r wire.FileCompletionRequest) (wire.FileCompletions, error) {
		path, err := d.scoped(r.AgentID, r.Path)
		if err != nil {
			return wire.FileCompletions{}, err
		}
		root := filepath.Dir(path)
		if a := d.Store.Agent(r.AgentID); a != nil {
			root = folderPath(a)
		}
		return languageServerPool.complete(ctx, root, path, r), nil
	})
}

const completionsMax = 50

func (p *languageServers) complete(ctx context.Context, root, path string, r wire.FileCompletionRequest) wire.FileCompletions {
	out := wire.FileCompletions{Items: []wire.FileCompletion{}}
	spec, languageID, ok := languageServerFor(path)
	if !ok {
		reason := "No language server for this kind of file."
		out.Reason = &reason
		return out
	}
	if len(r.Text) > diagnosticsTextLimit {
		reason := "The file is too big for its language server to read here."
		out.Reason = &reason
		return out
	}
	server, err := p.server(root, spec)
	if err != nil {
		reason := err.Error()
		out.Reason = &reason
		return out
	}
	items, err := server.complete(ctx, path, languageID, r.Text, int(r.Line), int(r.Column))
	if err != nil {
		reason := spec.name + ": " + err.Error()
		out.Reason = &reason
		return out
	}
	out.Items = items
	return out
}

func (p *languageServers) diagnose(root, path string, text *string) wire.FileDiagnostics {
	out := wire.FileDiagnostics{Diagnostics: []wire.FileDiagnostic{}}
	spec, languageID, ok := languageServerFor(path)
	if !ok {
		reason := "No language server for this kind of file."
		out.Reason = &reason
		return out
	}
	out.Server = &spec.name
	body := ""
	if text != nil {
		body = *text
	} else if b, err := os.ReadFile(path); err == nil {
		body = string(b)
	}
	if len(body) > diagnosticsTextLimit {
		reason := "The file is too big for its language server to read here."
		out.Reason = &reason
		return out
	}
	server, err := p.server(root, spec)
	if err != nil {
		reason := err.Error()
		out.Reason = &reason
		return out
	}
	found, err := server.diagnose(path, languageID, body)
	if errors.Is(err, errStarting) {
		reason := "Starting " + spec.name + "…"
		out.Reason = &reason
		return out
	}
	if err != nil {
		p.drop(server)
		reason := spec.name + " stopped: " + err.Error()
		out.Reason = &reason
		return out
	}
	out.Diagnostics = found
	return out
}

// server is the running server for a folder and language, started when there is none. A
// second ask while it starts waits for that start; asks for other servers do not wait.
func (p *languageServers) server(root string, spec languageServerSpec) (*languageServer, error) {
	key := root + "\x00" + spec.name
	p.mu.Lock()
	if s, ok := p.running[key]; ok && s.alive() {
		p.mu.Unlock()
		s.touch()
		return s, nil
	}
	if start, ok := p.starting[key]; ok {
		p.mu.Unlock()
		<-start.done
		return start.server, start.err
	}
	command := installedCommand(spec)
	if command == nil {
		p.mu.Unlock()
		return nil, fmt.Errorf("%s is not installed on this machine, so this file is not checked.", spec.name)
	}
	if p.starting == nil {
		p.starting = map[string]*serverStart{}
	}
	start := &serverStart{done: make(chan struct{})}
	p.starting[key] = start
	p.makeRoom()
	p.mu.Unlock()

	s, err := startLanguageServer(root, command)

	p.mu.Lock()
	defer p.mu.Unlock()
	defer close(start.done)
	if err != nil {
		delete(p.starting, key)
		start.err = fmt.Errorf("%s did not start: %v", spec.name, err)
		return nil, start.err
	}
	s.key = key
	p.makeRoom() // the start still counts, so the room is for it
	delete(p.starting, key)
	p.running[key] = s
	start.server = s
	go p.reapWhenIdle(s)
	return s, nil
}

// makeRoom stops the server used longest ago while the running and starting ones are at
// least languageServersMax. p.mu is held.
func (p *languageServers) makeRoom() {
	for len(p.running) > 0 && len(p.running)+len(p.starting) > languageServersMax {
		oldest := ""
		for k, s := range p.running {
			if oldest == "" || s.used().Before(p.running[oldest].used()) {
				oldest = k
			}
		}
		p.running[oldest].stop()
		delete(p.running, oldest)
	}
}

// stopAll stops every server: for a test, and a host going away.
func (p *languageServers) stopAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for key, s := range p.running {
		s.stop()
		delete(p.running, key)
	}
}

// count is how many servers run.
func (p *languageServers) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.running)
}

func (p *languageServers) drop(s *languageServer) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.running[s.key] == s {
		delete(p.running, s.key)
	}
	s.stop()
}

func (p *languageServers) reapWhenIdle(s *languageServer) {
	for {
		select {
		case <-s.dead:
			p.drop(s)
			return
		case <-time.After(time.Minute):
			if time.Since(s.used()) > languageServerIdle {
				p.drop(s)
				return
			}
		}
	}
}

// languageServer is one running server and the client's end of it.
type languageServer struct {
	key      string
	cmd      *exec.Cmd
	in       io.WriteCloser
	writeMu  sync.Mutex
	mu       sync.Mutex
	nextID   int64
	pending  map[int64]chan json.RawMessage
	diags    map[string][]wire.FileDiagnostic
	notify   map[string]chan struct{}
	versions map[string]int
	lastUsed time.Time
	dead     chan struct{}
	// started is when it was started, and answered whether it has published anything since
	// (#1687): until then, an empty list says it is starting.
	started  time.Time
	answered bool
}

// errStarting is a diagnose that gave up before the server's first answer (#1687).
var errStarting = errors.New("starting")

func startLanguageServer(root string, command []string) (*languageServer, error) {
	cmd := exec.Command(command[0], command[1:]...)
	cmd.Dir = root
	cmd.Env = loginEnvironment()
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	outPipe, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	s := &languageServer{cmd: cmd, in: in, pending: map[int64]chan json.RawMessage{},
		diags: map[string][]wire.FileDiagnostic{}, notify: map[string]chan struct{}{}, versions: map[string]int{},
		lastUsed: time.Now(), dead: make(chan struct{}), started: time.Now()}
	go s.read(bufio.NewReader(outPipe))
	go func() { _ = cmd.Wait(); s.markDead() }()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	init := map[string]any{
		"processId": os.Getpid(), "rootUri": fileURI(root),
		"workspaceFolders": []map[string]any{{"uri": fileURI(root), "name": filepath.Base(root)}},
		"capabilities": map[string]any{"textDocument": map[string]any{
			"publishDiagnostics": map[string]any{"relatedInformation": false},
			"synchronization":    map[string]any{"didSave": false}}},
	}
	if _, err := s.request(ctx, "initialize", init); err != nil {
		s.stop()
		return nil, err
	}
	if err := s.send(map[string]any{"jsonrpc": "2.0", "method": "initialized", "params": map[string]any{}}); err != nil {
		s.stop()
		return nil, err
	}
	return s, nil
}

func (s *languageServer) alive() bool {
	select {
	case <-s.dead:
		return false
	default:
		return true
	}
}

func (s *languageServer) markDead() {
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.dead:
	default:
		close(s.dead)
	}
}

func (s *languageServer) touch() { s.mu.Lock(); s.lastUsed = time.Now(); s.mu.Unlock() }
func (s *languageServer) used() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastUsed
}

func (s *languageServer) stop() {
	_ = s.in.Close()
	if s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
	}
	s.markDead()
}

// diagnose opens the file, or says its new text, and waits for what the server publishes.
func (s *languageServer) diagnose(path, languageID, text string) ([]wire.FileDiagnostic, error) {
	s.touch()
	uri := fileURI(path)
	published := make(chan struct{})
	s.mu.Lock()
	s.notify[uri] = published
	s.mu.Unlock()
	if err := s.sync(uri, languageID, text); err != nil {
		return nil, err
	}
	select {
	case <-published:
	case <-s.dead:
		return nil, fmt.Errorf("it ended")
	case <-time.After(languageServerWait):
		// Nothing new in time: what it said last, which may be of the text before.
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.answered && time.Since(s.started) < languageServerStarting {
		return nil, errStarting
	}
	return append([]wire.FileDiagnostic{}, s.diags[uri]...), nil
}

// sync says the editor's text to the server, opening the document the first time.
func (s *languageServer) sync(uri, languageID, text string) error {
	s.mu.Lock()
	version := s.versions[uri] + 1
	s.versions[uri] = version
	s.mu.Unlock()
	if version == 1 {
		return s.send(map[string]any{"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": map[string]any{
			"textDocument": map[string]any{"uri": uri, "languageId": languageID, "version": version, "text": text}}})
	}
	return s.send(map[string]any{"jsonrpc": "2.0", "method": "textDocument/didChange", "params": map[string]any{
		"textDocument":   map[string]any{"uri": uri, "version": version},
		"contentChanges": []map[string]any{{"text": text}}}})
}

// complete is what the server would write at line and column (from 1, UTF-16 as LSP counts).
func (s *languageServer) complete(ctx context.Context, path, languageID, text string, line, column int) ([]wire.FileCompletion, error) {
	s.touch()
	uri := fileURI(path)
	if err := s.sync(uri, languageID, text); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, languageServerWait)
	defer cancel()
	raw, err := s.request(ctx, "textDocument/completion", map[string]any{
		"textDocument": map[string]any{"uri": uri},
		"position":     map[string]any{"line": max(0, line-1), "character": max(0, column-1)},
	})
	if err != nil {
		return nil, err
	}
	return completionItems(raw), nil
}

// completionItems reads a completion answer: a list, or {isIncomplete, items}.
func completionItems(raw json.RawMessage) []wire.FileCompletion {
	type item struct {
		Label      string `json:"label"`
		InsertText string `json:"insertText"`
		Detail     string `json:"detail"`
		TextEdit   *struct {
			NewText string `json:"newText"`
		} `json:"textEdit"`
	}
	var items []item
	if json.Unmarshal(raw, &items) != nil {
		var list struct {
			Items []item `json:"items"`
		}
		_ = json.Unmarshal(raw, &list)
		items = list.Items
	}
	out := []wire.FileCompletion{}
	for _, it := range items {
		if it.Label == "" {
			continue
		}
		c := wire.FileCompletion{Label: it.Label}
		insert := it.InsertText
		if it.TextEdit != nil && it.TextEdit.NewText != "" {
			insert = it.TextEdit.NewText
		}
		// Snippet placeholders ($1, ${2:name}) are not typed: what is before the first goes in.
		if at := strings.IndexAny(insert, "$"); at >= 0 {
			insert = insert[:at]
		}
		// A call goes in as far as its "(": the arguments are the person's to write.
		if at := strings.Index(insert, "("); at >= 0 {
			insert = insert[:at+1]
		}
		if insert != "" && insert != it.Label {
			c.Insert = &insert
		}
		if it.Detail != "" {
			detail := it.Detail
			c.Detail = &detail
		}
		out = append(out, c)
		if len(out) == completionsMax {
			break
		}
	}
	return out
}

func (s *languageServer) request(ctx context.Context, method string, params any) (json.RawMessage, error) {
	s.mu.Lock()
	s.nextID++
	id := s.nextID
	reply := make(chan json.RawMessage, 1)
	s.pending[id] = reply
	s.mu.Unlock()
	if err := s.send(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}); err != nil {
		return nil, err
	}
	select {
	case r := <-reply:
		return r, nil
	case <-s.dead:
		return nil, fmt.Errorf("it ended")
	case <-ctx.Done():
		return nil, fmt.Errorf("%s took too long", method)
	}
}

// send writes one message, framed as LSP frames them.
func (s *languageServer) send(message any) error {
	b, err := json.Marshal(message)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err = fmt.Fprintf(s.in, "Content-Length: %d\r\n\r\n%s", len(b), b)
	return err
}

// read takes each message the server sends: replies, the problems it publishes, and the
// requests it makes of a client, each answered with nothing.
func (s *languageServer) read(r *bufio.Reader) {
	defer s.markDead()
	for {
		body, err := readFrame(r)
		if err != nil {
			return
		}
		var m struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(body, &m) != nil {
			continue
		}
		switch {
		case m.Method == "textDocument/publishDiagnostics":
			s.published(m.Params)
		case m.Method != "" && len(m.ID) > 0:
			// A request of the client's (configuration, progress, registration): an empty
			// answer of the shape it wants.
			var result any
			if m.Method == "workspace/configuration" {
				var p struct {
					Items []any `json:"items"`
				}
				_ = json.Unmarshal(m.Params, &p)
				result = make([]any, len(p.Items))
			}
			_ = s.send(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": result})
		case m.Method == "" && len(m.ID) > 0:
			id, err := strconv.ParseInt(string(m.ID), 10, 64)
			if err != nil {
				continue
			}
			s.mu.Lock()
			reply := s.pending[id]
			delete(s.pending, id)
			s.mu.Unlock()
			if reply != nil {
				reply <- m.Result
			}
		}
	}
}

func (s *languageServer) published(params json.RawMessage) {
	var p struct {
		URI         string `json:"uri"`
		Diagnostics []struct {
			Range struct {
				Start struct {
					Line      int `json:"line"`
					Character int `json:"character"`
				} `json:"start"`
			} `json:"range"`
			Severity int    `json:"severity"`
			Message  string `json:"message"`
			Source   string `json:"source"`
		} `json:"diagnostics"`
	}
	if json.Unmarshal(params, &p) != nil {
		return
	}
	found := []wire.FileDiagnostic{}
	for _, d := range p.Diagnostics {
		f := wire.FileDiagnostic{Line: int64(d.Range.Start.Line + 1), Column: int64(d.Range.Start.Character + 1),
			Severity: severityName(d.Severity), Message: strings.TrimSpace(d.Message)}
		if d.Source != "" {
			source := d.Source
			f.Source = &source
		}
		found = append(found, f)
	}
	sort.SliceStable(found, func(i, j int) bool {
		if found[i].Line != found[j].Line {
			return found[i].Line < found[j].Line
		}
		return found[i].Column < found[j].Column
	})
	if len(found) > diagnosticsMax {
		found = found[:diagnosticsMax]
	}
	uri := normalURI(p.URI)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.answered = true
	s.diags[uri] = found
	if c, ok := s.notify[uri]; ok {
		close(c)
		delete(s.notify, uri)
	}
}

func severityName(n int) string {
	switch n {
	case 1:
		return "error"
	case 2:
		return "warning"
	case 4:
		return "hint"
	}
	return "info"
}

// readFrame is one LSP message's body: headers to a blank line, then Content-Length bytes.
func readFrame(r *bufio.Reader) ([]byte, error) {
	length := -1
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		if name, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(strings.TrimSpace(name), "Content-Length") {
			length, _ = strconv.Atoi(strings.TrimSpace(value))
		}
	}
	if length < 0 {
		return nil, fmt.Errorf("a message with no length")
	}
	body := make([]byte, length)
	_, err := io.ReadFull(r, body)
	return body, err
}

func fileURI(path string) string {
	return (&url.URL{Scheme: "file", Path: path}).String()
}

// normalURI is a server's URI as fileURI writes it: servers differ in what they escape.
func normalURI(uri string) string {
	if u, err := url.Parse(uri); err == nil && u.Scheme == "file" {
		return fileURI(u.Path)
	}
	return uri
}
