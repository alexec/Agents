// Package acp starts an agent runtime and speaks ACP to it with coder/acp-go-sdk.
package acp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/safe"
)

// Sink is what the daemon hears from a session.
type Sink interface {
	Update(n sdk.SessionNotification)
	// Permission blocks until the person answers, and returns the option chosen, or "" for cancelled.
	Permission(ctx context.Context, req sdk.RequestPermissionRequest) string
	// Served is a file read or write, or a terminal, the client did for the runtime.
	Served(kind, detail string)
	// Elicitation blocks until the person answers a form (elicitation/create), and returns
	// the action, accept, decline or cancel, with the content of an accept. params is the
	// request as the runtime sent it.
	Elicitation(ctx context.Context, params json.RawMessage) (action string, content map[string]any)
	// ElicitationComplete is the runtime taking a form down (elicitation/complete).
	ElicitationComplete(elicitationID string)
}

// Launch is how one runtime starts.
type Launch struct {
	Command string
	Args    []string
	Env     []string
	Dir     string
	// Wrap, when set, rewrites the argv (a sandbox).
	Wrap func(argv []string) []string
	// Name is the runtime as the person knows it ("Claude"), for errors; "" is the
	// command's own name.
	Name string
}

// ErrNoAnswer is a runtime that did not answer initialize in handshakeWait (#1440).
var ErrNoAnswer = errors.New("did not answer")

// handshakeWait is how long a runtime has to answer initialize.
var handshakeWait = 60 * time.Second

// Session is one runtime process and its one ACP session.
type Session struct {
	cmd       *exec.Cmd
	conn      *sdk.ClientSideConnection
	ID        sdk.SessionId
	Init      sdk.InitializeResponse
	NewResult sdk.NewSessionResponse
	client    *client
	stderr    *tail
	done      chan struct{}
	// Continued is whether Start picked the runtime's own conversation back up; Lost is
	// whether it had one to continue and the runtime no longer had it.
	Continued, Lost bool
}

// Handshake launches the runtime and says initialize, and goes no further: for asking a
// runtime something without starting an agent (DaemonCore.handshakeOnly). A runtime that
// did not answer and wrote nothing, as npx does while the npm registry is slow, is
// launched once more (#1440).
func Handshake(ctx context.Context, l Launch, sink Sink) (*Session, error) {
	s, silent, err := handshake(ctx, l, sink)
	if silent && ctx.Err() == nil {
		log.Printf("%s did not answer initialize and wrote nothing: starting it once more", l.Command)
		s, _, err = handshake(ctx, l, sink)
	}
	return s, err
}

// handshake is one launch and initialize; silent is a runtime that did not answer in
// handshakeWait and wrote nothing to stderr.
func handshake(ctx context.Context, l Launch, sink Sink) (_ *Session, silent bool, _ error) {
	argv := append([]string{l.Command}, l.Args...)
	if l.Wrap != nil {
		argv = l.Wrap(argv)
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = l.Dir
	cmd.Env = l.Env
	// Its own process group, so npx's node child goes with it.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, false, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, false, err
	}
	stderr := &tail{}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return nil, false, fmt.Errorf("start %s: %w", l.Command, err)
	}
	s := &Session{cmd: cmd, stderr: stderr, done: make(chan struct{})}
	s.client = &client{sink: sink, dir: l.Dir, env: l.Env, runtime: l.Name, terminals: map[string]*terminal{}}
	s.conn = sdk.NewClientSideConnection(s.client, &sessionPromptWriter{w: stdin, c: s.client}, &rawElicitations{r: bufio.NewReader(stdout), c: s.client})
	safe.Go("runtime wait", func() { _ = cmd.Wait(); close(s.done) })

	ictx, cancel := context.WithTimeout(ctx, handshakeWait)
	defer cancel()
	s.Init, err = s.conn.Initialize(ictx, sdk.InitializeRequest{
		ProtocolVersion: sdk.ProtocolVersionNumber,
		ClientCapabilities: sdk.ClientCapabilities{
			Fs:       sdk.FileSystemCapabilities{ReadTextFile: true, WriteTextFile: true},
			Terminal: true,
			// Forms and links (ClientCapabilities.app): {"elicitation":{"form":{},"url":{}}}.
			Elicitation: &sdk.ElicitationCapabilities{Form: &sdk.ElicitationFormCapabilities{},
				Url: &sdk.ElicitationUrlCapabilities{}},
			// Typed session failures (052): JetBrains' AIR extension, version 1, the one
			// Claude's and Codex's adapters read.
			Meta: map[string]any{"jetbrains": map[string]any{"air": map[string]any{"version": 1, "capabilities": []string{"sessionFailure"}}}},
		},
	})
	if err != nil {
		s.Stop()
		// The SDK hands back the timeout as a JSON-RPC error, "context deadline exceeded".
		if ctx.Err() == nil && errors.Is(ictx.Err(), context.DeadlineExceeded) {
			name := l.Name
			if name == "" {
				name = filepath.Base(l.Command)
			}
			said := stderr.say()
			return nil, said == "", fmt.Errorf("%s %w in %d s%s", name, ErrNoAnswer, int(handshakeWait.Seconds()), said)
		}
		return nil, false, fmt.Errorf("initialize: %w%s", err, stderr.say())
	}
	return s, false, nil
}

