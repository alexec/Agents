package agentsd

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
	"github.com/ulikunitz/xz"
)

// tarGz makes a .tar.gz of files, each name to its text; a name ending in * is executable.
func tarGz(t *testing.T, files map[string]string) []byte {
	var b bytes.Buffer
	z := gzip.NewWriter(&b)
	w := tar.NewWriter(z)
	for name, text := range files {
		mode := int64(0o644)
		if strings.HasSuffix(name, "*") {
			name, mode = strings.TrimSuffix(name, "*"), 0o755
		}
		w.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(text)), Typeflag: tar.TypeReg})
		w.Write([]byte(text))
	}
	w.Close()
	z.Close()
	return b.Bytes()
}

func sha(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func TestTheBundlesToolsetsLoad(t *testing.T) {
	ts := loadToolsets("../../../App/Resources/toolsets")
	for _, id := range []string{"claude", "codex", "antigravity", "opencode"} {
		if ts[id] == nil || len(ts[id].id) != 16 {
			t.Fatalf("%s: %+v", id, ts[id])
		}
	}
	m, _ := os.ReadFile("../../../App/Resources/toolsets/claude/manifest.json")
	l, _ := os.ReadFile("../../../App/Resources/toolsets/claude/package-lock.json")
	if want := sha(append(m, l...))[:16]; ts["claude"].id != want {
		t.Fatalf("claude's id %s, want %s", ts["claude"].id, want)
	}
	if ts["claude"].archive() || !ts["opencode"].archive() || ts["claude"].node == nil {
		t.Fatal("kinds")
	}
	// A Mac's recipes: on Linux, every test host's start made the switch a server's.
	old := serverToolsets
	serverToolsets = false
	t.Cleanup(func() { serverToolsets = old })
	d := &Daemon{}
	d.toolsets = ts
	if d.recipe("claude") == nil || d.recipe("opencode") == nil || d.recipe("grok").Script == nil || d.recipe("nothing") != nil {
		t.Fatal("recipes")
	}
}

// A fake Node whose npm writes the package the lock names, and a fake vendor archive.
func fakeVendors(t *testing.T) (dist *httptest.Server, bundle string) {
	npm := `#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = --prefix ] && p=$2; shift; done
mkdir -p "$p/node_modules/@x/adapter/dist" && echo 'ok' > "$p/node_modules/@x/adapter/dist/index.js"
`
	node := tarGz(t, map[string]string{"node-v1/bin/npm*": npm, "node-v1/bin/node*": "#!/bin/sh\n"})
	archive := tarGz(t, map[string]string{"opencode*": "#!/bin/sh\necho opencode\n"})
	dist = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, ".tar.gz") && strings.Contains(r.URL.Path, "node-v1"):
			w.Write(node)
		case strings.HasSuffix(r.URL.Path, "/opencode.tar.gz"):
			w.Write(archive)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(dist.Close)
	bundle = t.TempDir()
	codex := filepath.Join(bundle, "codex")
	os.MkdirAll(codex, 0o755)
	os.WriteFile(filepath.Join(codex, "manifest.json"), []byte(`{"runtimeID":"codex","package":"@x/adapter","entry":"dist/index.js"}`), 0o644)
	os.WriteFile(filepath.Join(codex, "package.json"), []byte(`{}`), 0o644)
	os.WriteFile(filepath.Join(codex, "package-lock.json"), []byte(`{}`), 0o644)
	pin, _ := json.Marshal(map[string]any{"version": "v1", "sha256": map[string]string{macArch(): sha(node)}})
	os.WriteFile(filepath.Join(codex, "mac-node.json"), pin, 0o644)
	oc := filepath.Join(bundle, "opencode")
	os.MkdirAll(oc, 0o755)
	m, _ := json.Marshal(map[string]any{"kind": "archive", "runtimeID": "opencode", "version": "1", "minFreeBytes": 1,
		"platforms": map[string]any{macPlatform(): map[string]any{"url": dist.URL + "/opencode.tar.gz", "sha256": sha(archive),
			"size": len(archive), "command": "opencode", "arguments": []string{"acp"}}}})
	os.WriteFile(filepath.Join(oc, "manifest.json"), m, 0o644)
	old := nodeDistURL
	nodeDistURL = dist.URL + "/"
	t.Cleanup(func() { nodeDistURL = old; macToolsHome = "" })
	return dist, bundle
}

