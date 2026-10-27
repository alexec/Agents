package hostinstall

import (
	"archive/tar"
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ulikunitz/xz"
)

// The toolset installer on a control-plane host (#1136): what AgentsKit's
// ToolsetInstaller puts on a server the window holds over ssh (043, 046), done by
// machines/install instead, so a server added through the control plane can run a runtime
// with nothing installed by the person.
//
// The server downloads it itself (D2): Node.js from nodejs.org, checked against the
// SHA-256 the manifest carries, then the ACP adapter with `npm ci` against the lock,
// whose integrity fields npm checks. It lands in ~/.agents-server/tools/<runtime>/<id>/,
// built in .part-<id>, marked whole with ok last and only then moved into place.
//
// A server with no xz (a minimal Debian has none) or no curl or wget cannot do the first
// part, so the control plane does: it downloads Node, checks the same SHA-256, and sends
// it unpacked in the bundle. npm still runs on the server.

// Toolset files, as Toolset.manifestFile, packageFile and lockFile.
const (
	toolsetManifestFile = "manifest.json"
	toolsetPackageFile  = "package.json"
	toolsetLockFile     = "package-lock.json"
)

// npmCIArguments is Toolset.npmCIArguments: the lock and nothing else, no install
// scripts, and nothing said about audits or funding.
var npmCIArguments = []string{"ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund"}

// DefaultToolsets are the runtimes machines/install puts on a server when the Installer
// names none: Claude, the default runtime. Each is about 500 MB and a minute of npm.
var DefaultToolsets = []string{"claude"}

// nodeDist is where Node's tarballs are published.
const nodeDist = "https://nodejs.org/dist"

// toolsetManifest is Toolset.Manifest. Archive manifests ("kind": "archive") are not
// Node toolsets and are not read.
type toolsetManifest struct {
	Kind      string `json:"kind"`
	RuntimeID string `json:"runtimeID"`
	Node      struct {
		Version string            `json:"version"`
		SHA256  map[string]string `json:"sha256"`
	} `json:"node"`
	Package           string `json:"package"`
	Entry             string `json:"entry"`
	MinFreeBytes      int64  `json:"minFreeBytes"`
	ForwardsArguments *bool  `json:"forwardsArguments"`
}

// toolset is Toolset: a manifest, its id, and the folder its files are read from.
type toolset struct {
	manifest toolsetManifest
	id       string
	folder   string
}

// toolsetExecutables is RuntimeCatalog's executable for each runtime the app installs as
// a Node toolset: the shim's name in bin/, which discovery looks for (Toolset.shimName).
var toolsetExecutables = map[string]string{"claude": "npx", "codex": "codex-acp", "gemini": "gemini"}

func (t toolset) shimName() string {
	if name, ok := toolsetExecutables[t.manifest.RuntimeID]; ok {
		return name
	}
	return "npx"
}

// shimLines is Toolset.shimLines: the pinned package run by the toolset's own Node,
// whatever the shim is called. No line holds a single quote.
func (t toolset) shimLines() []string {
	forwards := ""
	if t.manifest.ForwardsArguments != nil && *t.manifest.ForwardsArguments {
		forwards = ` "$@"`
	}
	entry := "lib/node_modules/" + t.manifest.Package + "/" + t.manifest.Entry
	return []string{"#!/bin/sh",
		"# Agents: runs the " + t.manifest.Package + " this toolset was installed with.",
		`d=$(cd "$(dirname "$0")/.." && pwd -P)`,
		`PATH="$d/node/bin:$PATH" exec "$d/node/bin/node" "$d/` + entry + `"` + forwards}
}

// nodeTarball is Manifest.nodeTarball: Node's Linux tarball for an architecture's binary
// suffix, relative to /dist/.
func (m toolsetManifest) nodeTarball(arch string) string {
	var node string
	switch arch {
	case "x86_64":
		node = "x64"
	case "aarch64":
		node = "arm64"
	default:
		return ""
	}
	return m.Node.Version + "/node-" + m.Node.Version + "-linux-" + node + ".tar.xz"
}

// toolsetServerFolder is Toolset.serverFolder: a runtime's toolsets, relative to $HOME.
func toolsetServerFolder(runtimeID string) string { return ".agents-server/tools/" + runtimeID }

