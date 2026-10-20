package hosttunnels

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// connecting is HostTunnels.connecting: how long a master has to come up. ssh's own
// ConnectTimeout does not cover a ProxyCommand or a chain of jumps.
var connecting = 60 * time.Second

// session is HostTunnels.session: one tunnel session, until it ends or ctx is done.
// It returns why it ended.
//
// It is a master of its own with no forwards. Then our one forward is asked of it
// (#610): the master's ClearAllForwardings would drop a -R on its own command line. A
// forward the server refuses ends the session with ssh's words for it.
func session(ctx context.Context, record Record, base sshCommand, folder string, up func()) string {
	ssh := base
	ssh.options = join(base.options, sayErrors)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return "its folder could not be made: " + err.Error()
	}
	if record.KnownHosts == "" {
		ssh.options = join(ssh.options, personsKnownHosts(ctx, ssh), []string{"-o", "StrictHostKeyChecking=yes"})
	} else {
		knownHosts := filepath.Join(folder, record.ID+".known_hosts")
		if err := writeAtomically(knownHosts, []byte(Pinned(record.KnownHosts))); err != nil {
			return "its known hosts file could not be written: " + err.Error()
		}
		ssh.options = join(ssh.options, []string{"-o", "UserKnownHostsFile=" + knownHosts,
			"-o", "GlobalKnownHostsFile=/dev/null", "-o", "HostKeyAlias=" + PinnedAlias,
			"-o", "StrictHostKeyChecking=yes"})
	}
	id := record.ID
	if len(id) > 8 {
		id = id[:8]
	}
	control := filepath.Join(folder, id+".ctl")
	os.Remove(control)
	defer os.Remove(control)

	errorsRead, errorsWrite, err := os.Pipe()
	if err != nil {
		return "ssh could not be started: " + err.Error()
	}
	defer errorsRead.Close()
	cmd := exec.Command(ssh.executable, ssh.tunnelMasterArguments(control)...)
	cmd.Env = ssh.env
	cmd.Stderr = errorsWrite
	if err := cmd.Start(); err != nil {
		errorsWrite.Close()
		return "ssh could not be started: " + err.Error()
	}
	errorsWrite.Close()
	master := &master{cmd: cmd, exited: make(chan struct{})}
	go func() {
		cmd.Wait()
		master.ended.Store(true)
		close(master.exited)
	}()
	heard := &sessionLines{}
	closed := make(chan struct{})
	go func() {
		defer close(closed)
		buffer := make([]byte, 4096)
		for {
			n, err := errorsRead.Read(buffer)
			if n > 0 {
				heard.take(buffer[:n])
			}
			if err != nil {
				return
			}
		}
	}()
	forwardCtx, cancelForward := context.WithCancel(context.Background())
	defer cancelForward()
	forwarded := make(chan *string, 1)
	go func() { forwarded <- forward(forwardCtx, record, ssh, control, master, up) }()

	// ssh can exit before its last words are read. The session ends when it has exited
	// and its standard error is closed, or a moment after it exits if a child of its own
	// still holds that open.
	done, exited, closing := ctx.Done(), master.exited, closed
	var grace <-chan time.Time
	hasExited, isClosed := false, false
	for !(hasExited && isClosed) {
		select {
		case <-done:
			done = nil
			master.terminate()
			cancelForward()
		case <-exited:
			exited, hasExited = nil, true
			grace = time.After(time.Second)
		case <-closing:
			closing, isClosed = nil, true
		case <-grace:
			isClosed = true
		}
	}
	ended := "the ssh session ended"
	if problem := heard.problem(); problem != "" {
		ended = problem
	}
	cancelForward()
	if why := <-forwarded; why != nil {
		return *why
	}
	return ended
}

// PinnedAlias is the name a pinned key is kept under (ssh's HostKeyAlias): the known
// hosts file holds only the one server's keys, so the key is checked whatever address
// the server has now (#1691).
const PinnedAlias = "agents-pinned-host"

