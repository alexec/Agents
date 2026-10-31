package hostinstall

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ulikunitz/xz"
)

// The app's own toolsets, as the bundle carries them.
const appToolsets = "../../../../App/Resources/toolsets"

func TestTheAppsNodeToolsetsAreReadAndItsArchivesAreNot(t *testing.T) {
	all := loadToolsets(appToolsets, []string{"claude", "codex", "opencode", "antigravity"})
	var got []string
	for _, ts := range all {
		got = append(got, ts.manifest.RuntimeID+":"+ts.shimName())
		if len(ts.id) != 16 {
			t.Fatalf("id %q", ts.id)
		}
	}
	if strings.Join(got, " ") != "claude:npx codex:codex-acp" {
		t.Fatalf("%v", got)
	}
	// The id is the window's: the manifest's and the lock's bytes, one after the other.
	cmd := exec.Command("sh", "-c", "cat manifest.json package-lock.json | sha256sum | cut -c1-16")
	cmd.Dir = filepath.Join(appToolsets, "claude")
	if want, err := cmd.Output(); err == nil && strings.TrimSpace(string(want)) != all[0].id {
		t.Fatalf("id %s, sha256sum says %s", all[0].id, want)
	}
	if last := all[0].shimLines()[3]; strings.HasSuffix(last, `"$@"`) ||
		!strings.Contains(last, "lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js") {
		t.Fatalf("claude's shim %q", last)
	}
}

func TestTheCLibraryIsReadAsLddSaysIt(t *testing.T) {
	for line, want := range map[string]string{
		"ldd (Debian GLIBC 2.36-9+deb12u14) 2.36": "glibc 2.36",
		"ldd (GNU libc) 2.17":                     "glibc 2.17",
		"musl libc (aarch64)":                     "musl (Alpine)",
		"sh: ldd: not found":                      "an unknown C library",
	} {
		f := &facts{}
		parseLibc(line, f)
		if f.libcDisplay() != want {
			t.Fatalf("%q: %s", line, f.libcDisplay())
		}
	}
	old, new := &facts{}, &facts{}
	parseLibc("ldd (GNU libc) 2.17", old)
	parseLibc("ldd (GNU libc) 2.28", new)
	if old.canInstallToolsets() || !new.canInstallToolsets() {
		t.Fatal("glibc 2.28 is the least Node's builds run on")
	}
}

func TestTheProbesToolsetLinesAreRead(t *testing.T) {
	f, err := parseProbe("Linux x86_64\n/home/a\n/dev/sda 100 1 99 1% /\n\ndefault\n" +
		"banner from a login shell\nlibc:ldd (GNU libc) 2.36\nfetch:/usr/bin/wget\navx2:yes\ntoolset:none\n" +
		"toolset.claude:0123456789abcdef\ntoolset.codex:none\n")
	if err != nil {
		t.Fatal(err)
	}
	if f.downloader != "wget" || f.glibc != [2]int{2, 36} || f.toolsets["claude"] != "0123456789abcdef" ||
		f.toolsets["codex"] != "" {
		t.Fatalf("%+v", f)
	}
}

// toolsetFake is a fake server with glibc, and a Node "tarball" in a dist folder whose
// npm makes the package the manifest names.
type toolsetFake struct {
	*fake
	toolsets string
	dist     string
	url      string
	logs     []string
}

func newToolsetFake(t *testing.T) *toolsetFake {
	t.Helper()
	f := &toolsetFake{fake: newFake(t)}
	// The server can unpack xz, so it fetches Node itself.
	f.write("bin/xz", "#!/bin/sh\nexit 1\n", 0o755)
	f.write("bin/ldd", "#!/bin/sh\necho \"${FAKE_SSH_LDD:-ldd (Debian GLIBC 2.36-9) 2.36}\"\n", 0o755)
	f.dist = filepath.Join(f.dir, "dist")
	f.write("node/node-v0/bin/node", "#!/bin/sh\n", 0o755)
	f.write("node/node-v0/bin/npm", `#!/bin/sh
echo "npm $*" >> "$HOME/npm-calls"
while [ $# -gt 0 ]; do [ "$1" = --prefix ] && prefix="$2"; shift; done
mkdir -p "$prefix/node_modules/@test/adapter/dist" && echo 'adapter' > "$prefix/node_modules/@test/adapter/dist/index.js"
`, 0o755)
	if err := os.MkdirAll(filepath.Join(f.dist, "v0"), 0o755); err != nil {
		t.Fatal(err)
	}
	// A plain tar under the xz name, and a tar on the server that reads it so: not every
	// machine the tests run on has xz.
	f.write("bin/tar", `#!/bin/sh
real=/usr/bin/tar; [ -x "$real" ] || real=/bin/tar
n=$#; i=0
while [ $i -lt $n ]; do a="$1"; shift; [ "$a" = -xJf ] && a=-xf; set -- "$@" "$a"; i=$((i+1)); done
exec "$real" "$@"
`, 0o755)
	tarball := filepath.Join(f.dist, "v0", "node-v0-linux-arm64.tar.xz")
	if out, err := exec.Command("tar", "-cf", tarball, "-C", filepath.Join(f.dir, "node"), "node-v0").CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	data, _ := os.ReadFile(tarball)
	server := httptest.NewServer(http.FileServer(http.Dir(f.dist)))
	t.Cleanup(server.Close)
	f.url = server.URL
	f.toolsets = filepath.Join(f.dir, "toolsets")
	manifest := fmt.Sprintf(`{"runtimeID":"claude","node":{"version":"v0","sha256":{"aarch64":"%s"}},`+
		`"package":"@test/adapter","packageVersion":"1.0.0","entry":"dist/index.js","minFreeBytes":1024}`, sum(string(data)))
	f.write("toolsets/claude/manifest.json", manifest, 0o644)
	f.write("toolsets/claude/package.json", `{"name":"toolset"}`, 0o644)
	f.write("toolsets/claude/package-lock.json", `{"lockfileVersion":3}`, 0o644)
	// An archive runtime, which is not a Node toolset.
	f.write("toolsets/opencode/manifest.json", `{"kind":"archive","runtimeID":"opencode"}`, 0o644)
	return f
}

