package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"syscall"

	"github.com/creack/pty"
)

// shell is a person's terminal (ShellSession.swift): $SHELL -l on a pty, its output kept
// in a 4 MiB ring, each chunk numbered by its offset in everything it has printed.
type shell struct {
	agentID string
	number  int
	folder  string
	mu      sync.Mutex
	cmd     *exec.Cmd
	pty     *os.File
	buf     []byte
	dropped int
	started Date
	state   map[string]any
}

const scrollbackLimit = 4 << 20

type shellKey struct {
	agent  string
	number int
}

func liveState() map[string]any { return map[string]any{"live": map[string]any{}} }

func (d *Daemon) startShell(agentID string, number int, folder string, rows, cols int) (*shell, error) {
	if fi, err := os.Stat(folder); err != nil || !fi.IsDir() {
		return nil, &RPCError{Code: -32010, Message: "The folder this agent works in is not there any more: " + folder}
	}
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/bash"
	}
	cmd := exec.Command(sh, "-l")
	cmd.Dir = folder
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "TERM_PROGRAM=Agents")
	if rows <= 0 {
		rows = 24
	}
	if cols <= 0 {
		cols = 80
	}
	f, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)})
	if err != nil {
		return nil, &RPCError{Code: -32010, Message: "The shell would not start: " + err.Error()}
	}
	s := &shell{agentID: agentID, number: number, folder: folder, cmd: cmd, pty: f, started: Now(), state: liveState()}
	go s.pump(d)
	return s, nil
}

func (s *shell) pump(d *Daemon) {
	b := make([]byte, 32<<10)
	for {
		n, err := s.pty.Read(b)
		if n > 0 {
			// Appended and sent under one lock, so a replay ends where the next chunk starts.
			s.mu.Lock()
			offset := s.dropped + len(s.buf)
			s.buf = append(s.buf, b[:n]...)
			if over := len(s.buf) - scrollbackLimit; over > 0 {
				s.buf = append([]byte(nil), s.buf[over:]...)
				s.dropped += over
			}
			d.Broadcast("shell/output", map[string]any{"agentID": s.agentID, "shell": s.number, "bytes": b[:n], "offset": offset})
			s.mu.Unlock()
		}
		if err != nil {
			break
		}
	}
	err := s.cmd.Wait()
	status := 0
	if e, ok := err.(*exec.ExitError); ok {
		status = e.ExitCode()
	}
	s.mu.Lock()
	if _, released := s.state["released"]; !released {
		s.state = map[string]any{"exited": map[string]any{"status": status}}
	}
	state := s.state
	s.mu.Unlock()
	d.Broadcast("shell/stateChanged", map[string]any{"agentID": s.agentID, "shell": s.number, "state": state})
}

func (s *shell) isLive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.state["live"]
	return ok
}

func (s *shell) resize(rows, cols int) {
	if rows > 0 && cols > 0 {
		pty.Setsize(s.pty, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)})
	}
}

type shellRequest struct {
	AgentID   string `json:"agentID"`
	Shell     int    `json:"shell"`
	Rows      int    `json:"rows"`
	Cols      int    `json:"cols"`
	Folder    string `json:"folder"`
	Since     *int   `json:"since"`
	StartedAt *Date  `json:"startedAt"`
	Bytes     []byte `json:"bytes"`
}

// shellFolder: an agent's folder, or a project's for the project shell (Control-`), whose
// id the window makes from the folder and this host takes as given.
func (d *Daemon) shellFolder(r shellRequest) (string, error) {
	if a := d.store.Agent(r.AgentID); a != nil {
		return folderPath(a.Cwd), nil
	}
	if r.Folder != "" {
		for _, p := range d.store.Projects() {
			if folderPath(p.Folder) == folderPath(r.Folder) {
				return folderPath(p.Folder), nil
			}
		}
		return "", &RPCError{Code: -32005, Message: "There is no such project here."}
	}
	return "", &RPCError{Code: -32005, Message: "There is no such agent."}
}

func (d *Daemon) shellFor(agentID string, number int) *shell {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.shells[shellKey{strings.ToUpper(agentID), number}]
}

func (d *Daemon) keepShell(s *shell) {
	d.mu.Lock()
	if d.shells == nil {
		d.shells = map[shellKey]*shell{}
	}
	d.shells[shellKey{strings.ToUpper(s.agentID), s.number}] = s
	d.mu.Unlock()
}

