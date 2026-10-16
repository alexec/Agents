// Package runtime starts an agent runtime and speaks ACP to it with coder/acp-go-sdk.
package runtime

import (
	"bufio"
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
	"syscall"
	"time"

	acp "github.com/coder/acp-go-sdk"
)

// Sink is what the daemon hears from a session.
type Sink interface {
	Update(n acp.SessionNotification)
	// Permission blocks until the person answers, and returns the option chosen, or "" for cancelled.
	Permission(ctx context.Context, req acp.RequestPermissionRequest) string
	// Served is a file read or write, or a terminal, the client did for the runtime.
	Served(kind, detail string)
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
	conn      *acp.ClientSideConnection
	ID        acp.SessionId
	Init      acp.InitializeResponse
	NewResult acp.NewSessionResponse
	client    *client
	stderr    *tail
	done      chan struct{}
}

// Start launches the runtime, says initialize and session/new.
func Start(ctx context.Context, l Launch, sink Sink, mcp []acp.McpServer, meta map[string]any) (*Session, error) {
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
	s.conn = acp.NewClientSideConnection(s.client, stdin, stdout)
	go func() { _ = cmd.Wait(); close(s.done) }()

	ictx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	s.Init, err = s.conn.Initialize(ictx, acp.InitializeRequest{
		ProtocolVersion: acp.ProtocolVersionNumber,
		ClientCapabilities: acp.ClientCapabilities{
			Fs:       acp.FileSystemCapabilities{ReadTextFile: true, WriteTextFile: true},
			Terminal: true,
		},
	})
	if err != nil {
		s.Stop()
		return nil, fmt.Errorf("initialize: %w%s", err, stderr.say())
	}
	if mcp == nil {
		mcp = []acp.McpServer{}
	}
	s.NewResult, err = s.conn.NewSession(ictx, acp.NewSessionRequest{Cwd: l.Dir, McpServers: mcp, Meta: meta})
	if err != nil {
		s.Stop()
		return nil, fmt.Errorf("session/new: %w%s", err, stderr.say())
	}
	s.ID = s.NewResult.SessionId
	return s, nil
}

// Prompt sends one turn and waits for its end. The reply can overtake the last updates,
// so the SDK's notification barrier (it orders notifications before the reply) is relied on.
func (s *Session) Prompt(ctx context.Context, text string) (acp.PromptResponse, error) {
	r, err := s.conn.Prompt(ctx, acp.PromptRequest{SessionId: s.ID, Prompt: []acp.ContentBlock{acp.TextBlock(text)}})
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
	return s.conn.Cancel(ctx, acp.CancelNotification{SessionId: s.ID})
}