// loadToolset is Toolset.load: a toolset folder from the app's bundle. Its id is the
// first sixteen hex characters of the SHA-256 of the manifest and lock, byte for byte,
// so the same pin is the same id the window's installer gives it.
func loadToolset(folder string) (toolset, error) {
	manifestData, err := os.ReadFile(filepath.Join(folder, toolsetManifestFile))
	if err != nil {
		return toolset{}, err
	}
	lockData, err := os.ReadFile(filepath.Join(folder, toolsetLockFile))
	if err != nil {
		return toolset{}, err
	}
	if _, err := os.Stat(filepath.Join(folder, toolsetPackageFile)); err != nil {
		return toolset{}, err
	}
	var m toolsetManifest
	if err := json.Unmarshal(manifestData, &m); err != nil {
		return toolset{}, err
	}
	if m.Kind != "" && m.Kind != "node" || m.RuntimeID == "" || m.Package == "" || m.Entry == "" ||
		strings.ContainsAny(m.Package+m.Entry+m.Node.Version, `'"$`+"`\\\n") {
		return toolset{}, fmt.Errorf("%s is not a Node toolset", folder)
	}
	sum := sha256.Sum256(append(append([]byte{}, manifestData...), lockData...))
	return toolset{manifest: m, id: hex.EncodeToString(sum[:])[:16], folder: folder}, nil
}

// loadToolsets is Toolset.loadAll, for the runtimes named: every Node toolset under
// folder whose manifest names one of them, in the order named. A folder that cannot be
// read is skipped.
func loadToolsets(folder string, runtimes []string) []toolset {
	if folder == "" {
		return nil
	}
	entries, _ := os.ReadDir(folder)
	byRuntime := map[string]toolset{}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		if t, err := loadToolset(filepath.Join(folder, name)); err == nil {
			byRuntime[t.manifest.RuntimeID] = t
		}
	}
	var all []toolset
	for _, r := range runtimes {
		if t, ok := byRuntime[r]; ok {
			all = append(all, t)
		}
	}
	return all
}

// canInstallToolsets is ServerFacts.canInstallToolsets: Node's official Linux builds need
// glibc 2.28 or later, and musl has none (043, R2).
func (f *facts) canInstallToolsets() bool {
	return f.glibc[0] > 2 || f.glibc[0] == 2 && f.glibc[1] >= 28
}

// libcDisplay is Libc.display.
func (f *facts) libcDisplay() string {
	switch {
	case f.musl:
		return "musl (Alpine)"
	case f.glibc[0] > 0:
		return "glibc " + strconv.Itoa(f.glibc[0]) + "." + strconv.Itoa(f.glibc[1])
	}
	return "an unknown C library"
}

// parseLibc is Libc(lddFirstLine:): `ldd (Debian GLIBC 2.36-9+deb12u14) 2.36`,
// `musl libc (aarch64)`, or anything else.
func parseLibc(line string, f *facts) {
	lower := strings.ToLower(line)
	if strings.Contains(lower, "musl") {
		f.musl = true
		return
	}
	if strings.Contains(lower, "glibc") || strings.Contains(lower, "gnu libc") || strings.HasPrefix(lower, "ldd") {
		fields := strings.Split(line, " ")
		var parts []int
		for _, p := range strings.Split(fields[len(fields)-1], ".") {
			if n, err := strconv.Atoi(p); err == nil {
				parts = append(parts, n)
			}
		}
		if len(parts) >= 2 {
			f.glibc = [2]int{parts[0], parts[1]}
		}
	}
}

// toolsetRefusal is ToolsetInstaller.refusal: why this server cannot have the toolset,
// before anything is downloaded; nil when it can.
func toolsetRefusal(f *facts, t toolset) *Problem {
	name := runtimeName(t.manifest.RuntimeID)
	switch {
	case !f.canInstallToolsets():
		return installFailed(name + " needs glibc 2.28 or later, and the server has " + f.libcDisplay() + ".")
	case f.freeBytes < t.manifest.MinFreeBytes:
		return installFailed(fmt.Sprintf("%s needs %d MB free on the server, which has %d MB.", name,
			t.manifest.MinFreeBytes>>20, max(f.freeBytes, 0)>>20))
	case t.manifest.nodeTarball(binarySuffix(f.architecture)) == "" ||
		t.manifest.Node.SHA256[binarySuffix(f.architecture)] == "":
		return &Problem{Kind: UnsupportedSystem, System: f.system, Architecture: displayArchitecture(f.architecture)}
	}
	return nil
}

// runtimeName is RuntimeCatalog's name for a runtime the app installs as a toolset.
func runtimeName(id string) string {
	switch id {
	case "claude":
		return "Claude"
	case "codex":
		return "Codex"
	case "gemini":
		return "Gemini"
	}
	return id
}