// takes is the servers the runtime takes: one over http or sse only where it says so
// (SessionServers.noHTTPRefusal).
func (s *Session) takes(mcp []sdk.McpServer, command string) []sdk.McpServer {
	kept := []sdk.McpServer{}
	for _, m := range mcp {
		if m.Http != nil && !s.Init.AgentCapabilities.McpCapabilities.Http {
			log.Printf("%s does not take MCP servers over http: %s is left out", command, m.Http.Name)
			continue
		}
		if m.Sse != nil && !s.Init.AgentCapabilities.McpCapabilities.Sse {
			log.Printf("%s does not take MCP servers over sse: %s is left out", command, m.Sse.Name)
			continue
		}
		kept = append(kept, m)
	}
	return kept
}

// Start launches the runtime and says initialize, then continues the conversation it
// names (session/resume where the runtime offers it, else session/load with its replay
// dropped), or begins one with session/new: also when the runtime no longer has it.
func Start(ctx context.Context, l Launch, sink Sink, mcp []sdk.McpServer, meta, compatibilityMeta map[string]any, continuing, brief string) (*Session, error) {
	s, err := Handshake(ctx, l, sink)
	if err != nil {
		return nil, err
	}
	stderr := s.stderr
	ictx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	mcp = s.takes(mcp, l.Command)
	if s.SupportsSystemPrompt() {
		s.client.mu.Lock()
		s.client.systemPrompt = brief
		s.client.mu.Unlock()
	} else {
		meta = compatibilityMeta
	}
	if continuing != "" {
		if err := s.continueSession(ictx, continuing, l.Dir, mcp, meta); err == nil {
			s.Continued = true
			s.ID = sdk.SessionId(continuing)
			return s, nil
		} else if errors.Is(err, context.DeadlineExceeded) {
			s.Stop()
			return nil, fmt.Errorf("the runtime did not answer: %w%s", err, stderr.say())
		}
		s.Lost = true
	}
	s.NewResult, err = s.conn.NewSession(ictx, sdk.NewSessionRequest{Cwd: l.Dir, McpServers: mcp, Meta: meta})
	if err != nil {
		s.Stop()
		return nil, fmt.Errorf("session/new: %w%s", err, stderr.say())
	}
	s.ID = s.NewResult.SessionId
	return s, nil
}

// continueSession is ACPSession.continueSession: resume where it is offered, else load,
// whose replay of the conversation is not recorded again.
func (s *Session) continueSession(ctx context.Context, id, cwd string, mcp []sdk.McpServer, meta map[string]any) error {
	caps := s.Init.AgentCapabilities
	switch {
	case caps.SessionCapabilities.Resume != nil:
		r, err := s.conn.ResumeSession(ctx, sdk.ResumeSessionRequest{SessionId: sdk.SessionId(id), Cwd: cwd, McpServers: mcp, Meta: meta})
		if err == nil {
			s.NewResult.ConfigOptions = r.ConfigOptions
		}
		return err
	case caps.LoadSession:
		s.client.replaying.Store(true)
		defer s.client.replaying.Store(false)
		r, err := s.conn.LoadSession(ctx, sdk.LoadSessionRequest{SessionId: sdk.SessionId(id), Cwd: cwd, McpServers: mcp, Meta: meta})
		if err == nil {
			s.NewResult.ConfigOptions = r.ConfigOptions
		}
		return err
	}
	return errors.New("the runtime can neither resume nor load a conversation")
}

// Prompt sends one turn and waits for its end. The reply can overtake the last updates,
// so the SDK's notification barrier (it orders notifications before the reply) is relied on.
func (s *Session) Prompt(ctx context.Context, blocks []sdk.ContentBlock) (sdk.PromptResponse, error) {
	r, err := s.conn.Prompt(ctx, sdk.PromptRequest{SessionId: s.ID, Prompt: blocks})
	if err != nil {
		select {
		case <-s.done:
			return r, fmt.Errorf("the runtime exited: %w%s", err, s.stderr.say())
		default:
		}
	}
	return r, err
}

func (s *Session) Cancel(ctx context.Context) error {
	return s.conn.Cancel(ctx, sdk.CancelNotification{SessionId: s.ID})
}