// install asks for runtimes/install and waits for its ending. Not c.call, which drops the
// notifications that come before its answer: an install refused at once (no glibc) can
// say its ending before the answer, and that ending was lost.
func install(t *testing.T, c *conn, n int, id string) wire.RuntimeStatus {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": n, "method": "runtimes/install",
		"params": map[string]any{"runtimeID": id}})
	c.in <- string(b)
	return waitInstalled(t, c, id)
}

func waitInstalled(t *testing.T, c *conn, id string) wire.RuntimeStatus {
	t.Helper()
	deadline := time.After(20 * time.Second)
	for {
		select {
		case line := <-c.out:
			var m struct {
				Method string             `json:"method"`
				Params wire.RuntimeStatus `json:"params"`
			}
			json.Unmarshal([]byte(line), &m)
			if m.Method == "runtime/changed" && m.Params.Runtime.ID == id && m.Params.Availability.Installing == nil {
				return m.Params
			}
		case <-deadline:
			t.Fatalf("%s: no ending", id)
		}
	}
}

func TestInstallTheAppsOwnCopies(t *testing.T) {
	_, bundle := fakeVendors(t)
	d, c := start(t, t.TempDir())
	tools := filepath.Join(t.TempDir(), "tools")
	d.serveInstall(tools, bundle)
	// A device's connection may not install one that is not there.
	if _, err := d.installRuntime(&Client{conn: deviceConn{newConn()}}, "codex"); err == nil {
		t.Fatal("a device installed")
	}

	for i, id := range []string{"codex", "opencode"} {
		var s wire.RuntimeStatus
		json.Unmarshal(c.call(t, i+1, "runtimes/install", map[string]any{"runtimeID": id}), &s)
		if s.Availability.Installing == nil {
			t.Fatalf("%s: answered %+v", id, s.Availability)
		}
		end := waitInstalled(t, c, id)
		if end.Availability.Available == nil || !strings.HasSuffix(end.Availability.Available.Path, "/current/bin/"+runtimeByID(id).Executable) {
			t.Fatalf("%s: %+v", id, end.Availability)
		}
		shim, _ := os.ReadFile(end.Availability.Available.Path)
		if id == "codex" && !strings.Contains(string(shim), `"$d/lib/node_modules/@x/adapter/dist/index.js"`) ||
			id == "opencode" && !strings.Contains(string(shim), `exec "$d/opencode" "acp" "$@"`) {
			t.Fatalf("%s's shim: %s", id, shim)
		}
	}
	// runtimes/list offers the button, and says the copy is the one the app carries.
	var list []wire.RuntimeStatus
	json.Unmarshal(c.call(t, 9, "runtimes/list", nil), &list)
	for _, s := range list {
		if s.Runtime.ID == "codex" && (s.Runtime.Install == nil || s.Availability.Available == nil || s.Outdated) {
			t.Fatalf("codex listed as %+v", s)
		}
	}
	// A device's connection may update the copy that is there (#4035): an older one is current.
	current := filepath.Join(tools, "codex", "current")
	pinned, _ := os.Readlink(current)
	old := filepath.Join(tools, "codex", "old")
	if err := os.Rename(filepath.Join(tools, "codex", pinned), old); err != nil {
		t.Fatal(err)
	}
	os.Remove(current)
	os.Symlink("old", current)
	if s := d.statusOf(runtimeByID("codex")); !s.Outdated {
		t.Fatalf("an older copy listed as %+v", s)
	}
	if s, err := d.installRuntime(&Client{conn: deviceConn{newConn()}}, "codex"); err != nil || s.Availability.Installing == nil {
		t.Fatalf("a device's update: %+v %v", s.Availability, err)
	}
	if end := waitInstalled(t, c, "codex"); end.Availability.Available == nil || end.Outdated {
		t.Fatalf("updated to %+v", end)
	}
}