// toolsetInstallScript is ToolsetInstaller.installScript (contracts/ssh.md § 2), with
// Node's base address as dist. Exit 21: the download; 22: the checksum; 23: npm.
func toolsetInstallScript(t toolset, f *facts, dist string) string {
	m := t.manifest
	arch := binarySuffix(f.architecture)
	id := t.id
	// Only the one the probe found, so a failure is that tool's own words.
	fetch := `curl -fsSL "$1"`
	if f.downloader == "wget" {
		fetch = `wget -qO- "$1"`
	}
	var shim []string
	for _, l := range t.shimLines() {
		shim = append(shim, "'"+l+"'")
	}
	return `set -e; umask 077; T="$HOME/` + toolsetServerFolder(m.RuntimeID) + `"; P="$T/.part-` + id + `"; ` +
		`mkdir -p "$T"; chmod 700 "$HOME/.agents-server" "$HOME/.agents-server/tools" "$T" 2>/dev/null || true; ` +
		`rm -rf "$P"; mkdir -p "$P/lib"; trap 'rm -rf "$P"' EXIT; cd "$P"; ` +
		`tar -xf - -C lib; mv lib/` + toolsetManifestFile + ` .; ` +
		// Node unpacked by the control plane, for a server with no xz or no curl or wget.
		`if [ -f lib/node.tar ]; then mv lib/node.tar .; mkdir node; ` +
		`tar -xf node.tar -C node --strip-components=1; rm -f node.tar; else ` +
		`fetch() { ` + fetch + ` 2>"$P/fetch.err"; }; ` +
		`fetch '` + dist + `/` + m.nodeTarball(arch) + `' > node.tar.xz || { tail -1 "$P/fetch.err" >&2; exit 21; }; ` +
		`echo '` + m.Node.SHA256[arch] + `  node.tar.xz' | sha256sum -c - >/dev/null 2>&1 || exit 22; ` +
		`mkdir node; tar -xJf node.tar.xz -C node --strip-components=1; rm -f node.tar.xz fetch.err; fi; ` +
		`PATH="$P/node/bin:$PATH" npm ` + strings.Join(npmCIArguments, " ") + ` --prefix "$P/lib" ` +
		`--cache "$P/.npm" >"$P/npm.log" 2>&1 || { tail -5 "$P/npm.log" >&2; exit 23; }; ` +
		`rm -rf "$P/.npm" "$P/npm.log"; mkdir "$P/bin"; ` +
		`printf '%s\n' ` + strings.Join(shim, " ") + ` > "$P/bin/` + t.shimName() + `"; ` +
		`chmod 700 "$P/bin/` + t.shimName() + `"; : > "$P/ok"; ` +
		`rm -rf "$T/` + id + `"; trap - EXIT; mv "$P" "$T/` + id + `"`
}

// toolsetBundle is ToolsetInstaller.bundle: the three files as a tar, in folder, to
// stream on stdin. node, when given, is Node unpacked to a plain tar, sent as node.tar.
func toolsetBundle(t toolset, folder, node string) (string, error) {
	file := filepath.Join(folder, "toolset-"+t.manifest.RuntimeID+".tar")
	out, err := os.OpenFile(file, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	defer out.Close()
	w := tar.NewWriter(out)
	add := func(name, path string) error {
		in, err := os.Open(path)
		if err != nil {
			return err
		}
		defer in.Close()
		info, err := in.Stat()
		if err != nil {
			return err
		}
		if err := w.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: info.Size(),
			ModTime: time.Unix(0, 0), Format: tar.FormatPAX}); err != nil {
			return err
		}
		_, err = io.Copy(w, in)
		return err
	}
	for _, name := range []string{toolsetManifestFile, toolsetPackageFile, toolsetLockFile} {
		if err := add(name, filepath.Join(t.folder, name)); err != nil {
			return "", err
		}
	}
	if node != "" {
		if err := add("node.tar", node); err != nil {
			return "", err
		}
	}
	if err := w.Close(); err != nil {
		return "", err
	}
	return file, out.Close()
}

