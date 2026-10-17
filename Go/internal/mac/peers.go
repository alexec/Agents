// Package mac is what the Go agentsd asks of macOS that Go cannot do without cgo, through
// agents-mac, a small Swift helper Agents Host carries beside it (#1138).
package mac

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// Peers names the code on the other end of a daemon.sock connection, by its audit token,
// which a caller cannot forge (CallerSignature.swift). Each connection's descriptor is
// handed to `agents-mac peers` over a socket pair; the helper reads the token itself and
// says the code's signing identifier when it is signed through Apple by the helper's own
// team, which is this host's. One helper serves every connection, one at a time.
type Peers struct {
	// Helper is agents-mac's path.
	Helper string

	mu   sync.Mutex
	cmd  *exec.Cmd
	conn *net.UnixConn
	r    *bufio.Reader
	team string
}

// Answer is what the helper says of one caller.
type Answer struct {
	// OtherUser is a process of another account: closed unanswered.
	OtherUser bool
	// Identifier is the caller's signing identifier, when it is signed by this team; empty
	// for anything else (a stranger).
	Identifier string
}

// Team starts the helper if it is not running and says the team it is signed by: empty
// when it is not signed by one (a development build, `swift build`), as
// CallerSignature.ownTeam.
func (p *Peers) Team() (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if err := p.start(); err != nil {
		return "", err
	}
	return p.team, nil
}

// Identify asks who is on the other end of c. An error is a helper that would not answer:
// the caller then gets the least, a stranger.
func (p *Peers) Identify(c *net.UnixConn) (Answer, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return Answer{}, err
	}
	var fd int
	var dupErr error
	if err := raw.Control(func(f uintptr) { fd, dupErr = unix.Dup(int(f)) }); err != nil {
		return Answer{}, err
	}
	if dupErr != nil {
		return Answer{}, dupErr
	}
	defer unix.Close(fd)
	p.mu.Lock()
	defer p.mu.Unlock()
	for attempt := 0; ; attempt++ {
		a, err := p.ask(fd)
		if err == nil || attempt == 1 {
			return a, err
		}
		// A helper that went away is started again, once.
		p.stop()
	}
}

func (p *Peers) ask(fd int) (Answer, error) {
	if err := p.start(); err != nil {
		return Answer{}, err
	}
	p.conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, _, err := p.conn.WriteMsgUnix([]byte{'?'}, unix.UnixRights(fd), nil); err != nil {
		return Answer{}, err
	}
	line, err := p.r.ReadString('\n')
	if err != nil {
		return Answer{}, err
	}
	return parseAnswer(strings.TrimSuffix(line, "\n"))
}

func parseAnswer(line string) (Answer, error) {
	switch {
	case line == "other-user":
		return Answer{OtherUser: true}, nil
	case line == "stranger":
		return Answer{}, nil
	case strings.HasPrefix(line, "signed "):
		return Answer{Identifier: strings.TrimPrefix(line, "signed ")}, nil
	}
	return Answer{}, fmt.Errorf("agents-mac said %q", line)
}

func (p *Peers) start() error {
	if p.cmd != nil {
		return nil
	}
	if p.Helper == "" {
		return errors.New("no agents-mac")
	}
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		return err
	}
	unix.CloseOnExec(fds[0])
	ours := os.NewFile(uintptr(fds[0]), "agents-mac")
	theirs := os.NewFile(uintptr(fds[1]), "agents-mac peers")
	cmd := exec.Command(p.Helper, "peers")
	cmd.Stdin, cmd.Stderr = theirs, os.Stderr
	if err := cmd.Start(); err != nil {
		ours.Close()
		theirs.Close()
		return err
	}
	theirs.Close()
	fc, err := net.FileConn(ours)
	ours.Close()
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		return err
	}
	p.cmd, p.conn, p.r = cmd, fc.(*net.UnixConn), bufio.NewReader(fc)
	// Its first line is its team: "team <id>", or "team -" when it is not signed by one.
	p.conn.SetDeadline(time.Now().Add(5 * time.Second))
	line, err := p.r.ReadString('\n')
	if err != nil || !strings.HasPrefix(line, "team ") {
		p.stop()
		return fmt.Errorf("agents-mac did not say its team: %q %v", line, err)
	}
	p.team = strings.TrimSpace(strings.TrimPrefix(line, "team "))
	if p.team == "-" {
		p.team = ""
	}
	return nil
}

func (p *Peers) stop() {
	if p.cmd == nil {
		return
	}
	p.conn.Close()
	p.cmd.Process.Kill()
	p.cmd.Wait()
	p.cmd, p.conn, p.r = nil, nil, nil
}

// Close stops the helper.
func (p *Peers) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.stop()
}