// Toolsets that pin the same Node share one <tools>/node/<v> (#3959); a new pin adds a
// second, and tidy removes the first once no toolset links to it.
func TestToolsetsShareOneNode(t *testing.T) {
	_, bundle := fakeVendors(t)
	oldHome, oldServer := toolsHome, serverToolsets
	toolsHome, serverToolsets = filepath.Join(t.TempDir(), "tools"), false
	t.Cleanup(func() { toolsHome, serverToolsets = oldHome, oldServer })
	ts := loadToolsets(bundle)
	codex := ts["codex"]
	browser := *codex
	browser.runtimeID, browser.id = browserToolsetID, "b1"
	for _, ts := range []*macToolset{codex, &browser} {
		if err := ts.installNode(func(string) {}); err != nil {
			t.Fatal(err)
		}
		if to, err := os.Readlink(filepath.Join(toolsHome, ts.runtimeID, ts.id, "node")); err != nil || to != "../../node/v1" {
			t.Fatalf("%s's node: %q %v", ts.runtimeID, to, err)
		}
		if _, err := os.Stat(filepath.Join(toolsHome, ts.runtimeID, "current", "node", "bin", "node")); err != nil {
			t.Fatal(err)
		}
	}
	if names, _ := os.ReadDir(filepath.Join(toolsHome, "node")); len(names) != 1 {
		t.Fatalf("Nodes: %v", names)
	}

	// A new pin for the browser: v1 stays while Codex links to it.
	if err := os.CopyFS(filepath.Join(toolsHome, "node", "v2"), os.DirFS(filepath.Join(toolsHome, "node", "v1"))); err != nil {
		t.Fatal(err)
	}
	browser.node = &struct {
		Version string            `json:"version"`
		SHA256  map[string]string `json:"sha256"`
	}{"v2", codex.node.SHA256}
	browser.id = "b2"
	if err := browser.installNode(func(string) {}); err != nil {
		t.Fatal(err)
	}
	browser.tidy()
	tidyNode()
	if names, _ := os.ReadDir(filepath.Join(toolsHome, "node")); len(names) != 2 {
		t.Fatalf("Nodes: %v", names)
	}
	// Codex moves on too: v1 has no toolset left, so it goes.
	os.RemoveAll(filepath.Join(toolsHome, "codex"))
	tidyNode()
	if names, _ := os.ReadDir(filepath.Join(toolsHome, "node")); len(names) != 1 || names[0].Name() != "v2" {
		t.Fatalf("Nodes: %v", names)
	}
}

type deviceConn struct{ *conn }

func (deviceConn) Device() string { return "11111111-2222-3333-4444-555555555555" }

func TestAnInstallThatFailsSaysWhy(t *testing.T) {
	dist, bundle := fakeVendors(t)
	// A pin that does not match.
	os.WriteFile(filepath.Join(bundle, "codex", "mac-node.json"), []byte(`{"version":"v1","sha256":{"`+macArch()+`":"00"}}`), 0o644)
	d, c := start(t, t.TempDir())
	tools := filepath.Join(t.TempDir(), "tools")
	d.serveInstall(tools, bundle)
	end := install(t, c, 1, "codex")
	if end.Availability.InstallFailed == nil || !strings.Contains(end.Availability.InstallFailed.Reason, "checksum") {
		t.Fatalf("%+v", end.Availability)
	}
	if names, _ := os.ReadDir(filepath.Join(tools, "codex")); len(names) != 0 {
		t.Fatalf("left behind: %v", names)
	}
	if err := runScript(dist.URL+"/nothing.sh", "sh", "Grok"); err == nil || !strings.Contains(err.Error(), "Grok’s installer failed") {
		t.Fatalf("script: %v", err)
	}
	if e := c.callError(t, 2, "runtimes/install", map[string]any{"runtimeID": "nothing"}); e.Code != CodeRuntimeNotFound {
		t.Fatalf("%+v", e)
	}
}