func (s *shell) replay(since *int, startedAt *Date) map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]any{"state": s.state, "dropped": s.dropped, "startedAt": s.started, "folder": folderURL(s.folder)}
	end := s.dropped + len(s.buf)
	if since != nil && startedAt != nil && *startedAt == s.started && *since >= s.dropped && *since <= end {
		out["scrollback"] = append([]byte{}, s.buf[*since-s.dropped:]...)
		out["offset"] = *since
	} else {
		out["scrollback"] = append([]byte{}, s.buf...)
	}
	return out
}

func (d *Daemon) registerShells() {
	d.Handle("shell/attach", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[shellRequest](p)
		if err != nil {
			return nil, invalid(err)
		}
		if s := d.shellFor(r.AgentID, r.Shell); s != nil {
			return s.replay(r.Since, r.StartedAt), nil
		}
		folder, err := d.shellFolder(r)
		if err != nil {
			return nil, err
		}
		s, err := d.startShell(r.AgentID, r.Shell, folder, r.Rows, r.Cols)
		if err != nil {
			return nil, err
		}
		d.keepShell(s)
		return s.replay(nil, nil), nil
	})
	d.Handle("shell/restart", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[shellRequest](p)
		if err != nil {
			return nil, invalid(err)
		}
		if s := d.shellFor(r.AgentID, r.Shell); s != nil && s.isLive() {
			return nil, &RPCError{Code: -32011, Message: "That shell is still running."}
		}
		folder, err := d.shellFolder(r)
		if err != nil {
			return nil, err
		}
		s, err := d.startShell(r.AgentID, r.Shell, folder, r.Rows, r.Cols)
		if err != nil {
			return nil, err
		}
		d.keepShell(s)
		d.Broadcast("shell/stateChanged", map[string]any{"agentID": r.AgentID, "shell": r.Shell, "state": liveState()})
		return s.replay(nil, nil), nil
	})
	d.Handle("shell/open", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[shellRequest](p)
		if err != nil {
			return nil, invalid(err)
		}
		folder, err := d.shellFolder(r)
		if err != nil {
			return nil, err
		}
		n := 0
		for _, k := range d.shellNumbers(r.AgentID) {
			n = max(n, k)
		}
		s, err := d.startShell(r.AgentID, n+1, folder, r.Rows, r.Cols)
		if err != nil {
			return nil, err
		}
		d.keepShell(s)
		return map[string]any{"shell": n + 1}, nil
	})
	d.Handle("shell/list", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[shellRequest](p)
		ns := d.shellNumbers(r.AgentID)
		if len(ns) == 0 {
			ns = []int{0}
		}
		return map[string]any{"shells": ns}, nil
	})
	d.Handle("shell/input", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[shellRequest](p)
		if err != nil {
			return nil, invalid(err)
		}
		s := d.shellFor(r.AgentID, r.Shell)
		if s == nil || !s.isLive() {
			return nil, &RPCError{Code: -32011, Message: "That shell is not running."}
		}
		s.resize(r.Rows, r.Cols)
		if _, err := s.pty.Write(r.Bytes); err != nil {
			return nil, &RPCError{Code: -32011, Message: "That shell is not running."}
		}
		return empty(), nil
	})
	d.Handle("shell/resize", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[shellRequest](p)
		if s := d.shellFor(r.AgentID, r.Shell); s != nil {
			s.resize(r.Rows, r.Cols)
		}
		return empty(), nil
	})
	d.Handle("shell/detach", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) { return empty(), nil })
	d.Handle("shell/signal", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			AgentID string `json:"agentID"`
			Shell   int    `json:"shell"`
			Signal  int    `json:"signal"`
		}](p)
		if s := d.shellFor(r.AgentID, r.Shell); s != nil && s.cmd.Process != nil {
			syscall.Kill(-s.cmd.Process.Pid, syscall.Signal(r.Signal))
		}
		return empty(), nil
	})
	d.Handle("shell/close", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[shellRequest](p)
		s := d.shellFor(r.AgentID, r.Shell)
		if s == nil {
			return empty(), nil
		}
		s.mu.Lock()
		s.state = map[string]any{"released": map[string]any{"reason": "This shell was closed."}}
		s.mu.Unlock()
		if s.cmd.Process != nil {
			s.cmd.Process.Kill()
		}
		s.pty.Close()
		d.mu.Lock()
		delete(d.shells, shellKey{strings.ToUpper(r.AgentID), r.Shell})
		d.mu.Unlock()
		return empty(), nil
	})
}

func (d *Daemon) shellNumbers(agentID string) []int {
	d.mu.Lock()
	defer d.mu.Unlock()
	var ns []int
	for k := range d.shells {
		if k.agent == strings.ToUpper(agentID) {
			ns = append(ns, k.number)
		}
	}
	sort.Ints(ns)
	return ns
}

var _ = fmt.Sprintf
