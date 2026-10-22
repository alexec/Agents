package main

import (
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/rolllog"
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

// launchd starts the Mac's host with /dev/null for stdout: not a terminal, so the log goes
// to the root's daemon.log (#1392).
func TestDevNullIsNotATerminal(t *testing.T) {
	null, err := os.Stat(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	if isTerminalFile(null) {
		t.Fatal("/dev/null counted as a terminal")
	}
	file, err := os.Stat("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if isTerminalFile(file) {
		t.Fatal("a file counted as a terminal")
	}
}

// A log line with a token in it goes to daemon.log redacted (#1001, SC-001).
func TestALogLineIsRedacted(t *testing.T) {
	file := filepath.Join(t.TempDir(), "daemon.log")
	f, err := rolllog.Open(file, rolllog.Limit, false)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	defer setLog(os.Stderr)
	setLog(f)
	token := "ghp_" + strings.Repeat("a1B2", 9)
	log.Printf("clone failed: https://x-access-token:%s@github.com/o/r", token)
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), token) || !strings.Contains(string(b), "x-access-token:[redacted:github]@github.com") {
		t.Fatalf("daemon.log: %q", b)
	}
}
