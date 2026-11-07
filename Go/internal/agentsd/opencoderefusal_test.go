package agentsd

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A refused OpenCode turn (#3736): its log's stream error for the session ends the turn.

const openCodeRefusalLine = `timestamp=2026-11-07T03:11:48.551Z level=ERROR run=598ba7f5 message="stream error" providerID=opencode modelID=big-pickle session.id=ses_e4c0 small=false agent=build mode=primary error.error="AI_APICallError: Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"`

func TestAnOpenCodeStreamErrorIsTheProvidersWords(t *testing.T) {
	said, ok := openCodeStreamError(openCodeRefusalLine, "ses_e4c0")
	want := "Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"
	if !ok || said != want {
		t.Fatalf("said %q, %v", said, ok)
	}
	if wordsLimit("opencode", nil, "", said) != limitSpent {
		t.Fatal("not a spent allowance")
	}
	for name, line := range map[string]string{
		"another session": openCodeRefusalLine,
		"its title":       `message="stream error" session.id=ses_e4c0 small=true agent=title error.error="AI_RetryError: Failed after 3 attempts"`,
		"not an error":    `level=INFO message="stream" session.id=ses_e4c0 small=false`,
	} {
		id := "ses_e4c0"
		if name == "another session" {
			id = "ses_e4c"
		}
		if said, ok := openCodeStreamError(line, id); ok {
			t.Errorf("%s: said %q", name, said)
		}
	}
}

func TestTheLogDirFollowsTheRuntimesEnvironment(t *testing.T) {
	env := map[string]string{"HOME": "/h"}
	get := func(k string) string { return env[k] }
	if got := openCodeLogDir(get); got != "/h/.local/share/opencode/log" {
		t.Fatalf("got %s", got)
	}
	env["XDG_DATA_HOME"] = "/x"
	if got := openCodeLogDir(get); got != "/x/opencode/log" {
		t.Fatalf("got %s", got)
	}
}

// Only what the log gained during the turn is read: an older refusal ends nothing.
func TestTheTailReadsOnlyNewWholeLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "opencode.log")
	writeLog(t, path, openCodeRefusalLine+"\n")
	tail := newOpenCodeLogTail(path)
	if got := tail.lines(); len(got) != 0 {
		t.Fatalf("read the old lines: %q", got)
	}
	appendLog(t, path, "one\ntw")
	if got := tail.lines(); len(got) != 1 || got[0] != "one" {
		t.Fatalf("got %q", got)
	}
	appendLog(t, path, "o\n")
	if got := tail.lines(); len(got) != 1 || got[0] != "two" {
		t.Fatalf("got %q", got)
	}
	// Started again, shorter: read from its start.
	writeLog(t, path, "three\n")
	if got := tail.lines(); len(got) != 1 || got[0] != "three" {
		t.Fatalf("got %q", got)
	}
}

func TestARefusalWithNoUpdateAfterItEndsTheTurn(t *testing.T) {
	quickRefusals(t)
	path := filepath.Join(t.TempDir(), "opencode.log")
	writeLog(t, path, "")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	got := make(chan string, 1)
	go watchOpenCodeRefusal(ctx, path, "ses_e4c0", func() time.Time { return time.Time{} }, func(s string) { got <- s })
	time.Sleep(20 * time.Millisecond)
	appendLog(t, path, openCodeRefusalLine+"\n")
	select {
	case said := <-got:
		if said == "" {
			t.Fatal("no words")
		}
	case <-ctx.Done():
		t.Fatal("the turn was not ended")
	}
}

// OpenCode retried by itself and went on: its update after the error keeps the turn.
func TestAnUpdateAfterTheRefusalKeepsTheTurn(t *testing.T) {
	quickRefusals(t)
	path := filepath.Join(t.TempDir(), "opencode.log")
	writeLog(t, path, "")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	got := make(chan string, 1)
	go watchOpenCodeRefusal(ctx, path, "ses_e4c0", time.Now, func(s string) { got <- s })
	time.Sleep(20 * time.Millisecond)
	appendLog(t, path, openCodeRefusalLine+"\n")
	select {
	case said := <-got:
		t.Fatalf("ended with %q", said)
	case <-ctx.Done():
	}
}

func quickRefusals(t *testing.T) {
	poll, grace := openCodeRefusalPoll, openCodeRefusalGrace
	openCodeRefusalPoll, openCodeRefusalGrace = 5*time.Millisecond, 30*time.Millisecond
	t.Cleanup(func() { openCodeRefusalPoll, openCodeRefusalGrace = poll, grace })
}

func writeLog(t *testing.T, path, s string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
}

func appendLog(t *testing.T, path, s string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(s); err != nil {
		t.Fatal(err)
	}
}