func (s *Session) SetConfig(ctx context.Context, id, value string) error {
	_, err := s.conn.SetSessionConfigOption(ctx, acp.SetSessionConfigOptionRequest{
		ValueId: &acp.SetSessionConfigOptionValueId{SessionId: s.ID, ConfigId: acp.SessionConfigId(id), Value: acp.SessionConfigValueId(value)},
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
}

var _ acp.Client = (*client)(nil)

func (c *client) RequestPermission(ctx context.Context, p acp.RequestPermissionRequest) (acp.RequestPermissionResponse, error) {
	option := c.sink.Permission(ctx, p)
	if option == "" {
		return acp.RequestPermissionResponse{Outcome: acp.RequestPermissionOutcome{Cancelled: &acp.RequestPermissionOutcomeCancelled{}}}, nil
	}
	return acp.RequestPermissionResponse{Outcome: acp.RequestPermissionOutcome{Selected: &acp.RequestPermissionOutcomeSelected{OptionId: acp.PermissionOptionId(option)}}}, nil
}

func (c *client) SessionUpdate(ctx context.Context, n acp.SessionNotification) error {
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

func (c *client) ReadTextFile(ctx context.Context, p acp.ReadTextFileRequest) (acp.ReadTextFileResponse, error) {
	if err := c.inside(p.Path); err != nil {
		return acp.ReadTextFileResponse{}, err
	}
	b, err := os.ReadFile(p.Path)
	if err != nil {
		return acp.ReadTextFileResponse{}, err
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
	return acp.ReadTextFileResponse{Content: content}, nil
}

func (c *client) WriteTextFile(ctx context.Context, p acp.WriteTextFileRequest) (acp.WriteTextFileResponse, error) {
	if err := c.inside(p.Path); err != nil {
		return acp.WriteTextFileResponse{}, err
	}
	if err := os.MkdirAll(filepath.Dir(p.Path), 0o755); err != nil {
		return acp.WriteTextFileResponse{}, err
	}
	if err := os.WriteFile(p.Path, []byte(p.Content), 0o644); err != nil {
		return acp.WriteTextFileResponse{}, err
	}
	c.sink.Served("write", p.Path)
	return acp.WriteTextFileResponse{}, nil
}

// MARK: terminals the runtime asks for (terminal/*)

type terminal struct {
	cmd    *exec.Cmd
	mu     sync.Mutex
	out    []byte
	limit  int
	done   chan struct{}
	status *acp.TerminalExitStatus
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

func (c *client) CreateTerminal(ctx context.Context, p acp.CreateTerminalRequest) (acp.CreateTerminalResponse, error) {
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
		return acp.CreateTerminalResponse{}, err
	}
	go func() {
		err := cmd.Wait()
		code := 0
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code = exit.ExitCode()
		}
		t.mu.Lock()
		t.status = &acp.TerminalExitStatus{ExitCode: &code}
		t.mu.Unlock()
		close(t.done)
	}()
	c.mu.Lock()
	c.next++
	id := fmt.Sprintf("term-%d", c.next)
	c.terminals[id] = t
	c.mu.Unlock()
	c.sink.Served("terminal", strings.Join(append([]string{p.Command}, p.Args...), " "))
	return acp.CreateTerminalResponse{TerminalId: id}, nil
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

func (c *client) TerminalOutput(ctx context.Context, p acp.TerminalOutputRequest) (acp.TerminalOutputResponse, error) {
	t, err := c.terminal(p.TerminalId)
	if err != nil {
		return acp.TerminalOutputResponse{}, err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return acp.TerminalOutputResponse{Output: string(t.out), ExitStatus: t.status}, nil
}

func (c *client) WaitForTerminalExit(ctx context.Context, p acp.WaitForTerminalExitRequest) (acp.WaitForTerminalExitResponse, error) {
	t, err := c.terminal(p.TerminalId)
	if err != nil {
		return acp.WaitForTerminalExitResponse{}, err
	}
	select {
	case <-t.done:
	case <-ctx.Done():
		return acp.WaitForTerminalExitResponse{}, ctx.Err()
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return acp.WaitForTerminalExitResponse{ExitCode: t.status.ExitCode}, nil
}

func (c *client) KillTerminal(ctx context.Context, p acp.KillTerminalRequest) (acp.KillTerminalResponse, error) {
	t, err := c.terminal(p.TerminalId)
	if err != nil {
		return acp.KillTerminalResponse{}, err
	}
	if t.cmd.Process != nil {
		_ = syscall.Kill(-t.cmd.Process.Pid, syscall.SIGKILL)
	}
	return acp.KillTerminalResponse{}, nil
}

func (c *client) ReleaseTerminal(ctx context.Context, p acp.ReleaseTerminalRequest) (acp.ReleaseTerminalResponse, error) {
	_, _ = c.KillTerminal(ctx, acp.KillTerminalRequest{SessionId: p.SessionId, TerminalId: p.TerminalId})
	c.mu.Lock()
	delete(c.terminals, p.TerminalId)
	c.mu.Unlock()
	return acp.ReleaseTerminalResponse{}, nil
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
var _ = json.Marshal