func TestNPMProblems(t *testing.T) {
	out := "npm error code E404\nnpm error 404 Not Found - GET https://registry/x\nnpm error A complete log of this run can be found in: /x\n"
	if got := npmProblem(out, "Codex").Error(); got != "Installing Codex failed: 404 Not Found - GET https://registry/x" {
		t.Fatal(got)
	}
	if got := npmProblem("npm ERR! code EAI_AGAIN\n", "Codex").Error(); !strings.Contains(got, "internet") {
		t.Fatal(got)
	}
}

// tarXZ makes a .tar.xz of files, as tarGz; a name starting with @ is a link: "@name": "target".
func tarXZ(t *testing.T, files map[string]string) []byte {
	var b bytes.Buffer
	z, err := xz.NewWriter(&b)
	if err != nil {
		t.Fatal(err)
	}
	w := tar.NewWriter(z)
	for name, text := range files {
		if link, ok := strings.CutPrefix(name, "@"); ok {
			w.WriteHeader(&tar.Header{Name: link, Linkname: text, Typeflag: tar.TypeSymlink, Mode: 0o777})
			continue
		}
		mode := int64(0o644)
		if strings.HasSuffix(name, "*") {
			name, mode = strings.TrimSuffix(name, "*"), 0o755
		}
		w.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(text)), Typeflag: tar.TypeReg})
		w.Write([]byte(text))
	}
	w.Close()
	z.Close()
	return b.Bytes()
}

// A server (#1312) installs a Node toolset from the manifest's Linux pin, into
// ~/.agents-server/tools, where discovery looks first.
func TestAServerInstallsANodeToolset(t *testing.T) {
	npm := `#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = --prefix ] && p=$2; shift; done
mkdir -p "$p/node_modules/@x/adapter/dist" && echo 'ok' > "$p/node_modules/@x/adapter/dist/index.js"
`
	node := tarXZ(t, map[string]string{"node-v1/lib/npm-cli*": npm, "@node-v1/bin/npm": "../lib/npm-cli", "node-v1/bin/node*": "#!/bin/sh\n"})
	dist := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/node-v1-linux-"+macArch()+".tar.xz" {
			w.Write(node)
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(dist.Close)
	toolsets := t.TempDir()
	// Codex, not Claude: a CI runner has an npx on its PATH, which is Claude already there.
	codex := filepath.Join(toolsets, "codex")
	os.MkdirAll(codex, 0o755)
	m, _ := json.Marshal(map[string]any{"runtimeID": "codex", "package": "@x/adapter", "entry": "dist/index.js",
		"node": map[string]any{"version": "v1", "sha256": map[string]string{serverArch(): sha(node)}}})
	os.WriteFile(filepath.Join(codex, "manifest.json"), m, 0o644)
	os.WriteFile(filepath.Join(codex, "package.json"), []byte(`{}`), 0o644)
	os.WriteFile(filepath.Join(codex, "package-lock.json"), []byte(`{}`), 0o644)

	home := t.TempDir()
	t.Setenv("HOME", home)
	d, c := start(t, t.TempDir())
	oldDist, oldLibc, oldMac := nodeDistURL, serverLibc, macToolsHome
	nodeDistURL, macToolsHome = dist.URL+"/", ""
	libc := "glibc 2.36"
	serverLibc = func() string { return libc }
	t.Cleanup(func() {
		nodeDistURL, serverLibc, macToolsHome = oldDist, oldLibc, oldMac
		toolsHome, serverToolsets = "", false
	})
	d.serveServerInstall(toolsets)

	// Only the Node toolsets: a vendor's script or archive is the person's to run.
	if d.recipe("codex") == nil || d.recipe("grok") != nil || d.recipe("opencode") != nil {
		t.Fatal("a server's recipes")
	}
	// musl, or a glibc older than Node's builds need, is refused before any download.
	libc = ""
	if end := install(t, c, 1, "codex"); end.Availability.InstallFailed == nil ||
		!strings.Contains(end.Availability.InstallFailed.Reason, "glibc 2.28 or later, and this server has musl") {
		t.Fatalf("musl: %+v", end.Availability)
	}
	libc = "glibc 2.36"
	end := install(t, c, 2, "codex")
	want := filepath.Join(home, ".agents-server", "tools", "codex", "current", "bin", runtimeByID("codex").Executable)
	if end.Availability.Available == nil || end.Availability.Available.Path != want {
		t.Fatalf("%+v, want %s", end.Availability, want)
	}
	if target, err := os.Readlink(filepath.Join(home, ".agents-server", "tools", "codex", "current", "node", "bin", "npm")); err != nil || target != "../lib/npm-cli" {
		t.Fatalf("npm's link: %q %v", target, err)
	}
	if s := d.statusOf(runtimeByID("codex")); s.Outdated || s.Runtime.Install == nil {
		t.Fatalf("listed as %+v", s)
	}
}

