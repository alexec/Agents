package mac

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The kernel names the process on the other end: this one, dialling itself.
func TestPeerTokenIsTheCaller(t *testing.T) {
	dir, _ := os.MkdirTemp("", "peer")
	defer os.RemoveAll(dir)
	ln, err := net.Listen("unix", filepath.Join(dir, "s"))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := net.Dial("unix", filepath.Join(dir, "s"))
		if err == nil {
			time.Sleep(time.Second)
			c.Close()
		}
	}()
	c, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	tok, err := PeerToken(c)
	if err != nil {
		t.Fatal(err)
	}
	if int(tok.UID()) != os.Geteuid() || tok.PID() != os.Getpid() {
		t.Fatalf("token uid %d pid %d, want %d %d", tok.UID(), tok.PID(), os.Geteuid(), os.Getpid())
	}
}
