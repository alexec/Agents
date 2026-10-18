package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// The test binary is agentsd itself when asked, for a host run as launchd runs it.
func TestMain(m *testing.M) {
	if os.Getenv("AGENTSD_TEST_RUN_MAIN") == "1" {
		os.Args = append([]string{"agentsd"}, strings.Fields(os.Getenv("AGENTSD_TEST_ARGS"))...)
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// /dev/null is a character device, not a terminal (#1388).
func TestDevNullIsNotATerminal(t *testing.T) {
	null, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer null.Close()
	if isTerminalFD(int(null.Fd())) {
		t.Fatal("/dev/null is taken for a terminal")
	}
	r, w, _ := os.Pipe()
	defer r.Close()
	defer w.Close()
	if isTerminalFD(int(w.Fd())) {
		t.Fatal("a pipe is taken for a terminal")
	}
}

// Run as launchd runs it, stdout and stderr on /dev/null, the host says it started in the
// root's daemon.log (#1388).
func TestAHostWithStdoutOnDevNullLogsToDaemonLog(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "ad1388-") // short: the socket's name is at most 104 bytes
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), "AGENTSD_TEST_RUN_MAIN=1", "AGENTSD_TEST_ARGS=--root "+root)
	// Nil is /dev/null, as launchd gives it.
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cmd.Process.Signal(os.Interrupt)
		done := make(chan struct{})
		go func() { cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			cmd.Process.Kill()
		}
	}()
	logFile := store.At(root).Log()
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		if b, _ := os.ReadFile(logFile); strings.Contains(string(b), "agentsd ") && strings.Contains(string(b), "root "+root) {
			return
		}
	}
	b, _ := os.ReadFile(logFile)
	t.Fatalf("no start line in %s: %q", logFile, b)
}