func TestGlibcAtLeast(t *testing.T) {
	for libc, want := range map[string]bool{"glibc 2.36": true, "glibc 2.28": true, "glibc 2.27": false, "glibc 3.0": true, "": false, "musl": false} {
		if glibcAtLeast(libc, 2, 28) != want {
			t.Fatalf("%q", libc)
		}
	}
}

func TestUntarXZStaysInside(t *testing.T) {
	for _, files := range []map[string]string{{"n/../../escape*": "x"}, {"@n/bin/out": "../../../etc"}} {
		file := filepath.Join(t.TempDir(), "a.tar.xz")
		os.WriteFile(file, tarXZ(t, files), 0o644)
		if err := untarXZ(file, t.TempDir()); err == nil {
			t.Fatalf("%v unpacked", files)
		}
	}
}

// On a server, Claude's npx is not Claude installed (#3378): every machine with Node has one,
// and Claude's sign-in needs its toolset's command line or the person's own claude.
func TestAServerTakesNPXAsNoClaude(t *testing.T) {
	home, own := t.TempDir(), t.TempDir()
	t.Setenv("HOME", home)
	oldShell, oldMac := loginShellPath, macToolsHome
	loginShellPath, macToolsHome = func(string) []string { return []string{own} }, ""
	resetShellPath := func() { shellPath.Lock(); shellPath.key = ""; shellPath.Unlock() }
	resetShellPath()
	t.Cleanup(func() { loginShellPath, macToolsHome = oldShell, oldMac; resetShellPath() })
	claude, codex := runtimeByID("claude"), runtimeByID("codex")

	if installedAt(claude, "") || !installedAt(codex, "/usr/bin/codex-acp") {
		t.Fatal("a runtime that is not npx is installed where it was found")
	}
	// A CI runner or a dev machine can have its own claude in one of the usual places.
	if onPath([]string{"PATH=" + strings.Join(searchPaths(), ":")}, "claude") == "" && installedAt(claude, "/usr/bin/npx") {
		t.Fatal("npx alone is taken as Claude installed")
	}
	shim := filepath.Join(toolsetFolder("claude"), "current", "bin", "npx")
	os.MkdirAll(filepath.Dir(shim), 0o755)
	os.WriteFile(shim, []byte("#!/bin/sh\n"), 0o755)
	os.WriteFile(filepath.Join(filepath.Dir(filepath.Dir(shim)), "ok"), nil, 0o644)
	if !installedAt(claude, shim) {
		t.Fatal("Claude's toolset is not taken as Claude installed")
	}
	os.WriteFile(filepath.Join(own, "claude"), []byte("#!/bin/sh\n"), 0o755)
	if !installedAt(claude, "/usr/bin/npx") {
		t.Fatal("the person's own claude is not taken as Claude installed")
	}
	macToolsHome = t.TempDir()
	os.Remove(filepath.Join(own, "claude"))
	if !installedAt(claude, "/usr/bin/npx") {
		t.Fatal("a Mac's npx is Claude, as before")
	}
}

