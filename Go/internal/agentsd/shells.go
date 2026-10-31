package agentsd

import (
	"context"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"syscall"

	"github.com/creack/pty"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// shell is a person's terminal (ShellSession.swift): $SHELL -l on a pty, its output kept
// in a 4 MiB ring, each chunk numbered by its offset in everything it has printed.
type shell struct {
	agentID wire.UUID
	number  int64
	folder  string
	mu      sync.Mutex
	cmd     *exec.Cmd
	pty     *os.File
	buf     []byte
	dropped int64
	started wire.Date
	state   wire.ShellState
}

const scrollbackLimit = 4 << 20

type shellKey struct {
	agent  wire.UUID
	number int64
}

func key(agentID wire.UUID, number int64) shellKey {
	return shellKey{wire.UUID(strings.ToUpper(string(agentID))), number}
}

func liveState() wire.ShellState { return wire.ShellState{Live: &struct{}{}} }

// number is a request's shell, 0 when it names none, as Swift's decoder reads it.
func number(n *int64) int64 {
	if n == nil {
		return 0
	}
	return *n
}

func or(n *int64, otherwise int64) int64 {
	if n == nil || *n <= 0 {
		return otherwise
	}
	return *n
}

func (d *Daemon) startShell(agentID wire.UUID, number int64, folder string, rows, cols int64) (*shell, error) {
	if fi, err := os.Stat(folder); err != nil || !fi.IsDir() {
		return nil, &Error{Code: wire.FailureShellWillNotStart, Message: "The folder this agent works in is not there any more: " + folder}
	}
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/bash"
	}
	cmd := exec.Command(sh, "-l")
	cmd.Dir = folder
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "TERM_PROGRAM=Agents")
	f, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)})
	if err != nil {
		return nil, &Error{Code: wire.FailureShellWillNotStart, Message: "The shell would not start: " + err.Error()}
	}
	s := &shell{agentID: agentID, number: number, folder: folder, cmd: cmd, pty: f, started: now(), state: liveState()}
	safe.Go("shell pump", func() { s.pump(d) })
	return s, nil
}

