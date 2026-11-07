package agentsd

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestVersionLine(t *testing.T) {
	for out, want := range map[string]string{
		"2.1.318 (Claude Code)\n":                                                 "2.1.318",
		"grok 1.0.67 (2fe064390d07) [stable]":                                     "1.0.67",
		"GitHub Copilot CLI 1.0.105.\nRun 'copilot update' to check for updates.": "1.0.105",
		"2026.10.01-e373342":                                                      "2026.10.01-e373342",
		"v24.21.0":                                                                "24.21.0",
		"usage: thing [options]":                                                  "",
		"":                                                                        "",
	} {
		if got := versionLine(out); got != want {
			t.Errorf("versionLine(%q) = %q, want %q", out, got, want)
		}
	}
}

func TestToolsetVersion(t *testing.T) {
	dir := t.TempDir()
	for id, manifest := range map[string]string{
		"codex":    `{"runtimeID":"codex","node":{"version":"v24.21.0"},"package":"@agentclientprotocol/codex-acp","packageVersion":"2.5.0"}`,
		"opencode": `{"kind":"archive","version":"1.19.5"}`,
	} {
		cur := filepath.Join(dir, id, "current")
		if err := os.MkdirAll(filepath.Join(cur, "bin"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(cur, "manifest.json"), []byte(manifest), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if got := toolsetVersion(filepath.Join(dir, "codex", "current", "bin", "codex-acp")); got != "2.5.0" {
		t.Errorf("a Node toolset says %q, want its packageVersion 2.5.0", got)
	}
	if got := toolsetVersion(filepath.Join(dir, "opencode", "current", "bin", "opencode")); got != "1.19.5" {
		t.Errorf("an archive says %q, want its version 1.19.5", got)
	}
	if got := toolsetVersion("/opt/homebrew/bin/grok"); got != "" {
		t.Errorf("a person's own copy says %q, want none", got)
	}
}

// A runtime's --version is asked once for each file at its path, and again when the file
// there changes.
func TestCachedVersionAsksOncePerFile(t *testing.T) {
	asked := 0
	old := runtimeVersion
	runtimeVersion = func(string) string { asked++; return "1.0." + string(rune('0'+asked)) }
	t.Cleanup(func() { runtimeVersion = old })

	path := filepath.Join(t.TempDir(), "grok")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if v := cachedVersion(path); v != "1.0.1" {
		t.Fatalf("first ask = %q", v)
	}
	if v := cachedVersion(path); v != "1.0.1" || asked != 1 {
		t.Fatalf("second ask = %q after %d runs, want the kept 1.0.1 after 1", v, asked)
	}
	later := time.Now().Add(time.Minute)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n# updated\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	if v := cachedVersion(path); v != "1.0.2" || asked != 2 {
		t.Fatalf("after an update = %q after %d runs, want 1.0.2 after 2", v, asked)
	}
}