// Claude prefers the app's own copy on a Mac (#4512): the first use of the person's npx
// installs the pinned toolset, runtimes/list says installing, and from then on the shim
// runs the adapter with node, with no `npm exec` under it.
func TestClaudesFirstUseInstallsTheAppsCopy(t *testing.T) {
	_, bundle := fakeVendors(t)
	own := t.TempDir()
	os.WriteFile(filepath.Join(own, "npx"), []byte("#!/bin/sh\n"), 0o755)
	oldShell := loginShellPath
	loginShellPath = func(string) []string { return []string{own} }
	resetShellPath := func() { shellPath.Lock(); shellPath.key = ""; shellPath.Unlock() }
	resetShellPath()
	t.Cleanup(func() { loginShellPath = oldShell; resetShellPath() })
	claude := filepath.Join(bundle, "claude")
	os.MkdirAll(claude, 0o755)
	for name, text := range map[string]string{"package.json": `{}`, "package-lock.json": `{}`,
		"manifest.json": `{"runtimeID":"claude","package":"@x/adapter","entry":"dist/index.js"}`} {
		os.WriteFile(filepath.Join(claude, name), []byte(text), 0o644)
	}
	pin, _ := os.ReadFile(filepath.Join(bundle, "codex", "mac-node.json"))
	os.WriteFile(filepath.Join(claude, "mac-node.json"), pin, 0o644)
	d, c := start(t, t.TempDir())
	d.serveInstall(filepath.Join(t.TempDir(), "tools"), bundle)
	r := runtimeByID("claude")

	launch, err := d.launchFor(r, t.TempDir())
	if err != nil || launch.Command != filepath.Join(own, "npx") {
		t.Fatalf("the first use ran %q, %v: want the person's npx while the app's copy installs", launch.Command, err)
	}
	if s := d.statusOf(r); s.Availability.Installing == nil {
		t.Fatalf("runtimes/list says %+v while the app's copy installs", s.Availability)
	}
	end := waitInstalled(t, c, "claude")
	if end.Availability.Available == nil || end.Availability.Available.Path != appToolset(r) {
		t.Fatalf("installed as %+v", end.Availability)
	}
	if launch, err = d.launchFor(r, t.TempDir()); err != nil || launch.Command != appToolset(r) {
		t.Fatalf("the next use ran %q, %v: want the app's copy", launch.Command, err)
	}
	shim, _ := os.ReadFile(launch.Command)
	if !strings.Contains(string(shim), `exec "$d/node/bin/node" "$d/lib/node_modules/@x/adapter/dist/index.js"`) || strings.Contains(string(shim), "npx") {
		t.Fatalf("the shim: %s", shim)
	}
	if d.installOnFirstUse(r) {
		t.Fatal("a whole copy installed again")
	}
	// Codex, which uses the app's copy only, is installed by the person, not by a use.
	if d.installOnFirstUse(runtimeByID("codex")) {
		t.Fatal("codex installed on use")
	}
	// One that failed waits for the person's Install.
	os.RemoveAll(filepath.Join(macToolsHome, "claude"))
	d.instMu.Lock()
	d.states["claude"] = installFailed("no room")
	d.instMu.Unlock()
	if d.installOnFirstUse(r) {
		t.Fatal("a failed install was tried again by itself")
	}
}

// Dependabot bumps the adapter in package.json and its lock (#4512), and nothing else: the
// manifest's packageVersion, which runtimes/list and the runtime check read, must say the same.
func TestTheBundlesNodeToolsetsPinOneVersion(t *testing.T) {
	for _, id := range []string{"claude", "codex"} {
		dir := filepath.Join("../../../App/Resources/toolsets", id)
		var manifest struct{ Package, PackageVersion string }
		var pkg struct{ Dependencies map[string]string }
		var lock struct {
			Packages map[string]struct{ Version string } `json:"packages"`
		}
		for name, v := range map[string]any{"manifest.json": &manifest, "package.json": &pkg, "package-lock.json": &lock} {
			b, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil || json.Unmarshal(b, v) != nil {
				t.Fatalf("%s/%s: %v", id, name, err)
			}
		}
		pinned, locked := pkg.Dependencies[manifest.Package], lock.Packages["node_modules/"+manifest.Package].Version
		if pinned != manifest.PackageVersion || locked != manifest.PackageVersion {
			t.Fatalf("%s pins %s %s in package.json and %s in its lock, and its manifest says %s: run scripts/update-toolset.sh for %s with %s",
				id, manifest.Package, pinned, locked, manifest.PackageVersion, id, pinned)
		}
	}
}
