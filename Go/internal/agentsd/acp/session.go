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
	"log"
	"os"
	"os/exec"
	"path/filepath"
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
}

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

// Start launches the runtime and says initialize, then continues the conversation it
// names (session/resume where the runtime offers it, else session/load with its replay
// dropped), or begins one with session/new: also when the runtime no longer has it.
func Start(ctx context.Context, l Launch, sink Sink, mcp []sdk.McpServer, meta map[string]any, continuing string) (*Session, error) {
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
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr := &tail{}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start %s: %w", l.Command, err)
	}
	s := &Session{cmd: cmd, stderr: stderr, done: make(chan struct{})}
	s.client = &client{sink: sink, dir: l.Dir, terminals: map[string]*terminal{}}
	s.conn = sdk.NewClientSideConnection(s.client, stdin, &rawElicitations{r: bufio.NewReader(stdout), c: s.client})
	safe.Go("runtime wait", func() { _ = cmd.Wait(); close(s.done) })

	ictx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	s.Init, err = s.conn.Initialize(ictx, sdk.InitializeRequest{
		ProtocolVersion: sdk.ProtocolVersionNumber,
		ClientCapabilities: sdk.ClientCapabilities{
			Fs:       sdk.FileSystemCapabilities{ReadTextFile: true, WriteTextFile: true},
			Terminal: true,
			// Forms and links (ClientCapabilities.app): {"elicitation":{"form":{},"url":{}}}.
			Elicitation: &sdk.ElicitationCapabilities{Form: &sdk.ElicitationFormCapabilities{},
				Url: &sdk.ElicitationUrlCapabilities{}},
		},
	})
	if err != nil {
		s.Stop()
		return nil, fmt.Errorf("initialize: %w%s", err, stderr.say())
	}
	if mcp == nil {
		mcp = []sdk.McpServer{}
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
	sink      Sink
	dir       string
	mu        sync.Mutex
	terminals map[string]*terminal
	next      int
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
	return sdk.RequestPermissionResponse{Outcome: sdk.RequestPermissionOutcome{Selected: &sdk.RequestPermissionOutcomeSelected{OptionId: sdk.PermissionOptionId(option)}}}, nil
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
// elicitation/create's params on the way (at most 16, the oldest dropped).
type rawElicitations struct {
	r       *bufio.Reader
	c       *client
	pending []byte
}

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
	if !bytes.Contains(line, []byte(`"elicitation/create"`)) {
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

func (c *client) SessionUpdate(ctx context.Context, n sdk.SessionNotification) (err error) {
	defer safe.Err("acp SessionUpdate", &err)
	if c.replaying.Load() {
		return nil
	}
	c.sink.Update(n)
	return nil
}

// inside keeps file service to the agent's folder.
func (c *client) inside(path string) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("path must be absolute: %s", path)
	}
	rel, err := filepath.Rel(c.dir, filepath.Clean(path))
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return fmt.Errorf("%s is outside the agent's folder", path)
	}
	return nil
}

func (c *client) ReadTextFile(ctx context.Context, p sdk.ReadTextFileRequest) (_ sdk.ReadTextFileResponse, err error) {
	defer safe.Err("acp ReadTextFile", &err)
	if err := c.inside(p.Path); err != nil {
		return sdk.ReadTextFileResponse{}, err
	}
	b, err := os.ReadFile(p.Path)
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
	if err := c.inside(p.Path); err != nil {
		return sdk.WriteTextFileResponse{}, err
	}
	if err := os.MkdirAll(filepath.Dir(p.Path), 0o755); err != nil {
		return sdk.WriteTextFileResponse{}, err
	}
	if err := os.WriteFile(p.Path, []byte(p.Content), 0o644); err != nil {
		return sdk.WriteTextFileResponse{}, err
	}
	c.sink.Served("write", p.Path)
	return sdk.WriteTextFileResponse{}, nil
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
	cmd := exec.Command(p.Command, p.Args...)
	cmd.Dir = c.dir
	if p.Cwd != nil {
		cmd.Dir = *p.Cwd
	}
	cmd.Env = os.Environ()
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
	c.sink.Served("terminal", strings.Join(append([]string{p.Command}, p.Args...), " "))
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
func Fork(ctx context.Context, l Launch, sink Sink, sessionID, cwd string, meta map[string]any) (string, error) {
	l.Dir = cwd
	s, err := Start(ctx, l, sink, nil, meta, sessionID)
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
	r, err := s.conn.UnstableForkSession(fctx, sdk.UnstableForkSessionRequest{SessionId: sdk.SessionId(sessionID), Cwd: cwd, Meta: meta})
	if err != nil {
		return "", err
	}
	return string(r.SessionId), nil
}