func (f *toolsetFake) installer(steps *[]string) *Installer {
	i := f.fake.installer(&fakeCodes{}, steps)
	i.ToolsetFolder, i.NodeDist = f.toolsets, f.url
	i.Log = func(format string, args ...any) { f.logs = append(f.logs, fmt.Sprintf(format, args...)) }
	return i
}

func (f *toolsetFake) install(t *testing.T) {
	t.Helper()
	var steps []string
	got := reply(t)(f.installer(&steps).Install(context.Background(),
		json.RawMessage(`{"destination":"devbox","name":"Dev box","trust":"`+hostKeyFingerprint+`"}`)))
	if got["started"] != true {
		t.Fatalf("%v", got)
	}
	// No step of its own: the sheet says "Installing Agents…" through it.
	if strings.Join(steps, " ") != "Dev box:connect Dev box:checkSystem Dev box:setUp Dev box:started" {
		t.Fatalf("steps %v", steps)
	}
}

func TestAnInstallPutsClaudesToolsetOnBeforeTheHostStarts(t *testing.T) {
	f := newToolsetFake(t)
	f.install(t)
	ts, err := loadToolset(filepath.Join(f.toolsets, "claude"))
	if err != nil {
		t.Fatal(err)
	}
	tools := f.server("tools/claude")
	if current, err := os.Readlink(filepath.Join(tools, "current")); err != nil || current != ts.id {
		t.Fatalf("current %q %v (log %v)", current, err, f.logs)
	}
	for _, file := range []string{"ok", "manifest.json", "lib/package.json", "lib/package-lock.json", "node/bin/node",
		"lib/node_modules/@test/adapter/dist/index.js"} {
		if _, err := os.Stat(filepath.Join(tools, ts.id, file)); err != nil {
			t.Fatalf("%s: %v", file, err)
		}
	}
	shim, _ := os.ReadFile(filepath.Join(tools, ts.id, "bin/npx"))
	if string(shim) != strings.Join(ts.shimLines(), "\n")+"\n" {
		t.Fatalf("shim %q", shim)
	}
	if info, _ := os.Stat(filepath.Join(tools, ts.id, "bin/npx")); info == nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("shim mode %v", info)
	}
	calls, _ := os.ReadFile(filepath.Join(f.home, "npm-calls"))
	if !strings.Contains(string(calls), "npm ci --ignore-scripts --omit=dev --no-audit --no-fund --prefix") {
		t.Fatalf("npm %q", calls)
	}
	if entries, _ := filepath.Glob(filepath.Join(tools, ".part-*")); len(entries) != 0 || len(f.logs) != 0 {
		t.Fatalf("parts %v, logs %v", entries, f.logs)
	}
	if _, err := os.Stat(filepath.Join(f.home, "started-args")); err != nil {
		t.Fatal("the host did not start")
	}
	if left := f.leftInstallFolders(); len(left) != 0 {
		t.Fatalf("left %v", left)
	}

	// Again: the toolset current points at is not fetched a second time.
	os.Remove(filepath.Join(f.home, "npm-calls"))
	f.install(t)
	if _, err := os.Stat(filepath.Join(f.home, "npm-calls")); err == nil {
		t.Fatal("the same toolset was installed again")
	}
}

