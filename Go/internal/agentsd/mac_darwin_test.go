package agentsd

import (
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

// Finder, other apps and Terminal are /usr/bin/open's, asked by the window.
func TestTheMacsVerbsAreOpen(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	said := filepath.Join(dir, "said")
	fake := filepath.Join(dir, "open")
	os.WriteFile(fake, []byte("#!/bin/sh\necho \"$@\" >> "+said+"\n"), 0o755)
	macOpenCommand = fake
	defer func() { macOpenCommand = "/usr/bin/open" }()

	c.call(t, 1, "mac/reveal", map[string]any{"path": dir})
	c.call(t, 2, "mac/open", map[string]any{"path": dir, "app": "TextEdit"})
	c.call(t, 3, "mac/terminal", map[string]any{"path": dir})
	if e := c.callError(t, 4, "mac/reveal", map[string]any{"path": filepath.Join(dir, "gone")}); e.Code != CodeFolderGone {
		t.Fatalf("%+v", e)
	}
	// Each call is its own, so the order they reach open in is not fixed.
	want := []string{"-R " + dir, "-a TextEdit " + dir, "-a Terminal " + dir}
	sort.Strings(want)
	var got []string
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		b, _ := os.ReadFile(said)
		got = strings.Split(strings.TrimSpace(string(b)), "\n")
		sort.Strings(got)
		if slices.Equal(got, want) {
			return
		}
	}
	t.Fatalf("open was asked %q, want %q", got, want)
}