func (s *shell) pump(d *Daemon) {
	b := make([]byte, 32<<10)
	for {
		n, err := s.pty.Read(b)
		if n > 0 {
			// Appended and sent under one lock, so a replay ends where the next chunk starts.
			s.mu.Lock()
			offset := s.dropped + int64(len(s.buf))
			s.buf = append(s.buf, b[:n]...)
			if over := len(s.buf) - scrollbackLimit; over > 0 {
				s.buf = append([]byte(nil), s.buf[over:]...)
				s.dropped += int64(over)
			}
			Broadcast(d, wire.NotifyShellOutput, wire.ShellOutputNotification{
				AgentID: s.agentID, Shell: s.number, Bytes: wire.Data(b[:n]), Offset: &offset})
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
	if s.state.Released == nil {
		s.state = wire.ShellState{Exited: &wire.ShellStateExited{Status: int64(status)}}
	}
	state := s.state
	s.mu.Unlock()
	Broadcast(d, wire.NotifyShellStateChanged, wire.ShellStateNotification{AgentID: s.agentID, Shell: s.number, State: state})
}

func (s *shell) isLive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state.Live != nil
}

func (s *shell) resize(rows, cols *int64) {
	if rows != nil && cols != nil && *rows > 0 && *cols > 0 {
		pty.Setsize(s.pty, &pty.Winsize{Rows: uint16(*rows), Cols: uint16(*cols)})
	}
}

// shellFolder: an agent's folder, or a folder's for the folder shell (Control-`), whose
// id the window makes from the folder and this host takes as given.
func (d *Daemon) shellFolder(r wire.ShellAttachRequest) (string, error) {
	if a := d.Store.Agent(wire.UUID(strings.ToUpper(string(r.AgentID)))); a != nil {
		return store.FolderPath(a.Cwd), nil
	}
	if r.Folder != nil && *r.Folder != "" {
		for _, p := range d.Store.Folders() {
			if store.FolderPath(p.Folder) == store.FolderPath(*r.Folder) {
				return store.FolderPath(p.Folder), nil
			}
		}
		return "", &Error{Code: -32005, Message: "There is no such folder here."}
	}
	return "", &Error{Code: -32005, Message: "There is no such agent."}
}

func (d *Daemon) shellFor(agentID wire.UUID, number int64) *shell {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.shells[key(agentID, number)]
}

func (d *Daemon) keepShell(s *shell) {
	d.mu.Lock()
	d.shells[key(s.agentID, s.number)] = s
	d.mu.Unlock()
}

func (s *shell) replay(since *int64, startedAt *wire.Date) wire.ShellAttachResponse {
	s.mu.Lock()
	defer s.mu.Unlock()
	folder := fileURL(s.folder, true)
	out := wire.ShellAttachResponse{State: s.state, Dropped: s.dropped, StartedAt: s.started, Folder: &folder}
	end := s.dropped + int64(len(s.buf))
	if since != nil && startedAt != nil && *startedAt == s.started && *since >= s.dropped && *since <= end {
		out.Scrollback = append(wire.Data{}, s.buf[*since-s.dropped:]...)
		offset := *since
		out.Offset = &offset
	} else {
		out.Scrollback = append(wire.Data{}, s.buf...)
	}
	return out
}

func (d *Daemon) openShell(r wire.ShellAttachRequest, number int64) (*shell, error) {
	// A machine that must join its control plane, and has not, opens no shell (#998, FR-028).
	if err := d.pinRefusal(); err != nil {
		return nil, err
	}
	folder, err := d.shellFolder(r)
	if err != nil {
		return nil, err
	}
	s, err := d.startShell(r.AgentID, number, folder, or(r.Rows, 24), or(r.Cols, 80))
	if err != nil {
		return nil, err
	}
	d.keepShell(s)
	return s, nil
}

func (d *Daemon) registerShells() {
	On(d, wire.CallShellAttach, func(ctx context.Context, c *Client, r wire.ShellAttachRequest) (wire.ShellAttachResponse, error) {
		if s := d.shellFor(r.AgentID, number(r.Shell)); s != nil {
			return s.replay(r.Since, r.StartedAt), nil
		}
		s, err := d.openShell(r, number(r.Shell))
		if err != nil {
			return wire.ShellAttachResponse{}, err
		}
		return s.replay(nil, nil), nil
	})
	On(d, wire.CallShellRestart, func(ctx context.Context, c *Client, r wire.ShellAttachRequest) (wire.ShellAttachResponse, error) {
		if s := d.shellFor(r.AgentID, number(r.Shell)); s != nil && s.isLive() {
			return wire.ShellAttachResponse{}, &Error{Code: wire.FailureShellNotLive, Message: "That shell is still running."}
		}
		s, err := d.openShell(r, number(r.Shell))
		if err != nil {
			return wire.ShellAttachResponse{}, err
		}
		Broadcast(d, wire.NotifyShellStateChanged, wire.ShellStateNotification{AgentID: r.AgentID, Shell: number(r.Shell), State: liveState()})
		return s.replay(nil, nil), nil
	})
	On(d, wire.CallShellOpen, func(ctx context.Context, c *Client, r wire.ShellAttachRequest) (wire.ShellOpenResponse, error) {
		var n int64
		for _, k := range d.shellNumbers(r.AgentID) {
			n = max(n, k)
		}
		if _, err := d.openShell(r, n+1); err != nil {
			return wire.ShellOpenResponse{}, err
		}
		return wire.ShellOpenResponse{Shell: n + 1}, nil
	})
	On(d, wire.CallShellList, func(ctx context.Context, c *Client, r wire.AgentRequest) (wire.ShellListResponse, error) {
		ns := d.shellNumbers(r.AgentID)
		if len(ns) == 0 {
			ns = []int64{0}
		}
		return wire.ShellListResponse{Shells: ns}, nil
	})
	On(d, wire.CallShellInput, func(ctx context.Context, c *Client, r wire.ShellInputRequest) (wire.Empty, error) {
		s := d.shellFor(r.AgentID, number(r.Shell))
		if s == nil || !s.isLive() {
			return wire.Empty{}, &Error{Code: wire.FailureShellNotLive, Message: "That shell is not running."}
		}
		s.resize(r.Rows, r.Cols)
		if _, err := s.pty.Write(r.Bytes); err != nil {
			return wire.Empty{}, &Error{Code: wire.FailureShellNotLive, Message: "That shell is not running."}
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallShellResize, func(ctx context.Context, c *Client, r wire.ShellResizeRequest) (wire.Empty, error) {
		if s := d.shellFor(r.AgentID, number(r.Shell)); s != nil {
			s.resize(&r.Rows, &r.Cols)
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallShellDetach, func(ctx context.Context, c *Client, r wire.ShellRequest) (wire.Empty, error) {
		return wire.Empty{}, nil
	})
	On(d, wire.CallShellSignal, func(ctx context.Context, c *Client, r wire.ShellSignalRequest) (wire.Empty, error) {
		if s := d.shellFor(r.AgentID, number(r.Shell)); s != nil && s.cmd.Process != nil {
			syscall.Kill(-s.cmd.Process.Pid, syscall.Signal(r.Signal))
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallShellClose, func(ctx context.Context, c *Client, r wire.ShellRequest) (wire.Empty, error) {
		s := d.shellFor(r.AgentID, number(r.Shell))
		if s == nil {
			return wire.Empty{}, nil
		}
		s.mu.Lock()
		s.state = wire.ShellState{Released: &wire.ShellStateReleased{Reason: "This shell was closed."}}
		s.mu.Unlock()
		if s.cmd.Process != nil {
			s.cmd.Process.Kill()
		}
		s.pty.Close()
		d.mu.Lock()
		delete(d.shells, key(r.AgentID, number(r.Shell)))
		d.mu.Unlock()
		return wire.Empty{}, nil
	})
}

func (d *Daemon) shellNumbers(agentID wire.UUID) []int64 {
	d.mu.Lock()
	defer d.mu.Unlock()
	var ns []int64
	for k := range d.shells {
		if k.agent == key(agentID, 0).agent {
			ns = append(ns, k.number)
		}
	}
	slices.Sort(ns)
	return ns
}

// stopShells ends every terminal, as the host stops.
func (d *Daemon) stopShells() {
	d.mu.Lock()
	ss := make([]*shell, 0, len(d.shells))
	for _, s := range d.shells {
		ss = append(ss, s)
	}
	d.mu.Unlock()
	for _, s := range ss {
		if s.cmd.Process != nil {
			syscall.Kill(-s.cmd.Process.Pid, syscall.SIGHUP)
		}
	}
}