// SetOption is session/set_config_option for a value of any kind, a boolean as one
// (ACPSession.setOption), and is the options the runtime says it has now.
func (s *Session) SetOption(ctx context.Context, id string, value any) ([]sdk.SessionConfigOption, error) {
	var req sdk.SetSessionConfigOptionRequest
	switch v := value.(type) {
	case bool:
		req.Boolean = &sdk.SetSessionConfigOptionBoolean{SessionId: s.ID, ConfigId: sdk.SessionConfigId(id), Type: "boolean", Value: v}
	case string:
		req.ValueId = &sdk.SetSessionConfigOptionValueId{SessionId: s.ID, ConfigId: sdk.SessionConfigId(id), Value: sdk.SessionConfigValueId(v)}
	default:
		return nil, fmt.Errorf("an option is a string or a boolean, not %T", value)
	}
	r, err := s.conn.SetSessionConfigOption(ctx, req)
	return r.ConfigOptions, err
}

// SupportsSteering is initialize's root _meta.steering.supported: whether words can go
// into a running turn (_session/steering).
func (s *Session) SupportsSteering() bool {
	steering, _ := s.Init.Meta["steering"].(map[string]any)
	supported, _ := steering["supported"].(bool)
	return supported
}

// SupportsSystemPrompt reports the draft ACP session system-prompt capability.
func (s *Session) SupportsSystemPrompt() bool {
	s.client.mu.Lock()
	defer s.client.mu.Unlock()
	return s.client.supportsSystemPrompt
}

// Steer puts words into the running turn (ACPSession.steer), always with idleBehavior
// promptRequired, and is what the runtime did with them: injected, startedNewTurn,
// promptRequired, or failed for an answer that cannot be read.
func (s *Session) Steer(ctx context.Context, blocks []sdk.ContentBlock) (string, error) {
	raw, err := s.conn.CallExtension(ctx, "_session/steering", map[string]any{"sessionId": s.ID, "prompt": blocks,
		"_meta": map[string]any{"steering": map[string]any{"idleBehavior": "promptRequired"}}})
	if err != nil {
		return "", err
	}
	var r struct {
		Outcome string `json:"outcome"`
	}
	if json.Unmarshal(raw, &r) != nil {
		return "failed", nil
	}
	switch r.Outcome {
	case "injected", "startedNewTurn", "promptRequired":
		return r.Outcome, nil
	}
	return "failed", nil
}

func (s *Session) SetConfig(ctx context.Context, id, value string) error {
	_, err := s.conn.SetSessionConfigOption(ctx, sdk.SetSessionConfigOptionRequest{
		ValueId: &sdk.SetSessionConfigOptionValueId{SessionId: s.ID, ConfigId: sdk.SessionConfigId(id), Value: sdk.SessionConfigValueId(value)},
	})
	return err
}

// Stop ends the process group: TERM, then KILL.
func (s *Session) Stop() {
	if s.cmd.Process == nil {
		return
	}
	pgid := s.cmd.Process.Pid
	_ = syscall.Kill(-pgid, syscall.SIGTERM)
	select {
	case <-s.done:
	case <-time.After(3 * time.Second):
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
	}
	s.client.closeTerminals()
}

func (s *Session) Done() <-chan struct{} { return s.done }

// client answers the runtime's requests.
type client struct {
	sink Sink
	dir  string
	// runtime is the name shown to the person (Launch.Name), used for narrow client
	// compatibility where an ACP runtime does not follow the standard request shape.
	runtime string
	// systemPrompt is attached to every session lifecycle request only when initialize
	// advertised the draft ACP sessionCapabilities.systemPrompt field.
	systemPrompt         string
	supportsSystemPrompt bool
	// env is the runtime's own environment (environment, runtimes.go), which its
	// terminals get too: never the daemon's whole one.
	env       []string
	mu        sync.Mutex
	terminals map[string]*terminal
	next      int
	// allowedEdits is each file the person just allowed an edit to on the runtime's own
	// card, and when (ACPSession.allowedEdits).
	allowedEdits map[string]time.Time
	// replaying is set while a session/load replays the conversation, which is already on
	// the record.
	replaying atomic.Bool
	// raw is each elicitation/create's params as the runtime sent them, oldest first. The
	// SDK's typed request drops what the form is drawn from (propertyOrder, requestId).
	raw []json.RawMessage
}

var _ sdk.Client = (*client)(nil)

