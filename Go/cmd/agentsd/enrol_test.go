package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd"
	"github.com/alexec/agents/Go/internal/controllink"
)

func hostCode(t *testing.T, n byte) string {
	t.Helper()
	c := &controllink.Code{Host: true, ControlKey: bytes.Repeat([]byte{4}, 65), Secret: bytes.Repeat([]byte{n}, 32),
		URL: "https://127.0.0.1:1", Name: "cp"}
	return c.Text()
}

// #1770: a code the control plane refused for good is said once, not tried again every
// 5 s; the host waits for a new code in its file and enrols with it.
func TestARefusedCodeWaitsForANewOne(t *testing.T) {
	was := enrolEvery
	enrolEvery = 20 * time.Millisecond
	t.Cleanup(func() { enrolEvery = was })
	var logged syncBuffer
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	old, fresh := hostCode(t, 1), hostCode(t, 2)
	file := filepath.Join(t.TempDir(), "control-join-code")
	var mu sync.Mutex
	tries := map[string]int{}
	try := func(_ context.Context, c *controllink.Code) (*controllink.Membership, error) {
		mu.Lock()
		defer mu.Unlock()
		tries[c.Text()]++
		if c.Text() == old {
			return nil, fmt.Errorf("enrol: %w", controllink.Refuse(controllink.Expired))
		}
		return &controllink.Membership{Host: "h1"}, nil
	}
	done := make(chan *controllink.Membership, 1)
	go func() { done <- enrol(context.Background(), old, file, try) }()
	time.Sleep(200 * time.Millisecond)
	mu.Lock()
	if tries[old] != 1 {
		t.Errorf("the refused code was tried %d times", tries[old])
	}
	mu.Unlock()
	if n := strings.Count(logged.String(), "refused the host code (expired)"); n != 1 {
		t.Errorf("said %d times:\n%s", n, logged.String())
	}
	if err := os.WriteFile(file, []byte(fresh+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case m := <-done:
		if m == nil || m.Host != "h1" {
			t.Fatalf("%+v", m)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the new code was not taken")
	}
}

// A control plane that does not answer is tried again, and ctx ends the wait.
func TestAnUnansweredEnrolIsTriedAgain(t *testing.T) {
	was := enrolEvery
	enrolEvery = 10 * time.Millisecond
	t.Cleanup(func() { enrolEvery = was })
	log.SetOutput(&syncBuffer{})
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	ctx, cancel := context.WithCancel(context.Background())
	var mu sync.Mutex
	n := 0
	try := func(context.Context, *controllink.Code) (*controllink.Membership, error) {
		mu.Lock()
		defer mu.Unlock()
		if n++; n == 3 {
			cancel()
		}
		return nil, errors.New("127.0.0.1:1 took the connection but did not answer within 10s")
	}
	if m := enrol(ctx, hostCode(t, 1), filepath.Join(t.TempDir(), "code"), try); m != nil {
		t.Fatalf("%+v", m)
	}
	if n < 3 {
		t.Fatalf("tried %d times", n)
	}
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// #1996: the uplink's problem goes to control-join.json, as HostJoinFile reads it, so
// Agents Host and the control plane beside it show it.
func TestTheJoinStatusSaysTheProblem(t *testing.T) {
	root := t.TempDir()
	writeJoinStatus(root, false, "it does not take this host's key")
	data, err := os.ReadFile(filepath.Join(root, joinStatusFile))
	if err != nil {
		t.Fatal(err)
	}
	var read struct {
		PID    int `json:"pid"`
		Status struct {
			Member, Connected bool
			Problem           *string
			At                string
		}
	}
	if err := json.Unmarshal(data, &read); err != nil || read.PID != os.Getpid() || !read.Status.Member || read.Status.Connected ||
		read.Status.Problem == nil || *read.Status.Problem != "it does not take this host's key" {
		t.Fatalf("%s", data)
	}
	if _, err := time.Parse(time.RFC3339, read.Status.At); err != nil || strings.Contains(read.Status.At, ".") {
		t.Fatalf("%s", read.Status.At)
	}
	writeJoinStatus(root, true, "")
	data, _ = os.ReadFile(filepath.Join(root, joinStatusFile))
	if strings.Contains(string(data), "problem") {
		t.Fatalf("%s", data)
	}
}

// #998, US7 AS2: a code for another control plane than the pinned one is refused for good,
// said once with the control plane required, and the host waits for a new code.
func TestACodeForAnotherControlPlaneIsRefused(t *testing.T) {
	pin := agentsd.PinFromFlags("control.acme.dev", "", true)
	c, err := controllink.ParseCode(hostCode(t, 1))
	if err != nil {
		t.Fatal(err)
	}
	refusal := pin.Admits(c.ControlKey, c.URL)
	why, forGood := refusedForGood(fmt.Errorf("enrol: %w", refusal))
	if !forGood || !strings.Contains(why, "control.acme.dev") {
		t.Fatalf("%q %v", why, forGood)
	}
	cl := parse([]string{"--root", t.TempDir(), "--pin-address", "control.acme.dev", "--pin-key=abc", "--must-join"})
	if cl.pinAddress != "control.acme.dev" || cl.pinKey != "abc" || !cl.mustJoin {
		t.Fatalf("%+v", cl)
	}
}
