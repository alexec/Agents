package codespacessh

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