func TestADownloadThatDoesNotMatchLeavesNoToolsetButAHost(t *testing.T) {
	f := newToolsetFake(t)
	manifest, _ := os.ReadFile(filepath.Join(f.toolsets, "claude/manifest.json"))
	var m map[string]any
	json.Unmarshal(manifest, &m)
	m["node"].(map[string]any)["sha256"] = map[string]string{"aarch64": strings.Repeat("0", 64)}
	data, _ := json.Marshal(m)
	f.write("toolsets/claude/manifest.json", string(data), 0o644)
	f.install(t)
	if entries, _ := os.ReadDir(f.server("tools/claude")); len(entries) != 0 {
		t.Fatalf("left %v", entries)
	}
	if len(f.logs) != 1 || !strings.Contains(f.logs[0], "Claude on Dev box: The download did not match its checksum") {
		t.Fatalf("logs %v", f.logs)
	}
	if _, err := os.Stat(filepath.Join(f.home, "started-args")); err != nil {
		t.Fatal("the host did not start")
	}
}

func TestAServerWithoutGlibcIsNotGivenAToolset(t *testing.T) {
	f := newToolsetFake(t)
	f.env["FAKE_SSH_LDD"] = "musl libc (aarch64)"
	f.install(t)
	if _, err := os.Stat(f.server("tools/claude")); err == nil {
		t.Fatal("a toolset was started on musl")
	}
	if len(f.logs) != 1 || !strings.HasSuffix(f.logs[0], "Claude needs glibc 2.28 or later, and the server has musl (Alpine).") {
		t.Fatalf("logs %v", f.logs)
	}
}

func TestNoToolsetFolderInstallsNone(t *testing.T) {
	f := newToolsetFake(t)
	var steps []string
	i := f.installer(&steps)
	i.ToolsetFolder = ""
	reply(t)(i.Install(context.Background(),
		json.RawMessage(`{"destination":"devbox","trust":"`+hostKeyFingerprint+`"}`)))
	if _, err := os.Stat(f.server("tools")); err == nil || len(f.logs) != 0 {
		t.Fatalf("tools made, logs %v", f.logs)
	}
}

func TestAServerWithoutXzIsSentNodeUnpacked(t *testing.T) {
	f := newToolsetFake(t)
	// Node as nodejs.org ships it, xz and all, and its checksum in the manifest.
	plain, _ := os.ReadFile(filepath.Join(f.dist, "v0", "node-v0-linux-arm64.tar.xz"))
	var packed strings.Builder
	w, err := xz.NewWriter(&packed)
	if err != nil {
		t.Fatal(err)
	}
	w.Write(plain)
	w.Close()
	f.write("dist/v0/node-v0-linux-arm64.tar.xz", packed.String(), 0o644)
	manifest, _ := os.ReadFile(filepath.Join(f.toolsets, "claude/manifest.json"))
	f.write("toolsets/claude/manifest.json", strings.Replace(string(manifest), sum(string(plain)), sum(packed.String()), 1), 0o644)
	ts, err := loadToolset(filepath.Join(f.toolsets, "claude"))
	if err != nil {
		t.Fatal(err)
	}
	ssh := sshCommand{executable: filepath.Join(f.dir, "ssh"), name: "devbox", env: f.environ(),
		options: []string{"-o", "StrictHostKeyChecking=no"}}
	// No xz, and no curl or wget either: nothing is fetched on the server.
	found := &facts{system: "Linux", architecture: "aarch64", freeBytes: 1 << 30, glibc: [2]int{2, 36},
		toolsets: map[string]string{}}
	bundles := t.TempDir()
	if err := (installer{ssh}).installToolset(context.Background(), ts, found, f.url, bundles); err != nil {
		t.Fatal(err)
	}
	tools := f.server("tools/claude")
	if current, _ := os.Readlink(filepath.Join(tools, "current")); current != ts.id {
		t.Fatalf("current %q", current)
	}
	for _, file := range []string{"ok", "node/bin/node", "node/bin/npm", "bin/npx", "lib/node_modules/@test/adapter/dist/index.js"} {
		if _, err := os.Stat(filepath.Join(tools, ts.id, file)); err != nil {
			t.Fatalf("%s: %v", file, err)
		}
	}
	if _, err := os.Stat(filepath.Join(tools, ts.id, "node.tar")); err == nil {
		t.Fatal("node.tar was left")
	}
	if left, _ := os.ReadDir(bundles); len(left) != 0 {
		t.Fatalf("left %v", left)
	}

	// A download that is not the pinned one is refused here, before the server sees it.
	f.write("dist/v0/node-v0-linux-arm64.tar.xz", "not node", 0o644)
	ts.id = "another"
	err = (installer{ssh}).installToolset(context.Background(), ts, found, f.url, bundles)
	if p, ok := err.(*Problem); !ok || !strings.Contains(p.Words, "did not match its checksum") {
		t.Fatalf("%v", err)
	}
	if _, err := os.Stat(filepath.Join(tools, "another")); err == nil {
		t.Fatal("a toolset was made from the wrong download")
	}
}
