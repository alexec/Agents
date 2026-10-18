package agentsd

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// A bare command is found on the given PATH, not this process's (#1382): launchd starts
// agentsd with the system's folders only, where no node or npx is.
func TestLoginCommandFindsABareNameOnTheGivenPath(t *testing.T) {
	dir := t.TempDir()
	tool := filepath.Join(dir, "some-tool")
	if err := os.WriteFile(tool, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	env := []string{"HOME=/h", "PATH=/nowhere:" + dir}
	cmd := loginCommand(env, "some-tool", "a")
	if cmd.Path != tool {
		t.Fatalf("Path = %q, want %q", cmd.Path, tool)
	}
	if !slices.Equal(cmd.Env, env) {
		t.Fatalf("Env = %v, want %v", cmd.Env, env)
	}
	if got := loginCommand(env, "/bin/sh").Path; got != "/bin/sh" {
		t.Fatalf("a path stays as given, got %q", got)
	}
}

func TestLoginEnvironmentHasTheUsualFolders(t *testing.T) {
	for _, kv := range loginEnvironment() {
		if dirs, ok := strings.CutPrefix(kv, "PATH="); ok {
			for _, want := range []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"} {
				if !slices.Contains(strings.Split(dirs, ":"), want) {
					t.Fatalf("PATH %s has no %s", dirs, want)
				}
			}
			return
		}
	}
	t.Fatal("no PATH")
}
