package codespacessh

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestEachCodespaceHasABlockOfItsOwn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(path, []byte("Host mine\n  User me\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, step := range []struct{ label, config string }{
		{"", "Host cs.all.main\n  User codespace"},
		{"first", "Host cs.first.main\n  User codespace"},
		{"second", "Host cs.second.main\n  User vscode"},
		{"first", "Host cs.first.next\n  User node"},
	} {
		if err := Merge(path, step.label, []byte(step.config)); err != nil {
			t.Fatal(err)
		}
	}
	data, _ := os.ReadFile(path)
	text := string(data)
	for _, want := range []string{"Host mine", "Host cs.all.main", "Host cs.second.main", "Host cs.first.next"} {
		if !strings.Contains(text, want) {
			t.Errorf("no %q in\n%s", want, text)
		}
	}
	if strings.Contains(text, "cs.first.main") || strings.Count(text, Begin("first")+"\n") != 1 {
		t.Errorf("first's block not replaced:\n%s", text)
	}
	if !Has(path, "first", "cs.first.next") || Has(path, "first", "cs.second.main") || Has(path, "", "cs.first.next") {
		t.Errorf("Has is wrong for\n%s", text)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", info.Mode())
	}
}

// fakeGH is a gh that says what it was run with and writes a codespace's config.
func fakeGH(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	gh := filepath.Join(dir, "gh")
	if err := os.WriteFile(gh, []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	was := GH
	GH = gh
	t.Cleanup(func() { GH = was })
	return dir
}

func TestPrepareRunsGHWithTheTokenOnce(t *testing.T) {
	dir := fakeGH(t, `echo "$GH_TOKEN $GITHUB_TOKEN $*" >> "$(dirname "$0")/calls"
printf 'Host cs.%s.main\n\tUser codespace\n\tProxyCommand gh cs ssh -c %s --stdio\n' "$5" "$5"
`)
	path := filepath.Join(t.TempDir(), ".ssh", "config")
	env := []string{"PATH=/usr/bin:/bin", "GH_TOKEN=someone-elses", "GITHUB_TOKEN=also"}
	for range 2 {
		if err := Prepare(context.Background(), path, "fuzzy", "cs.fuzzy.main", "ghp_test", env); err != nil {
			t.Fatal(err)
		}
	}
	calls, _ := os.ReadFile(filepath.Join(dir, "calls"))
	if string(calls) != "ghp_test  codespace ssh --config -c fuzzy\n" {
		t.Errorf("calls %q", calls)
	}
	if !Has(path, "fuzzy", "cs.fuzzy.main") {
		data, _ := os.ReadFile(path)
		t.Errorf("no block in\n%s", data)
	}
}

func TestPrepareSaysWhatGHSaid(t *testing.T) {
	fakeGH(t, "echo 'HTTP 401: Bad credentials' >&2; exit 1\n")
	err := Prepare(context.Background(), filepath.Join(t.TempDir(), "config"), "fuzzy", "cs.fuzzy.main", "bad", nil)
	if err == nil || !strings.Contains(err.Error(), "Bad credentials") || !strings.Contains(err.Error(), "fuzzy") {
		t.Errorf("%v", err)
	}
}

func TestPrepareSaysThereIsNoGH(t *testing.T) {
	was := GH
	GH = filepath.Join(t.TempDir(), "no-gh")
	t.Cleanup(func() { GH = was })
	err := Prepare(context.Background(), filepath.Join(t.TempDir(), "config"), "fuzzy", "cs.fuzzy.main", "t", nil)
	if err == nil || !strings.Contains(err.Error(), "no GitHub CLI") {
		t.Errorf("%v", err)
	}
}

// A gh that Find finds is run, not the gh on PATH.
func TestPrepareRunsTheGHFindFinds(t *testing.T) {
	was := GH
	GH = filepath.Join(t.TempDir(), "no-gh")
	t.Cleanup(func() { GH = was })
	dir := t.TempDir()
	found := filepath.Join(dir, "gh")
	if err := os.WriteFile(found, []byte("#!/bin/sh\nprintf 'Host cs.fuzzy.main\\n\\tUser codespace\\n'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	Find = func() string { return found }
	t.Cleanup(func() { Find = nil })
	path := filepath.Join(t.TempDir(), "config")
	if err := Prepare(context.Background(), path, "fuzzy", "cs.fuzzy.main", "t", []string{"PATH=/usr/bin:/bin"}); err != nil {
		t.Fatal(err)
	}
	if !Has(path, "fuzzy", "cs.fuzzy.main") {
		t.Error("no block")
	}
}

// A deleted codespace's block goes, and every other line stays (#3746).
func TestRemoveTakesOutOnlyItsBlock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(path, []byte("Host mine\n  User me\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	for _, label := range []string{"", "first", "second"} {
		if err := Merge(path, label, []byte("Host cs."+label+".main\n  User codespace")); err != nil {
			t.Fatal(err)
		}
	}
	if removed, err := Remove(path, "first"); err != nil || !removed {
		t.Fatalf("%v %v", removed, err)
	}
	data, _ := os.ReadFile(path)
	text := string(data)
	if strings.Contains(text, "cs.first.main") || strings.Contains(text, Begin("first")) || strings.Contains(text, "\n\n\n") {
		t.Errorf("first's block is still here:\n%s", text)
	}
	if !strings.HasPrefix(text, "Host mine\n  User me\n") || !Has(path, "", "cs..main") || !Has(path, "second", "cs.second.main") {
		t.Errorf("another block went:\n%s", text)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o640 {
		t.Errorf("mode %v", info.Mode())
	}
	if removed, err := Remove(path, "first"); err != nil || removed {
		t.Fatalf("again: %v %v", removed, err)
	}
	if removed, err := Remove(filepath.Join(t.TempDir(), "none"), "first"); err != nil || removed {
		t.Fatalf("no file: %v %v", removed, err)
	}
	Remove(path, "")
	Remove(path, "second")
	if data, _ := os.ReadFile(path); string(data) != "Host mine\n  User me\n" {
		t.Errorf("the person's lines changed: %q", data)
	}
}

// KeepAwake holds gh's session with the provider's token alone, saying a line each
// KeepAwakeEvery, until it is cancelled (#4637).
func TestKeepAwakeHoldsASessionUntilCancelled(t *testing.T) {
	dir := fakeGH(t, `echo "$GH_TOKEN $GITHUB_TOKEN $*" >> "$(dirname "$0")/calls"
exec sleep 30
`)
	was := KeepAwakeEvery
	KeepAwakeEvery = 240 * time.Second
	t.Cleanup(func() { KeepAwakeEvery = was })
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- KeepAwake(ctx, "fuzzy", "ghp_test", []string{"PATH=/usr/bin:/bin", "GITHUB_TOKEN=other"})
	}()
	calls := filepath.Join(dir, "calls")
	for start := time.Now(); ; time.Sleep(10 * time.Millisecond) {
		if data, _ := os.ReadFile(calls); len(data) > 0 {
			break
		}
		if time.Since(start) > 5*time.Second {
			t.Fatal("gh never ran")
		}
	}
	select {
	case err := <-done:
		t.Fatalf("ended before it was cancelled: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("a cancelled session said %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("still running after cancel")
	}
	data, _ := os.ReadFile(calls)
	if want := "ghp_test  codespace ssh -c fuzzy -- while :; do echo keepalive; sleep 240; done\n"; string(data) != want {
		t.Errorf("calls %q", data)
	}
}

// A session that ends by itself says why, with gh's words.
func TestKeepAwakeSaysWhyTheSessionEnded(t *testing.T) {
	fakeGH(t, "echo 'codespace is not running' >&2; exit 1\n")
	err := KeepAwake(context.Background(), "fuzzy", "t", nil)
	if err == nil || !strings.Contains(err.Error(), "not running") || !strings.Contains(err.Error(), "fuzzy") {
		t.Errorf("%v", err)
	}
}
