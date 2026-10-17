package mac

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

// TestMain is also the stand-in for agents-mac: with AGENTS_MAC_FAKE set, it is the
// helper, and answers each descriptor it is handed with the socket's own name.
func TestMain(m *testing.M) {
	if os.Getenv("AGENTS_MAC_FAKE") != "" {
		fakeHelper()
		return
	}
	os.Exit(m.Run())
}

func fakeHelper() {
	// Answered on the socket it reads, as agents-mac does.
	say := func(format string, a ...any) { unix.Write(0, []byte(fmt.Sprintf(format, a...))) }
	say("team TEAMX\n")
	b, oob := make([]byte, 1), make([]byte, unix.CmsgSpace(4))
	for {
		_, oobn, _, _, err := unix.Recvmsg(0, b, oob, 0)
		if err != nil {
			os.Exit(0)
		}
		msgs, _ := unix.ParseSocketControlMessage(oob[:oobn])
		fds, _ := unix.ParseUnixRights(&msgs[0])
		sa, err := unix.Getsockname(fds[0])
		unix.Close(fds[0])
		if os.Getenv("AGENTS_MAC_FAKE") == "die" {
			os.Exit(1)
		}
		if un, ok := sa.(*unix.SockaddrUnix); ok && err == nil {
			say("signed %s\n", filepath.Base(un.Name))
		} else {
			say("stranger\n")
		}
	}
}

func listen(t *testing.T) (net.Listener, string) {
	t.Helper()
	dir, _ := os.MkdirTemp("/tmp", "peers")
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "d.sock")
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	return l, path
}

func TestThePeerIsAskedByItsDescriptor(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_MAC_FAKE", "1")
	p := &Peers{Helper: self}
	defer p.Close()
	if team, err := p.Team(); err != nil || team != "TEAMX" {
		t.Fatalf("team %q %v", team, err)
	}
	l, path := listen(t)
	for i := 0; i < 3; i++ {
		go func() {
			c, err := net.Dial("unix", path)
			if err == nil {
				defer c.Close()
				c.Read(make([]byte, 1))
			}
		}()
		c, err := l.Accept()
		if err != nil {
			t.Fatal(err)
		}
		a, err := p.Identify(c.(*net.UnixConn))
		c.Close()
		if err != nil || a.Identifier != "d.sock" || a.OtherUser {
			t.Fatalf("%d: %+v %v", i, a, err)
		}
	}
}

func TestAHelperThatDiesIsAnError(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_MAC_FAKE", "die")
	p := &Peers{Helper: self}
	defer p.Close()
	l, path := listen(t)
	go func() {
		if c, err := net.Dial("unix", path); err == nil {
			defer c.Close()
			c.Read(make([]byte, 1))
		}
	}()
	c, _ := l.Accept()
	defer c.Close()
	if _, err := p.Identify(c.(*net.UnixConn)); err == nil {
		t.Fatal("a helper that died answered")
	}
}

func TestParseAnswer(t *testing.T) {
	for line, want := range map[string]Answer{"other-user": {OtherUser: true}, "stranger": {}, "signed agentsd": {Identifier: "agentsd"}} {
		if a, err := parseAnswer(line); err != nil || a != want {
			t.Fatalf("%q: %+v %v", line, a, err)
		}
	}
	if _, err := parseAnswer("what"); err == nil {
		t.Fatal("nonsense was an answer")
	}
}
