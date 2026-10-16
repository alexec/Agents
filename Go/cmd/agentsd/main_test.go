package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The flags the install script's systemd unit and its detached start pass.
func TestTheInstallScriptsFlags(t *testing.T) {
	cl := parse([]string{"--root", "/home/a/.agents-server/root", "--serve", "--control-network", "--host-name", "devbox (Go)"})
	if cl.root != "/home/a/.agents-server/root" || !cl.serve || !cl.controlNetwork() || cl.hostName != "devbox (Go)" || cl.detach {
		t.Fatalf("%+v", cl)
	}
	cl = parse([]string{"--root=/r", "--detach", "--control", "agents-control:2:h:x"})
	if cl.root != "/r" || !cl.detach || cl.code != "agents-control:2:h:x" || !cl.controlNetwork() {
		t.Fatalf("%+v", cl)
	}
}

func TestOneHostPerRoot(t *testing.T) {
	file := filepath.Join(t.TempDir(), "daemon.lock")
	a, err := takeLock(file)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if b, err := takeLock(file); err == nil {
		b.Close()
		t.Fatal("a second host took the lock")
	}
	if b, _ := os.ReadFile(file); len(b) < 2 {
		t.Fatalf("lock holds %q", b)
	}
}
