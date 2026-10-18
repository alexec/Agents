package acp

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fakeRuntime is a script that counts its launches in <dir>/launches, says nothing on the
// launches before the answering one, and answers initialize on that one. stderr is what a
// silent launch writes there.
func fakeRuntime(t *testing.T, answering int, stderr string) (Launch, string) {
	t.Helper()
	dir := t.TempDir()
	count := filepath.Join(dir, "launches")
	script := `#!/bin/sh
n=$(($(cat "` + count + `" 2>/dev/null || echo 0) + 1))
echo $n > "` + count + `"
if [ $n -lt ` + strconv.Itoa(answering) + ` ]; then
  printf '%s' "` + stderr + `" >&2
  exec sleep 30
fi
read line
id=$(printf '%s' "$line" | sed 's/.*"id":\([0-9]*\).*/\1/')
printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id"
exec sleep 30
`
	exe := filepath.Join(dir, "runtime")
	if err := os.WriteFile(exe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return Launch{Command: exe, Dir: dir, Name: "Claude"}, count
}

func launches(t *testing.T, count string) string {
	t.Helper()
	b, _ := os.ReadFile(count)
	return strings.TrimSpace(string(b))
}

func shortWait(t *testing.T) {
	old := handshakeWait
	handshakeWait = time.Second
	t.Cleanup(func() { handshakeWait = old })
}

// A runtime that says nothing in time, as npx does while the registry is slow, is
// launched once more, and the second launch is the session (#1440).
func TestASilentRuntimeIsLaunchedOnceMore(t *testing.T) {
	shortWait(t)
	l, count := fakeRuntime(t, 2, "")
	s, err := Handshake(context.Background(), l, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	if n := launches(t, count); n != "2" {
		t.Fatalf("launched %s times", n)
	}
}

// Twice silent is a plain error, not the SDK's "context deadline exceeded".
func TestTwiceSilentSaysTheRuntimeDidNotAnswer(t *testing.T) {
	shortWait(t)
	l, count := fakeRuntime(t, 9, "")
	_, err := Handshake(context.Background(), l, nil)
	if !errors.Is(err, ErrNoAnswer) || err.Error() != "Claude did not answer in 1 s" {
		t.Fatalf("%v", err)
	}
	if n := launches(t, count); n != "2" {
		t.Fatalf("launched %s times", n)
	}
}

// A runtime that wrote something is not silent: it is not launched again, and what it
// wrote is in the error.
func TestARuntimeThatWroteIsNotLaunchedAgain(t *testing.T) {
	shortWait(t)
	l, count := fakeRuntime(t, 9, "no network")
	_, err := Handshake(context.Background(), l, nil)
	if !errors.Is(err, ErrNoAnswer) || !strings.HasSuffix(err.Error(), "\nno network") {
		t.Fatalf("%v", err)
	}
	if n := launches(t, count); n != "1" {
		t.Fatalf("launched %s times", n)
	}
}