// Pinned is known_hosts lines with each one's host names written as PinnedAlias. A
// marker (@cert-authority, @revoked) stays before them.
func Pinned(knownHosts string) string {
	var out []string
	for _, line := range strings.Split(knownHosts, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		names := 0
		if strings.HasPrefix(fields[0], "@") {
			names = 1
		}
		if len(fields) <= names+1 {
			continue
		}
		fields[names] = PinnedAlias
		out = append(out, strings.Join(fields, " "))
	}
	if len(out) == 0 {
		return ""
	}
	return strings.Join(out, "\n") + "\n"
}

// master is the session's ssh: ended is set once it has exited.
type master struct {
	cmd    *exec.Cmd
	exited chan struct{}
	ended  atomic.Bool
}

// terminate is Process.terminate: SIGTERM, if it still runs.
func (m *master) terminate() {
	if !m.ended.Load() {
		m.cmd.Process.Signal(syscall.SIGTERM)
	}
}

// forward is HostTunnels.forward: once the master answers, it asks the master for the
// tunnel's forward. It returns why the session must end, or nil when the forward is
// open or the master ended by itself.
func forward(ctx context.Context, record Record, ssh sshCommand, control string, master *master, up func()) *string {
	deadline := time.Now().Add(connecting)
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(500 * time.Millisecond):
		}
		if master.ended.Load() {
			return nil
		}
		if check, err := ssh.run(ctx, ssh.tunnelControlArguments(control, "check")); err == nil && check.status == 0 {
			break
		}
		if master.ended.Load() || ctx.Err() != nil {
			return nil
		}
		if time.Now().After(deadline) {
			master.terminate()
			why := fmt.Sprintf("ssh did not connect within %d seconds", int(connecting/time.Second))
			return &why
		}
	}
	asked, err := ssh.run(ctx, ssh.tunnelForwardArguments(control, record.Port, record.Port))
	if err == nil && asked.status == 0 {
		up()
		return nil
	}
	// A master that ended meanwhile has its own reason.
	if master.ended.Load() {
		return nil
	}
	master.terminate()
	why := forwardFailure(asked.stderr)
	return &why
}

// forwardFailure is HostTunnels.forwardFailure: ssh's reason for a forward its master
// would not open, as in "mux_client_forward: forwarding request failed: remote port
// forwarding failed for listen port 8791".
func forwardFailure(stderr string) string {
	const failed = "forwarding request failed: "
	var all []string
	for _, line := range lines(stderr) {
		all = append(all, strings.TrimSpace(line))
	}
	for _, line := range all {
		if _, after, ok := strings.Cut(line, failed); ok {
			return after
		}
	}
	for i := len(all) - 1; i >= 0; i-- {
		if said, ok := said(all[i]); ok {
			return said
		}
	}
	return "the server would not open the tunnel's forward"
}

// sessionLines is HostTunnels.SessionLines: what ssh says on standard error, a line at
// a time. The last line that is not debug chatter is why it ended.
type sessionLines struct {
	mu      sync.Mutex
	partial []byte
	last    string
}

func (s *sessionLines) problem() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.last
}

func (s *sessionLines) take(data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.partial = append(s.partial, data...)
	for {
		newline := strings.IndexByte(string(s.partial), '\n')
		if newline < 0 {
			return
		}
		line := strings.TrimSpace(string(s.partial[:newline]))
		s.partial = s.partial[newline+1:]
		if said, ok := said(line); ok {
			s.last = said
		}
	}
}

// said is SessionLines.said: a line worth showing, ssh's own warnings and errors, not
// its debug output.
func said(line string) (string, bool) {
	if line == "" {
		return "", false
	}
	for _, chatter := range []string{"debug", "OpenSSH_", "Authenticated to", "Transferred:", "Bytes per second"} {
		if strings.HasPrefix(line, chatter) {
			return "", false
		}
	}
	return strings.TrimPrefix(line, "Warning: "), true
}

// writeAtomically is Data.write(to:options: .atomic).
func writeAtomically(path string, data []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".known_hosts-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), path)
}
