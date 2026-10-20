package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

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