func (c *client) RequestPermission(ctx context.Context, p sdk.RequestPermissionRequest) (_ sdk.RequestPermissionResponse, err error) {
	defer safe.Err("acp RequestPermission", &err)
	option := c.sink.Permission(ctx, p)
	if option == "" {
		return sdk.RequestPermissionResponse{Outcome: sdk.RequestPermissionOutcome{Cancelled: &sdk.RequestPermissionOutcomeCancelled{}}}, nil
	}
	c.noteAllowedEdit(p, option)
	return sdk.RequestPermissionResponse{Outcome: sdk.RequestPermissionOutcome{Selected: &sdk.RequestPermissionOutcomeSelected{OptionId: sdk.PermissionOptionId(option)}}}, nil
}

// allowedEditWindow is how long an edit allowed on the runtime's own card covers its write.
const allowedEditWindow = 60 * time.Second

// noteAllowedEdit keeps the files an edit the person just allowed on the runtime's own card
// names (049, T025a). Antigravity asks "Run client_create_file?" with the diff, then writes
// through fs/write_text_file; asking again there is the same question twice. Only an edit,
// only by a diff or location naming the file.
func (c *client) noteAllowedEdit(p sdk.RequestPermissionRequest, option string) {
	allowed := strings.HasPrefix(option, "allow")
	for _, o := range p.Options {
		if string(o.OptionId) == option {
			allowed = o.Kind == sdk.PermissionOptionKindAllowOnce || o.Kind == sdk.PermissionOptionKindAllowAlways
		}
	}
	if !allowed {
		return
	}
	var named []string
	for _, content := range p.ToolCall.Content {
		if content.Diff != nil {
			named = append(named, content.Diff.Path)
		}
	}
	if p.ToolCall.Kind != nil && *p.ToolCall.Kind == sdk.ToolKindEdit {
		for _, l := range p.ToolCall.Locations {
			named = append(named, l.Path)
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.allowedEdits == nil {
		c.allowedEdits = map[string]time.Time{}
	}
	for _, path := range named {
		c.allowedEdits[samePath(path)] = time.Now()
	}
}

// takeAllowedEdit is whether a write to path was just allowed on the runtime's own card,
// which it then uses up.
func (c *client) takeAllowedEdit(path string) bool {
	key := samePath(path)
	c.mu.Lock()
	defer c.mu.Unlock()
	at, ok := c.allowedEdits[key]
	delete(c.allowedEdits, key)
	return ok && time.Since(at) < allowedEditWindow
}

// samePath is one key for one file: /tmp/x and /private/tmp/x are one.
func samePath(path string) string {
	if resolved, err := resolve(path); err == nil {
		return resolved
	}
	return filepath.Clean(path)
}

func (c *client) UnstableCreateElicitation(ctx context.Context, p sdk.UnstableCreateElicitationRequest) (_ sdk.UnstableCreateElicitationResponse, err error) {
	defer safe.Err("acp CreateElicitation", &err)
	action, content := c.sink.Elicitation(ctx, c.takeRaw(p))
	switch action {
	case "accept":
		if content == nil {
			content = map[string]any{}
		}
		return sdk.UnstableCreateElicitationResponse{Accept: &sdk.UnstableCreateElicitationAccept{Action: "accept", Content: content}}, nil
	case "decline":
		return sdk.UnstableCreateElicitationResponse{Decline: &sdk.UnstableCreateElicitationDecline{Action: "decline"}}, nil
	default:
		return sdk.UnstableCreateElicitationResponse{Cancel: &sdk.UnstableCreateElicitationCancel{Action: "cancel"}}, nil
	}
}

func (c *client) UnstableCompleteElicitation(ctx context.Context, p sdk.UnstableCompleteElicitationNotification) (err error) {
	defer safe.Err("acp CompleteElicitation", &err)
	c.sink.ElicitationComplete(string(p.ElicitationId))
	return nil
}

// takeRaw is the raw params of the request the SDK typed as p: the oldest kept with the
// same message, or p itself when none was kept.
func (c *client) takeRaw(p sdk.UnstableCreateElicitationRequest) json.RawMessage {
	message := ""
	if p.Form != nil {
		message = p.Form.Message
	} else if p.Url != nil {
		message = p.Url.Message
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for i, raw := range c.raw {
		var m struct {
			Message string `json:"message"`
		}
		if json.Unmarshal(raw, &m) == nil && m.Message == message {
			c.raw = append(c.raw[:i], c.raw[i+1:]...)
			return raw
		}
	}
	b, _ := json.Marshal(p)
	return b
}

// rawElicitations reads the runtime's output for the SDK, keeping a copy of each
// elicitation/create's params on the way (at most 16, the oldest dropped), and whether the
// initialize response advertised systemPrompt. Only lines with a marker are decoded: every
// chunk, tool result and replayed line passes through here (#2733).
type rawElicitations struct {
	r       *bufio.Reader
	c       *client
	pending []byte
	// handshook is set once the initialize response has been read; no later line is
	// decoded for capabilities.
	handshook bool
}

var (
	agentCapabilitiesMarker = []byte(`"agentCapabilities"`)
	elicitationCreateMarker = []byte(`"elicitation/create"`)
)

func (e *rawElicitations) Read(b []byte) (int, error) {
	if len(e.pending) == 0 {
		line, err := e.r.ReadBytes('\n')
		if len(line) == 0 {
			return 0, err
		}
		e.keep(line)
		e.pending = line
	}
	n := copy(b, e.pending)
	e.pending = e.pending[n:]
	return n, nil
}

func (e *rawElicitations) keep(line []byte) {
	if !e.handshook && bytes.Contains(line, agentCapabilitiesMarker) {
		e.capabilities(line)
	}
	if !bytes.Contains(line, elicitationCreateMarker) {
		return
	}
	var m struct {
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if json.Unmarshal(line, &m) != nil || m.Method != sdk.ClientMethodElicitationCreate {
		return
	}
	e.c.mu.Lock()
	defer e.c.mu.Unlock()
	e.c.raw = append(e.c.raw, m.Params)
	if len(e.c.raw) > 16 {
		e.c.raw = e.c.raw[1:]
	}
}

// capabilities reads the systemPrompt capability from the initialize response, and marks
// the handshake done once a response with agentCapabilities has been read.
func (e *rawElicitations) capabilities(line []byte) {
	var response struct {
		Result struct {
			AgentCapabilities *struct {
				SessionCapabilities map[string]json.RawMessage `json:"sessionCapabilities"`
			} `json:"agentCapabilities"`
		} `json:"result"`
	}
	if json.Unmarshal(line, &response) != nil || response.Result.AgentCapabilities == nil {
		return
	}
	e.handshook = true
	if raw, ok := response.Result.AgentCapabilities.SessionCapabilities["systemPrompt"]; ok {
		var capability map[string]json.RawMessage
		if json.Unmarshal(raw, &capability) == nil && capability != nil {
			e.c.mu.Lock()
			e.c.supportsSystemPrompt = true
			e.c.mu.Unlock()
		}
	}
}

// sessionPromptWriter adds standard ACP systemPrompt fields to the lifecycle calls. This
// keeps the draft protocol field out of the pinned SDK's generated request structs.
type sessionPromptWriter struct {
	w   io.Writer
	c   *client
	mu  sync.Mutex
	buf []byte
}

func (w *sessionPromptWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	start := 0
	defer func() { w.buf = append(w.buf[:0], w.buf[start:]...) }()
	for {
		i := bytes.IndexByte(w.buf[start:], '\n')
		if i < 0 {
			break
		}
		// The line is written before w.buf changes, so it needs no copy of its own.
		line := w.inject(w.buf[start : start+i+1])
		start += i + 1
		n, err := w.w.Write(line)
		if err != nil {
			return 0, err
		}
		if n != len(line) {
			return 0, io.ErrShortWrite
		}
	}
	return len(p), nil
}

func (w *sessionPromptWriter) inject(line []byte) []byte {
	w.c.mu.Lock()
	brief, supported := w.c.systemPrompt, w.c.supportsSystemPrompt
	w.c.mu.Unlock()
	if !supported || brief == "" || !isSessionLifecycle(line) {
		return line
	}
	var message map[string]any
	if json.Unmarshal(line, &message) != nil {
		return line
	}
	method, _ := message["method"].(string)
	if !slices.Contains(sessionLifecycleMethods, method) {
		return line
	}
	params, ok := message["params"].(map[string]any)
	if !ok {
		return line
	}
	params["systemPrompt"] = map[string]any{"mode": "append", "content": []any{map[string]any{"type": "text", "text": brief}}}
	out, err := json.Marshal(message)
	if err != nil {
		return line
	}
	return append(out, '\n')
}

// sessionLifecycleMethods are the requests that carry systemPrompt, and
// sessionLifecycleMarkers their quoted names to look for before any decode.
var (
	sessionLifecycleMethods = []string{"session/new", "session/load", "session/resume", "session/fork"}
	sessionLifecycleMarkers = func() [][]byte {
		markers := make([][]byte, len(sessionLifecycleMethods))
		for i, method := range sessionLifecycleMethods {
			markers[i] = []byte(`"` + method + `"`)
		}
		return markers
	}()
)

// isSessionLifecycle is a byte check for a lifecycle method name, so prompts, attachments
// and replies are not decoded on the way out (#2733).
func isSessionLifecycle(line []byte) bool {
	for _, marker := range sessionLifecycleMarkers {
		if bytes.Contains(line, marker) {
			return true
		}
	}
	return false
}

func (c *client) SessionUpdate(ctx context.Context, n sdk.SessionNotification) (err error) {
	defer safe.Err("acp SessionUpdate", &err)
	if c.replaying.Load() {
		return nil
	}
	c.sink.Update(n)
	return nil
}

// inside keeps file service, and a terminal's folder, to the agent's folder, with links
// followed (FolderScope.allows): it is the path to use, as resolved. A path that does not
// exist yet is judged by its nearest parent that does, so a runtime can make a file but not
// one through a link out of its folder.
func (c *client) inside(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("path must be absolute: %s", path)
	}
	dir, err := resolve(c.dir)
	if err != nil {
		return "", err
	}
	resolved, err := resolve(path)
	if err != nil {
		return "", fmt.Errorf("%s is outside the agent's folder", path)
	}
	rel, err := filepath.Rel(dir, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return "", fmt.Errorf("%s is outside the agent's folder", path)
	}
	return resolved, nil
}

// resolve is path with its links followed, working up to the nearest parent that exists
// when the path does not. A link that leads nowhere is refused: writing it would make
// the file it names, wherever that is.
func resolve(path string) (string, error) {
	p := filepath.Clean(path)
	var missing []string
	for {
		resolved, err := filepath.EvalSymlinks(p)
		if err == nil {
			return filepath.Join(append([]string{resolved}, missing...)...), nil
		}
		if _, lerr := os.Lstat(p); lerr == nil || !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(p)
		if parent == p {
			return "", err
		}
		missing = append([]string{filepath.Base(p)}, missing...)
		p = parent
	}
}

func (c *client) ReadTextFile(ctx context.Context, p sdk.ReadTextFileRequest) (_ sdk.ReadTextFileResponse, err error) {
	defer safe.Err("acp ReadTextFile", &err)
	path, err := c.inside(p.Path)
	if err != nil {
		return sdk.ReadTextFileResponse{}, err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return sdk.ReadTextFileResponse{}, err
	}
	content := string(b)
	if p.Line != nil || p.Limit != nil {
		lines := strings.Split(content, "\n")
		start := 0
		if p.Line != nil && *p.Line > 0 {
			start = min(*p.Line-1, len(lines))
		}
		end := len(lines)
		if p.Limit != nil && *p.Limit > 0 && start+*p.Limit < end {
			end = start + *p.Limit
		}
		content = strings.Join(lines[start:end], "\n")
	}
	c.sink.Served("read", p.Path)
	return sdk.ReadTextFileResponse{Content: content}, nil
}

func (c *client) WriteTextFile(ctx context.Context, p sdk.WriteTextFileRequest) (_ sdk.WriteTextFileResponse, err error) {
	defer safe.Err("acp WriteTextFile", &err)
	path, err := c.inside(p.Path)
	if err != nil {
		return sdk.WriteTextFileResponse{}, err
	}
	// A write is a change, so it is asked about as any other change is, with the change on
	// the card, unless the person has just allowed it on the runtime's own card.
	if !c.takeAllowedEdit(path) && c.sink.Permission(ctx, writeRequest(p.Path, path, p.Content)) != "allow_once" {
		return sdk.WriteTextFileResponse{}, fmt.Errorf("the person said no to writing %s", p.Path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return sdk.WriteTextFileResponse{}, err
	}
	// The resolved path, and no link followed at its end, so what was checked is what is written.
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC|syscall.O_NOFOLLOW, 0o644)
	if err != nil {
		return sdk.WriteTextFileResponse{}, err
	}
	if _, err := f.WriteString(p.Content); err != nil {
		_ = f.Close()
		return sdk.WriteTextFileResponse{}, err
	}
	if err := f.Close(); err != nil {
		return sdk.WriteTextFileResponse{}, err
	}
	c.sink.Served("write", p.Path)
	return sdk.WriteTextFileResponse{}, nil
}

// writeRequest is the card for a write the runtime asks the client for
// (FileService.writeToolCall): the diff against the file as it is, Allow or Refuse.
func writeRequest(asked, path, content string) sdk.RequestPermissionRequest {
	diff := sdk.ToolDiffContent(asked, content)
	if b, err := os.ReadFile(path); err == nil {
		diff = sdk.ToolDiffContent(asked, content, string(b))
	}
	return sdk.RequestPermissionRequest{
		ToolCall: sdk.ToolCallUpdate{Title: sdk.Ptr("Write " + filepath.Base(asked)), Kind: sdk.Ptr(sdk.ToolKindEdit),
			Status: sdk.Ptr(sdk.ToolCallStatusPending), Content: []sdk.ToolCallContent{diff},
			Locations: []sdk.ToolCallLocation{{Path: asked}}},
		Options: []sdk.PermissionOption{{OptionId: "allow_once", Name: "Allow", Kind: sdk.PermissionOptionKindAllowOnce},
			{OptionId: "reject_once", Name: "Refuse", Kind: sdk.PermissionOptionKindRejectOnce}},
	}
}

// MARK: terminals the runtime asks for (terminal/*)

type terminal struct {
	cmd    *exec.Cmd
	mu     sync.Mutex
	out    []byte
	limit  int
	done   chan struct{}
	status *sdk.TerminalExitStatus
}

func (t *terminal) Write(b []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.out = append(t.out, b...)
	if len(t.out) > t.limit {
		t.out = t.out[len(t.out)-t.limit/2:]
	}
	return len(b), nil
}

func (c *client) CreateTerminal(ctx context.Context, p sdk.CreateTerminalRequest) (_ sdk.CreateTerminalResponse, err error) {
	defer safe.Err("acp CreateTerminal", &err)
	command, args := p.Command, p.Args
	// Grok sends its full shell invocation in command instead of separating the
	// executable and arguments. Run only that known shape through bash; other
	// runtimes keep the standard executable-plus-arguments path below.
	if strings.EqualFold(c.runtime, "Grok") && len(args) == 0 && strings.HasPrefix(command, "/bin/bash -lc ") {
		args = []string{"-lc", command}
		command = "/bin/bash"
	}
	cmd := exec.Command(command, args...)
	cmd.Dir = c.dir
	if p.Cwd != nil {
		dir, err := c.inside(*p.Cwd)
		if err != nil {
			return sdk.CreateTerminalResponse{}, err
		}
		cmd.Dir = dir
	}
	cmd.Env = append([]string{}, c.env...)
	for _, e := range p.Env {
		cmd.Env = append(cmd.Env, e.Name+"="+e.Value)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	limit := 256 << 10
	if p.OutputByteLimit != nil && *p.OutputByteLimit > 0 {
		limit = *p.OutputByteLimit
	}
	t := &terminal{cmd: cmd, limit: limit, done: make(chan struct{})}
	cmd.Stdout, cmd.Stderr = t, t
	if err := cmd.Start(); err != nil {
		return sdk.CreateTerminalResponse{}, err
	}
	safe.Go("terminal wait", func() {
		err := cmd.Wait()
		code := 0
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code = exit.ExitCode()
		}
		t.mu.Lock()
		t.status = &sdk.TerminalExitStatus{ExitCode: &code}
		t.mu.Unlock()
		close(t.done)
	})

	c.mu.Lock()
	c.next++
	id := fmt.Sprintf("term-%d", c.next)
	c.terminals[id] = t
	c.mu.Unlock()
	c.sink.Served("terminal", strings.Join(append([]string{command}, args...), " "))
	return sdk.CreateTerminalResponse{TerminalId: id}, nil
}

func (c *client) terminal(id string) (*terminal, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	t := c.terminals[id]
	if t == nil {
		return nil, fmt.Errorf("no terminal %s", id)
	}
	return t, nil
}

func (c *client) TerminalOutput(ctx context.Context, p sdk.TerminalOutputRequest) (_ sdk.TerminalOutputResponse, err error) {
	defer safe.Err("acp TerminalOutput", &err)
	t, err := c.terminal(p.TerminalId)
	if err != nil {
		return sdk.TerminalOutputResponse{}, err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return sdk.TerminalOutputResponse{Output: string(t.out), ExitStatus: t.status}, nil
}

func (c *client) WaitForTerminalExit(ctx context.Context, p sdk.WaitForTerminalExitRequest) (_ sdk.WaitForTerminalExitResponse, err error) {
	defer safe.Err("acp WaitForTerminalExit", &err)
	t, err := c.terminal(p.TerminalId)
	if err != nil {
		return sdk.WaitForTerminalExitResponse{}, err
	}
	select {
	case <-t.done:
	case <-ctx.Done():
		return sdk.WaitForTerminalExitResponse{}, ctx.Err()
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return sdk.WaitForTerminalExitResponse{ExitCode: t.status.ExitCode}, nil
}

func (c *client) KillTerminal(ctx context.Context, p sdk.KillTerminalRequest) (_ sdk.KillTerminalResponse, err error) {
	defer safe.Err("acp KillTerminal", &err)
	t, err := c.terminal(p.TerminalId)
	if err != nil {
		return sdk.KillTerminalResponse{}, err
	}
	if t.cmd.Process != nil {
		_ = syscall.Kill(-t.cmd.Process.Pid, syscall.SIGKILL)
	}
	return sdk.KillTerminalResponse{}, nil
}

func (c *client) ReleaseTerminal(ctx context.Context, p sdk.ReleaseTerminalRequest) (_ sdk.ReleaseTerminalResponse, err error) {
	defer safe.Err("acp ReleaseTerminal", &err)
	_, _ = c.KillTerminal(ctx, sdk.KillTerminalRequest{SessionId: p.SessionId, TerminalId: p.TerminalId})
	c.mu.Lock()
	delete(c.terminals, p.TerminalId)
	c.mu.Unlock()
	return sdk.ReleaseTerminalResponse{}, nil
}

func (c *client) closeTerminals() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, t := range c.terminals {
		if t.cmd.Process != nil {
			_ = syscall.Kill(-t.cmd.Process.Pid, syscall.SIGKILL)
		}
	}
}

// tail keeps the last 8 KiB of the runtime's stderr, and logs it.
type tail struct {
	mu  sync.Mutex
	buf []byte
}

func (t *tail) Write(b []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, b...)
	if len(t.buf) > 8192 {
		t.buf = t.buf[len(t.buf)-8192:]
	}
	sc := bufio.NewScanner(strings.NewReader(string(b)))
	for sc.Scan() {
		log.Printf("runtime stderr: %s", sc.Text())
	}
	return len(b), nil
}

func (t *tail) say() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.buf) == 0 {
		return ""
	}
	s := string(t.buf)
	if len(s) > 600 {
		s = s[len(s)-600:]
	}
	return "\n" + s
}

var _ io.Writer = (*tail)(nil)

// ErrCannotFork is a runtime that does not say it can branch a conversation.
var ErrCannotFork = errors.New("the runtime cannot branch a conversation")

// ErrConversationGone is a conversation the runtime no longer has.
var ErrConversationGone = errors.New("the runtime no longer has this conversation")

// Fork is agents/fork's handshake (DaemonCore.fork): a runtime of its own, the
// conversation continued, then session/fork; the process goes once it has answered.
func Fork(ctx context.Context, l Launch, sink Sink, sessionID, cwd string, meta, compatibilityMeta map[string]any, brief string) (string, error) {
	l.Dir = cwd
	s, err := Start(ctx, l, sink, nil, meta, compatibilityMeta, sessionID, brief)
	if err != nil {
		return "", err
	}
	defer s.Stop()
	if s.Init.AgentCapabilities.SessionCapabilities.Fork == nil {
		return "", ErrCannotFork
	}
	if !s.Continued {
		return "", ErrConversationGone
	}
	fctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	requestMeta := compatibilityMeta
	if s.SupportsSystemPrompt() {
		requestMeta = meta
	}
	r, err := s.conn.UnstableForkSession(fctx, sdk.UnstableForkSessionRequest{SessionId: sdk.SessionId(sessionID), Cwd: cwd, Meta: requestMeta})
	if err != nil {
		return "", err
	}
	return string(r.SessionId), nil
}

// CanList, CanDelete and CanLoad are whether the runtime lists its conversations, deletes
// one, and loads one with its replay.
func (s *Session) CanList() bool   { return s.Init.AgentCapabilities.SessionCapabilities.List != nil }
func (s *Session) CanDelete() bool { return s.Init.AgentCapabilities.SessionCapabilities.Delete != nil }
func (s *Session) CanLoad() bool   { return s.Init.AgentCapabilities.LoadSession }

// ListSessions is session/list for a folder, every page of it (ACPSession.listSessions).
func (s *Session) ListSessions(ctx context.Context, cwd string) ([]sdk.SessionInfo, error) {
	var out []sdk.SessionInfo
	var cursor *string
	for page := 0; page < 50; page++ {
		r, err := s.conn.ListSessions(ctx, sdk.ListSessionsRequest{Cwd: &cwd, Cursor: cursor})
		if err != nil {
			return nil, err
		}
		out = append(out, r.Sessions...)
		if r.NextCursor == nil || *r.NextCursor == "" {
			break
		}
		cursor = r.NextCursor
	}
	return out, nil
}

// DeleteSession is session/delete.
func (s *Session) DeleteSession(ctx context.Context, id string) error {
	_, err := s.conn.UnstableDeleteSession(ctx, sdk.UnstableDeleteSessionRequest{SessionId: sdk.SessionId(id)})
	return err
}

// LoadRecorded is session/load with its replay given to the sink: a conversation taken over
// from the runtime, whose replay is its transcript.
func (s *Session) LoadRecorded(ctx context.Context, id, cwd string, mcp []sdk.McpServer, meta map[string]any) error {
	r, err := s.conn.LoadSession(ctx, sdk.LoadSessionRequest{SessionId: sdk.SessionId(id), Cwd: cwd, McpServers: s.takes(mcp, "the runtime"), Meta: meta})
	if err != nil {
		return err
	}
	s.NewResult.ConfigOptions = r.ConfigOptions
	s.ID = sdk.SessionId(id)
	return nil
}
