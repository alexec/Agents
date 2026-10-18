// Package mac is what the Go agentsd needs of a Mac that Go cannot do by itself (#1138):
// the code signature of daemon.sock's callers, through the agents-peer helper, since the
// Security framework needs cgo, and a container cannot link it.
package mac

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
)

// Token is an audit token (audit_token_t): what the kernel keeps for the process on the
// other end of a connection, which a caller cannot forge. A pid can be reused; a pid with
// its version cannot, so a token names one process for as long as it runs.
type Token [8]uint32

// UID is the token's effective user id.
func (t Token) UID() uint32 { return t[1] }

// PID is the token's process id.
func (t Token) PID() int { return int(t[5]) }

// Hex is the token's 32 bytes, little-endian as the kernel lays them out, in hex: what
// agents-peer reads.
func (t Token) Hex() string {
	var b strings.Builder
	for _, v := range t {
		fmt.Fprintf(&b, "%02x%02x%02x%02x", byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
	}
	return b.String()
}

// The roles agents-peer answers (RolePolicy.signedRoles), and its answer for anything else.
const (
	RoleControl  = "control"
	RoleAgent    = "agent"
	RoleHostApp  = "hostApp"
	RoleWindow   = "window"
	RoleStranger = "stranger"
)

// maxCached bounds the answers kept: each helper call is a new process, so a long day
// would otherwise keep one per tool call. Past it the cache starts again.
const maxCached = 1024

// PeerChecker asks agents-peer for the role of each caller, once per audit token. The
// helper runs for as long as the checker is used: its first line says which team it is
// signed by, and then it answers one role per token it is sent.
type PeerChecker struct {
	helper string

	mu     sync.Mutex
	cmd    *exec.Cmd
	in     io.WriteCloser
	out    *bufio.Reader
	team   string
	cached map[Token]string
}

// NewPeerChecker is a checker that runs the helper at path when it is first needed.
func NewPeerChecker(path string) *PeerChecker {
	return &PeerChecker{helper: path, cached: map[Token]string{}}
}

// ErrUnsigned is Team's error when agents-peer is not signed by a team: then no caller's
// signature can be told apart from another's.
var ErrUnsigned = errors.New("agents-peer is not signed by a team")

// Team starts the helper, if it is not running, and says the team it is signed by.
func (p *PeerChecker) Team() (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if err := p.startLocked(); err != nil {
		return "", err
	}
	return p.team, nil
}

// Role is the role of the process with token t: one of the Role constants. An error
// means the helper could not answer; the caller is then a stranger.
func (p *PeerChecker) Role(t Token) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if r, ok := p.cached[t]; ok {
		return r, nil
	}
	if err := p.startLocked(); err != nil {
		return "", err
	}
	line, err := p.askLocked(t.Hex())
	if err != nil {
		p.stopLocked() // started again for the next caller
		return "", err
	}
	switch line {
	case RoleControl, RoleAgent, RoleHostApp, RoleWindow, RoleStranger:
	default:
		return "", fmt.Errorf("agents-peer answered %q", line)
	}
	if len(p.cached) >= maxCached {
		p.cached = map[Token]string{}
	}
	p.cached[t] = line
	return line, nil
}

// Close stops the helper.
func (p *PeerChecker) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.stopLocked()
}

func (p *PeerChecker) startLocked() error {
	if p.cmd != nil {
		return nil
	}
	cmd := exec.Command(p.helper)
	in, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("agents-peer: %w", err)
	}
	p.cmd, p.in, p.out = cmd, in, bufio.NewReader(out)
	first, err := p.readLocked()
	if err != nil {
		p.stopLocked()
		return fmt.Errorf("agents-peer said nothing: %w", err)
	}
	switch {
	case first == "unsigned":
		p.stopLocked()
		return ErrUnsigned
	case strings.HasPrefix(first, "team "):
		p.team = strings.TrimPrefix(first, "team ")
		return nil
	default:
		p.stopLocked()
		return fmt.Errorf("agents-peer began with %q", first)
	}
}

func (p *PeerChecker) askLocked(line string) (string, error) {
	if _, err := io.WriteString(p.in, line+"\n"); err != nil {
		return "", err
	}
	return p.readLocked()
}

func (p *PeerChecker) readLocked() (string, error) {
	line, err := p.out.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

func (p *PeerChecker) stopLocked() {
	if p.cmd == nil {
		return
	}
	p.in.Close()
	p.cmd.Process.Kill()
	p.cmd.Wait()
	p.cmd, p.in, p.out = nil, nil, nil
}
