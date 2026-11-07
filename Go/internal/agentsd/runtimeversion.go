package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// The version of each installed runtime, for a machine's page (#3674). The app's own copy
// says its toolset's pinned version; any other copy is asked with --version once per path
// and file, and the answer is kept until the file at that path changes.

// toolsetVersion is the version current/manifest.json pins when path is a toolset's shim
// (<tools>/<id>/current/bin/<executable>): a Node toolset's packageVersion, an archive's
// version. "" for any other path.
func toolsetVersion(path string) string {
	cur := filepath.Dir(filepath.Dir(path))
	if filepath.Base(cur) != "current" || filepath.Base(filepath.Dir(path)) != "bin" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(cur, "manifest.json"))
	if err != nil {
		return ""
	}
	var m struct {
		PackageVersion string `json:"packageVersion"`
		Version        string `json:"version"`
	}
	if json.Unmarshal(b, &m) != nil {
		return ""
	}
	if m.PackageVersion != "" {
		return m.PackageVersion
	}
	return m.Version
}

// versionLine is the version in the first line a runtime's --version prints: its first
// word that starts with a digit, less a "v" before it and a full stop after it.
// "2.1.4 (Claude Code)", "grok 1.0.67 (2fe0643) [stable]" and "GitHub Copilot CLI 1.0.105."
// are 2.1.4, 1.0.67 and 1.0.105.
func versionLine(out string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(out), "\n")
	for _, w := range strings.Fields(line) {
		w = strings.TrimSuffix(strings.TrimPrefix(w, "v"), ".")
		if w != "" && w[0] >= '0' && w[0] <= '9' {
			return w
		}
	}
	return ""
}

// runtimeVersion runs path --version and reads its version; a test replaces it so that no
// runtime is started.
var runtimeVersion = func(path string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "--version")
	cmd.Env = loginEnvironment()
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return versionLine(string(out))
}

// versions is what runtimeVersion said for each path, kept while the file there (its
// target, when the path is a link) is the same.
var versions struct {
	sync.Mutex
	at map[string]versionAt
}

type versionAt struct {
	file    string
	modTime time.Time
	size    int64
	version string
}

// cachedVersion is runtimeVersion for path, asked once for each file at that path.
func cachedVersion(path string) string {
	file, err := filepath.EvalSymlinks(path)
	if err != nil {
		return ""
	}
	fi, err := os.Stat(file)
	if err != nil {
		return ""
	}
	versions.Lock()
	v, ok := versions.at[path]
	versions.Unlock()
	if ok && v.file == file && v.modTime.Equal(fi.ModTime()) && v.size == fi.Size() {
		return v.version
	}
	v = versionAt{file: file, modTime: fi.ModTime(), size: fi.Size(), version: runtimeVersion(path)}
	versions.Lock()
	if versions.at == nil {
		versions.at = map[string]versionAt{}
	}
	versions.at[path] = v
	versions.Unlock()
	return v.version
}

// installedVersion is the version of r installed at path, or "" when it is not known.
// Claude's own copy is run by npx, so its version is the claude command's on the login
// shell's PATH, as installedAt finds it.
func installedVersion(r *runtimeDef, path string) string {
	if path == "" {
		return ""
	}
	if v := toolsetVersion(path); v != "" {
		return v
	}
	if r.Executable == "npx" {
		path = onPath([]string{"PATH=" + strings.Join(searchPaths(), ":")}, r.ID)
		if path == "" {
			return ""
		}
	}
	return cachedVersion(path)
}