// fetchNode is the control plane's side of a toolset for a server that cannot fetch or
// unpack Node itself (#1136): Node's .tar.xz, checked against the manifest's SHA-256 and
// unpacked to a plain tar in folder, as ServerArchiveInstaller fetches an archive on the
// Mac (049).
func fetchNode(ctx context.Context, t toolset, f *facts, dist, folder string) (string, error) {
	arch := binarySuffix(f.architecture)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, dist+"/"+t.manifest.nodeTarball(arch), nil)
	if err != nil {
		return "", err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return "", installFailed("couldn’t download Node.js: " + err.Error())
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", installFailed("couldn’t download Node.js: " + response.Status)
	}
	xzFile := filepath.Join(folder, "node.tar.xz")
	out, err := os.OpenFile(xzFile, os.O_CREATE|os.O_TRUNC|os.O_RDWR, 0o600)
	if err != nil {
		return "", err
	}
	defer os.Remove(xzFile)
	defer out.Close()
	digest := sha256.New()
	if _, err := io.Copy(io.MultiWriter(out, digest), response.Body); err != nil {
		return "", installFailed("couldn’t download Node.js: " + err.Error())
	}
	if hex.EncodeToString(digest.Sum(nil)) != strings.ToLower(t.manifest.Node.SHA256[arch]) {
		return "", installFailed("The download did not match its checksum, so nothing was installed.")
	}
	if _, err := out.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	reader, err := xz.NewReader(bufio.NewReader(out))
	if err != nil {
		return "", installFailed("couldn’t unpack Node.js: " + err.Error())
	}
	plain := filepath.Join(folder, "node.tar")
	tarFile, err := os.OpenFile(plain, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	defer tarFile.Close()
	if _, err := io.Copy(tarFile, reader); err != nil {
		os.Remove(plain)
		return "", installFailed("couldn’t unpack Node.js: " + err.Error())
	}
	return plain, tarFile.Close()
}

// toolsetProblem is ToolsetInstaller.problem (contracts/ssh.md § 4).
func toolsetProblem(status int, stderr string) *Problem {
	all := lines(stderr)
	last := ""
	if len(all) > 0 {
		last = strings.TrimSpace(all[len(all)-1])
	}
	if strings.Contains(stderr, "No space left on device") {
		return installFailed("The server ran out of disk space.")
	}
	noInternet := func(markers ...string) bool {
		for _, m := range markers {
			if strings.Contains(stderr, m) {
				return true
			}
		}
		return false
	}
	switch status {
	case 21:
		if noInternet("Could not resolve host", "unable to resolve", "Temporary failure in name resolution", "Failed to connect") {
			return installFailed("The server can’t reach the internet: " + last)
		}
		return installFailed("couldn’t download Node.js: " + last)
	case 22:
		return installFailed("The download did not match its checksum, so nothing was installed.")
	case 23:
		if strings.Contains(stderr, "EINTEGRITY") {
			return installFailed("The download did not match its checksum, so nothing was installed.")
		}
		if noInternet("ENOTFOUND", "EAI_AGAIN", "ECONNREFUSED", "ETIMEDOUT") {
			return installFailed("The server can’t reach the internet: " + last)
		}
		return installFailed(last)
	}
	return orFailed(classify(status, stderr, true), last)
}

// installToolset is ToolsetInstaller.install: the toolset beside whatever is there, then
// current pointed at it (swap). A whole one with this id already there is not fetched
// again. bundles is a folder for the tar, removed by the caller.
func (i installer) installToolset(ctx context.Context, t toolset, f *facts, dist, bundles string) error {
	if refusal := toolsetRefusal(f, t); refusal != nil {
		return refusal
	}
	if f.toolsets[t.manifest.RuntimeID] != t.id && !i.toolsetInstalled(ctx, t) {
		node := ""
		if !f.xz || f.downloader == "" {
			var err error
			if node, err = fetchNode(ctx, t, f, dist, bundles); err != nil {
				return err
			}
			defer os.Remove(node)
		}
		bundle, err := toolsetBundle(t, bundles, node)
		if err != nil {
			return err
		}
		defer os.Remove(bundle)
		out, err := i.ssh.run(ctx, i.ssh.runArguments(toolsetInstallScript(t, f, dist)), bundle)
		if err != nil {
			return err
		}
		if out.status != 0 {
			return toolsetProblem(out.status, out.stderr)
		}
	}
	return i.check(ctx, `set -e; T="$HOME/`+toolsetServerFolder(t.manifest.RuntimeID)+`"; `+
		`[ -f "$T/`+t.id+`/ok" ]; ln -sfn `+quote(t.id)+` "$T/current"`)
}

// toolsetInstalled is ToolsetInstaller.isInstalled: a whole toolset with this id is on
// the server already.
func (i installer) toolsetInstalled(ctx context.Context, t toolset) bool {
	out, err := i.run(ctx, `[ -f "$HOME/`+toolsetServerFolder(t.manifest.RuntimeID)+`/`+t.id+`/ok" ]`)
	return err == nil && out.status == 0
}
