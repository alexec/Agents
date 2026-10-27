package agentsd

import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
	"github.com/ulikunitz/xz"
)

// Installing a runtime that is missing on this Mac (048, 047, 049), as DaemonCore+Install
// and RuntimeInstaller: Claude, Codex and Gemini from the app's pinned Node toolsets,
// Antigravity and OpenCode from its pinned vendor archives, the rest with the vendor's own
// script. runtimes/install answers at once with installing; the progress and the ending
// go out on runtime/changed. Each lands in <cache>/tools/<runtime>/<id>/, built in
// .part-<id>, marked whole with ok last, then made current.
//
// A Mac host installs into <cache>/tools (install_darwin.go). A Linux host (#1312) installs
// the Node toolsets the shown command left in ~/.agents-server/toolsets into
// ~/.agents-server/tools, where machines/install over ssh puts them (install_linux.go). The
// recipes are here so they test anywhere.

// nodeDistURL is where Node is published; a test serves its own.
var nodeDistURL = "https://nodejs.org/dist/"

// installTimeout is how long a vendor's script or npm may take.
var installTimeout = 5 * time.Minute

// toolsHome is where runtimes/install builds toolsets: a Mac's <cache>/tools, or a
// server's ~/.agents-server/tools. serverToolsets says which (#1312): a server takes Node
// from the manifest's Linux pins, and installs only the Node toolsets.
var (
	toolsHome      string
	serverToolsets bool
)

// serverLibc is the C library a server has, as `getconf GNU_LIBC_VERSION` says it
// ("glibc 2.36"), or "" when it says nothing (musl); a test gives its own.
var serverLibc = func() string {
	out, err := exec.Command("getconf", "GNU_LIBC_VERSION").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

type installBook struct {
	instMu   sync.Mutex
	toolsets map[string]*macToolset
	installs map[string]bool
	states   map[string]wire.RuntimeAvailability
}

// macToolset is a Toolset or an ArchiveToolset the app's bundle carries.
type macToolset struct {
	runtimeID string
	id        string
	folder    string
	// A Node toolset's.
	manifest struct {
		Kind              string `json:"kind"`
		Package           string `json:"package"`
		Entry             string `json:"entry"`
		ForwardsArguments *bool  `json:"forwardsArguments"`
		// A server's Node, by `uname -m` (Toolset.Manifest.node).
		Node *struct {
			Version string            `json:"version"`
			SHA256  map[string]string `json:"sha256"`
		} `json:"node"`
		// An archive's.
		Version      string                     `json:"version"`
		MinFreeBytes int64                      `json:"minFreeBytes"`
		Platforms    map[string]archivePlatform `json:"platforms"`
	}
	node *struct {
		Version string            `json:"version"`
		SHA256  map[string]string `json:"sha256"`
	}
}

type archivePlatform struct {
	URL         string   `json:"url"`
	SHA256      string   `json:"sha256"`
	Size        int64    `json:"size"`
	Command     string   `json:"command"`
	Arguments   []string `json:"arguments"`
	KnownBroken *string  `json:"knownBroken"`
}

func (t *macToolset) archive() bool { return t.manifest.Kind == "archive" }

// loadToolsets is Toolset.loadAll and ArchiveToolset.loadAll over the bundle's toolsets/.
// A Node toolset's id is the first sixteen hex characters of the SHA-256 of its manifest
// and lock; an archive's, of its manifest.
func loadToolsets(folder string) map[string]*macToolset {
	out := map[string]*macToolset{}
	names, _ := os.ReadDir(folder)
	for _, n := range names {
		dir := filepath.Join(folder, n.Name())
		manifest, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
		if err != nil {
			continue
		}
		t := &macToolset{folder: dir}
		var head struct {
			RuntimeID string `json:"runtimeID"`
		}
		if json.Unmarshal(manifest, &head) != nil || head.RuntimeID == "" || json.Unmarshal(manifest, &t.manifest) != nil {
			continue
		}
		t.runtimeID = head.RuntimeID
		sum := sha256.New()
		sum.Write(manifest)
		if t.archive() {
			ok := true
			for _, p := range t.manifest.Platforms {
				ok = ok && archiveFormat(p.URL) != ""
			}
			if !ok {
				continue
			}
		} else {
			lock, err := os.ReadFile(filepath.Join(dir, "package-lock.json"))
			if err != nil || t.manifest.Package == "" || t.manifest.Entry == "" {
				continue
			}
			sum.Write(lock)
			if b, err := os.ReadFile(filepath.Join(dir, "mac-node.json")); err == nil {
				json.Unmarshal(b, &t.node)
			}
		}
		t.id = hex.EncodeToString(sum.Sum(nil))[:16]
		out[t.runtimeID] = t
	}
	return out
}

func archiveFormat(url string) string {
	u := strings.ToLower(url)
	switch {
	case strings.HasSuffix(u, ".zip"):
		return "zip"
	case strings.HasSuffix(u, ".tar.gz"), strings.HasSuffix(u, ".tgz"):
		return "tarGz"
	}
	return ""
}

// macArch is MacNode.hostArchitecture; macPlatform is ArchiveToolset.macPlatform.
func macArch() string {
	if goruntime.GOARCH == "arm64" {
		return "arm64"
	}
	return "x64"
}

func macPlatform() string {
	if goruntime.GOARCH == "arm64" {
		return "darwin-aarch64"
	}
	return "darwin-x86_64"
}

// serverArch is a server's `uname -m`, the key of the manifest's Node pins.
func serverArch() string {
	if goruntime.GOARCH == "arm64" {
		return "aarch64"
	}
	return "x86_64"
}

// nodePin is the Node this host installs a Node toolset with: the Mac's from mac-node.json,
// or a server's from the manifest; "" when the toolset pins none for this machine.
func (t *macToolset) nodePin() (version, sum string) {
	if serverToolsets {
		if n := t.manifest.Node; n != nil {
			return n.Version, n.SHA256[serverArch()]
		}
		return "", ""
	}
	if t.node != nil {
		return t.node.Version, t.node.SHA256[macArch()]
	}
	return "", ""
}

// platform is the archive's entry for this Mac, or why there is none.
func (t *macToolset) platform() (archivePlatform, string) {
	p, ok := t.manifest.Platforms[macPlatform()]
	if !ok {
		return archivePlatform{}, fmt.Sprintf("%s publishes no %s for this Mac.", vendorOf(t), runtimeName(t.runtimeID))
	}
	if p.KnownBroken != nil {
		return archivePlatform{}, *p.KnownBroken
	}
	return p, ""
}

func vendorOf(t *macToolset) string {
	for _, p := range t.manifest.Platforms {
		host := p.URL
		if _, rest, ok := strings.Cut(host, "://"); ok {
			host, _, _ = strings.Cut(rest, "/")
		}
		switch {
		case host == "google.com" || strings.HasSuffix(host, ".google.com"):
			return "Google"
		case host == "github.com" || strings.HasSuffix(host, ".github.com"):
			return "GitHub"
		}
		return host
	}
	return "the vendor"
}

// installRecipes is RuntimeCatalog's install for each runtime.
var installRecipes = map[string]wire.RuntimeInstall{
	"claude":      {Toolset: &wire.RuntimeInstallToolset{RuntimeID: "claude"}},
	"codex":       {Toolset: &wire.RuntimeInstallToolset{RuntimeID: "codex"}},
	"gemini":      {Toolset: &wire.RuntimeInstallToolset{RuntimeID: "gemini"}},
	"antigravity": {Toolset: &wire.RuntimeInstallToolset{RuntimeID: "antigravity"}},
	"opencode":    {Toolset: &wire.RuntimeInstallToolset{RuntimeID: "opencode"}},
	"grok":        {Script: &wire.RuntimeInstallScript{URL: "https://x.ai/cli/install.sh", Shell: "bash"}},
	"copilot":     {Script: &wire.RuntimeInstallScript{URL: "https://gh.io/copilot-install", Shell: "bash"}},
	"cursor":      {Script: &wire.RuntimeInstallScript{URL: "https://cursor.com/install", Shell: "bash"}},
}

// recipe is RuntimeInstaller.recipe: what this Mac can carry out, or nil when all it can
// offer is the vendor's page.
func (d *Daemon) recipe(id string) *wire.RuntimeInstall {
	r, ok := installRecipes[id]
	if !ok || d.toolsets == nil {
		return nil
	}
	// A server installs only the Node toolsets (#1312): a vendor's script or archive is
	// the person's own to run there.
	if serverToolsets && r.Toolset == nil {
		return nil
	}
	if r.Toolset != nil {
		t := d.toolsets[r.Toolset.RuntimeID]
		switch {
		case t == nil:
			return nil
		case t.archive():
			if _, why := t.platform(); why != "" || serverToolsets {
				return nil
			}
		default:
			if _, sum := t.nodePin(); sum == "" {
				return nil
			}
		}
	}
	return &r
}

// appToolset is RuntimeDiscovery.appToolset: the copy runtimes/install made, when it is whole.
func appToolset(r *runtimeDef) string {
	if toolsHome == "" {
		return ""
	}
	return toolsetShim(filepath.Join(toolsHome, r.ID), r.Executable)
}

// overlay is DaemonCore.overlaid's install half: the button where this host can carry it
// out, what an install says over what discovery sees, and whether the app's copy is older
// than the one the app carries.
func (d *Daemon) overlay(s *wire.RuntimeStatus) {
	if d.toolsets == nil {
		return
	}
	s.Runtime.Install = d.recipe(s.Runtime.ID)
	d.instMu.Lock()
	state, ok := d.states[s.Runtime.ID]
	d.instMu.Unlock()
	if ok && (state.Installing != nil || s.Availability.Available == nil) {
		s.Availability = state
	}
	s.Outdated = s.Availability.Available != nil && d.outdated(s.Runtime.ID, s.Availability.Available.Path)
}

// outdated is RuntimeDiscovery.isOutdated: the app's own copy is in use, and is not the
// toolset this app carries.
func (d *Daemon) outdated(id, path string) bool {
	t := d.toolsets[id]
	r := runtimeByID(id)
	if t == nil || r == nil || path == "" || path != appToolset(r) {
		return false
	}
	cur, err := os.Readlink(filepath.Join(toolsHome, id, "current"))
	return err == nil && cur != t.id
}

func (d *Daemon) statusOf(r *runtimeDef) wire.RuntimeStatus {
	for _, s := range d.runtimeStatuses() {
		if s.Runtime.ID == r.ID {
			return s
		}
	}
	return wire.RuntimeStatus{Runtime: r.Runtime, CheckedAt: now()}
}

// installRuntime is runtimes/install: started and left running.
func (d *Daemon) installRuntime(c *Client, id string) (wire.RuntimeStatus, error) {
	r := runtimeByID(id)
	if r == nil {
		return wire.RuntimeStatus{}, &Error{Code: CodeRuntimeNotFound, Message: "There is no runtime called " + id + "."}
	}
	recipe := d.recipe(id)
	if recipe == nil {
		return wire.RuntimeStatus{}, &Error{Code: wire.FailureNotSupported,
			Message: fmt.Sprintf("%s can’t be installed from here. Install it from %s.", r.Name, r.InstallPage)}
	}
	if c != nil && c.conn.Device() != "" {
		return wire.RuntimeStatus{}, &Error{Code: wire.FailureNotSupported, Message: "Install " + r.Name + " from the Mac."}
	}
	d.instMu.Lock()
	if d.installs[id] {
		d.instMu.Unlock()
		return d.statusOf(r), nil
	}
	path, _, _ := locateFor(r)
	if path != "" && !d.outdated(id, path) {
		delete(d.states, id)
		d.instMu.Unlock()
		return d.statusOf(r), nil
	}
	if d.installs == nil {
		d.installs, d.states = map[string]bool{}, map[string]wire.RuntimeAvailability{}
	}
	d.installs[id] = true
	d.instMu.Unlock()
	log.Printf("installing %s", id)
	d.setInstallState(r, wire.RuntimeAvailability{Installing: &wire.RuntimeAvailabilityInstalling{}})
	safe.Go("install "+id, func() {
		result := d.install(r, *recipe, func(step string) {
			d.instMu.Lock()
			going := d.installs[id]
			d.instMu.Unlock()
			if going {
				d.setInstallState(r, wire.RuntimeAvailability{Installing: &wire.RuntimeAvailabilityInstalling{Progress: &step}})
			}
		})
		d.instMu.Lock()
		delete(d.installs, id)
		d.instMu.Unlock()
		if result.Available != nil {
			log.Printf("installed %s", id)
			d.instMu.Lock()
			delete(d.states, id)
			d.instMu.Unlock()
			Broadcast(d, wire.NotifyRuntimeChanged, d.statusOf(r))
		} else {
			log.Printf("installing %s failed: %s", id, result.InstallFailed.Reason)
			d.setInstallState(r, result)
		}
	})
	return d.statusOf(r), nil
}

func (d *Daemon) setInstallState(r *runtimeDef, s wire.RuntimeAvailability) {
	d.instMu.Lock()
	d.states[r.ID] = s
	d.instMu.Unlock()
	Broadcast(d, wire.NotifyRuntimeChanged, d.statusOf(r))
}

func installFailed(reason string) wire.RuntimeAvailability {
	return wire.RuntimeAvailability{InstallFailed: &wire.RuntimeAvailabilityInstallFailed{Reason: reason}}
}

// install is RuntimeInstaller.install: the result is decided by looking again, so a
// script that exits 0 and leaves nothing where the app looks is a failure.
func (d *Daemon) install(r *runtimeDef, recipe wire.RuntimeInstall, progress func(string)) wire.RuntimeAvailability {
	var err error
	switch {
	case recipe.Toolset != nil:
		t := d.toolsets[recipe.Toolset.RuntimeID]
		if t.archive() {
			err = t.installArchive(progress)
		} else {
			err = t.installNode(progress)
		}
	case recipe.Script != nil:
		url := string(recipe.Script.URL)
		// An unreleased build points every vendor script at a walk's own (048).
		if o := os.Getenv("AGENTS_TEST_INSTALL_SCRIPT"); o != "" && buildinfo.Version == "dev" {
			url = o
		}
		host := url
		if _, rest, ok := strings.Cut(url, "://"); ok {
			host, _, _ = strings.Cut(rest, "/")
		}
		progress("Running " + host + "’s installer")
		err = runScript(url, recipe.Script.Shell, r.Name)
	}
	if err != nil {
		var f installFailure
		if errors.As(err, &f) {
			return installFailed(string(f))
		}
		return installFailed(fmt.Sprintf("Installing %s failed: %v", r.Name, err))
	}
	path, _, looked := locateFor(r)
	if path == "" {
		if len(looked) > 4 {
			looked = looked[:4]
		}
		return installFailed(fmt.Sprintf("%s installed, but not where the app looks: %s…", r.Name, strings.Join(looked, ", ")))
	}
	return wire.RuntimeAvailability{Available: &wire.RuntimeAvailabilityAvailable{Path: path}}
}

// installFailure is a failure said in a whole sentence.
type installFailure string

func (f installFailure) Error() string { return string(f) }

// step runs one command, and says its output and whether it ran out of time.
func step(timeout time.Duration, dir string, env []string, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir, cmd.Env = dir, env
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return string(out), context.DeadlineExceeded
	}
	return string(out), err
}

func tail(out string, n int) string {
	var lines []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " ")
}

// runScript is `curl -fsSL <url> | <shell>`, with pipefail so a download that fails is the
// failure rather than an empty script that "succeeds".
func runScript(url, shell, name string) error {
	home, _ := os.UserHomeDir()
	out, err := step(installTimeout, home, loginEnvironment(), "/bin/bash", "-c",
		`set -o pipefail; curl -fsSL "$1" | "$2"`, "install", url, shell)
	switch {
	case err == context.DeadlineExceeded:
		return installFailure(name + "’s installer took more than five minutes, so it was stopped.")
	case err != nil:
		if t := tail(out, 3); t != "" {
			return installFailure(name + "’s installer failed: " + t)
		}
		return installFailure(name + "’s installer failed.")
	}
	return nil
}

// home is the runtime's folder under tools/, through any link (npm resolves --prefix):
// /tmp is /private/tmp on a Mac.
func (t *macToolset) home() (string, error) {
	dir := filepath.Join(toolsHome, t.runtimeID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(dir)
}

// build makes <home>/<id> with make, unless it is whole already, and makes it current.
func (t *macToolset) build(make func(part string) error) error {
	home, err := t.home()
	if err != nil {
		return err
	}
	finished := filepath.Join(home, t.id)
	if _, err := os.Stat(filepath.Join(finished, "ok")); err != nil {
		part := filepath.Join(home, ".part-"+t.id)
		os.RemoveAll(part)
		if err := make(part); err != nil {
			os.RemoveAll(part)
			if errors.Is(err, syscall.ENOSPC) {
				return installFailure("There isn’t room on " + thisMachine() + " to install " + runtimeName(t.runtimeID) + ".")
			}
			return err
		}
		os.RemoveAll(finished)
		if err := os.Rename(part, finished); err != nil {
			return err
		}
	}
	return pointCurrent(home, t.id)
}

// pointCurrent is `ln -sfn <id> current`, by a new link renamed over the old, so there is
// never a moment without one.
func pointCurrent(home, id string) error {
	next := filepath.Join(home, fmt.Sprintf(".current-%d", time.Now().UnixNano()))
	if err := os.Symlink(id, next); err != nil {
		return err
	}
	if err := os.Rename(next, filepath.Join(home, "current")); err != nil {
		os.Remove(next)
		return installFailure("couldn’t make " + id + " the current toolset")
	}
	return nil
}

// tidy removes every toolset but the current one, and anything half-built. Only at the
// host's start, when nothing can be running from them.
func (t *macToolset) tidy() {
	home := filepath.Join(toolsHome, t.runtimeID)
	keep, _ := os.Readlink(filepath.Join(home, "current"))
	names, _ := os.ReadDir(home)
	for _, n := range names {
		if n.Name() != "current" && n.Name() != keep && !strings.HasPrefix(n.Name(), ".current-") {
			os.RemoveAll(filepath.Join(home, n.Name()))
		}
	}
}

// download fetches url into file, and checks its size (when given) and its SHA-256.
func download(url, file string, size int64, sha string, what string, progress func(int64)) error {
	resp, err := http.Get(url)
	if err != nil {
		return installFailure("Couldn’t reach the internet to download " + what + ".")
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		host := url
		if _, rest, ok := strings.Cut(url, "://"); ok {
			host, _, _ = strings.Cut(rest, "/")
		}
		return installFailure(fmt.Sprintf("Couldn’t download %s: %s answered %d", what, host, resp.StatusCode))
	}
	f, err := os.Create(file)
	if err != nil {
		return err
	}
	defer f.Close()
	sum := sha256.New()
	var written, said int64
	buf := make([]byte, 1<<20)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, err := f.Write(buf[:n]); err != nil {
				return err
			}
			sum.Write(buf[:n])
			written += int64(n)
			if progress != nil && written-said >= 4_000_000 {
				said = written
				progress(written)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return installFailure("Couldn’t download " + what + ": " + rerr.Error())
		}
	}
	if size > 0 && written != size || hex.EncodeToString(sum.Sum(nil)) != strings.ToLower(sha) {
		return installFailure("The download didn’t match its checksum, so nothing was installed.")
	}
	return nil
}

func copyFile(from, to string) error {
	b, err := os.ReadFile(from)
	if err != nil {
		return err
	}
	return os.WriteFile(to, b, 0o644)
}

func writeShim(part, name string, lines []string) error {
	bin := filepath.Join(part, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(bin, name), []byte(strings.Join(lines, "\n")+"\n"), 0o700); err != nil {
		return err
	}
	// Last: a toolset without this is never used.
	return os.WriteFile(filepath.Join(part, "ok"), nil, 0o644)
}

func (t *macToolset) shimName() string {
	if r := runtimeByID(t.runtimeID); r != nil {
		return r.Executable
	}
	if t.archive() {
		return t.runtimeID
	}
	return "npx"
}

// installNode is MacToolsetInstaller.install: Node from nodejs.org checked against the
// app's pin, the adapter with `npm ci` against the app's lock, and the shim.
func (t *macToolset) installNode(progress func(string)) error {
	name := runtimeName(t.runtimeID)
	v, sum := t.nodePin()
	if sum == "" {
		return installFailure("This build of the app carries no Node.js for " + thisMachine() + ".")
	}
	if serverToolsets {
		// Node's own Linux builds need glibc 2.28 or later, and musl has none (043, R2).
		if libc := serverLibc(); !glibcAtLeast(libc, 2, 28) {
			has := "musl or an unknown C library"
			if libc != "" {
				has = libc
			}
			return installFailure(name + " needs glibc 2.28 or later, and this server has " + has + ".")
		}
	}
	return t.build(func(part string) error {
		lib := filepath.Join(part, "lib")
		if err := os.MkdirAll(lib, 0o755); err != nil {
			return err
		}
		for _, f := range []string{"package.json", "package-lock.json"} {
			if err := copyFile(filepath.Join(t.folder, f), filepath.Join(lib, f)); err != nil {
				return err
			}
		}
		if err := copyFile(filepath.Join(t.folder, "manifest.json"), filepath.Join(part, "manifest.json")); err != nil {
			return err
		}
		progress("Downloading Node.js " + v)
		node := filepath.Join(part, "node")
		os.MkdirAll(node, 0o755)
		base := strings.TrimSuffix(nodeDistURL, "/") + "/" + v + "/node-" + v
		if serverToolsets {
			// A tar.xz, unpacked here: a minimal Debian has no xz (043).
			tarball := filepath.Join(part, "node.tar.xz")
			if err := download(base+"-linux-"+macArch()+".tar.xz", tarball, 0, sum, "Node.js", nil); err != nil {
				return err
			}
			progress("Unpacking Node.js")
			if err := untarXZ(tarball, node); err != nil {
				if errors.Is(err, syscall.ENOSPC) {
					return err
				}
				return installFailure("Couldn’t unpack Node.js: " + err.Error())
			}
			os.Remove(tarball)
		} else {
			tarball := filepath.Join(part, "node.tar.gz")
			if err := download(base+"-darwin-"+macArch()+".tar.gz", tarball, 0, sum, "Node.js", nil); err != nil {
				return err
			}
			progress("Unpacking Node.js")
			if out, err := step(installTimeout, part, loginEnvironment(), "/usr/bin/tar", "-xzf", tarball, "-C", node, "--strip-components=1"); err != nil {
				return unpackProblem(out, "Couldn’t download Node.js: "+tail(out, 1))
			}
			os.Remove(tarball)
		}
		progress("Installing " + name)
		env := loginEnvironment()
		for i, kv := range env {
			if strings.HasPrefix(kv, "PATH=") {
				env[i] = "PATH=" + filepath.Join(node, "bin") + ":" + strings.TrimPrefix(kv, "PATH=")
			}
		}
		args := []string{"ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund", "--prefix", lib, "--cache", filepath.Join(part, ".npm")}
		out, err := step(2*installTimeout, part, env, filepath.Join(node, "bin", "npm"), args...)
		if err == context.DeadlineExceeded {
			return installFailure("Installing " + name + " failed: it took more than ten minutes")
		}
		if err != nil {
			return npmProblem(out, name)
		}
		os.RemoveAll(filepath.Join(part, ".npm"))
		forwards := ""
		if t.manifest.ForwardsArguments != nil && *t.manifest.ForwardsArguments {
			forwards = ` "$@"`
		}
		entry := "lib/node_modules/" + t.manifest.Package + "/" + t.manifest.Entry
		return writeShim(part, t.shimName(), []string{"#!/bin/sh",
			"# Agents: runs the " + t.manifest.Package + " this toolset was installed with.",
			`d=$(cd "$(dirname "$0")/.." && pwd -P)`,
			`PATH="$d/node/bin:$PATH" exec "$d/node/bin/node" "$d/` + entry + `"` + forwards})
	})
}

// installArchive is MacArchiveInstaller.install: the vendor's archive for this Mac,
// checked against the app's pin and unpacked by the host, so nothing is quarantined.
func (t *macToolset) installArchive(progress func(string)) error {
	name := runtimeName(t.runtimeID)
	p, why := t.platform()
	if why != "" {
		return installFailure(why)
	}
	if home, err := t.home(); err == nil {
		var st syscall.Statfs_t
		if syscall.Statfs(home, &st) == nil && int64(st.Bavail)*int64(st.Bsize) < t.manifest.MinFreeBytes {
			return installFailure(fmt.Sprintf("Not enough room: %s needs about %.1f GB free.", name, float64(t.manifest.MinFreeBytes)/1e9))
		}
	}
	return t.build(func(part string) error {
		if err := os.MkdirAll(part, 0o755); err != nil {
			return err
		}
		if err := copyFile(filepath.Join(t.folder, "manifest.json"), filepath.Join(part, "manifest.json")); err != nil {
			return err
		}
		total := megabytes(p.Size)
		progress(fmt.Sprintf("Downloading %s (%s)", name, total))
		tarGz := archiveFormat(p.URL) == "tarGz"
		archive := filepath.Join(part, "archive.zip")
		if tarGz {
			archive = filepath.Join(part, "archive.tar.gz")
		}
		if err := download(p.URL, archive, p.Size, p.SHA256, name, func(n int64) {
			progress(fmt.Sprintf("Downloading %s: %s of %s", name, megabytes(n), total))
		}); err != nil {
			return err
		}
		progress("Unpacking " + name)
		var out string
		var err error
		if tarGz {
			out, err = step(installTimeout, part, loginEnvironment(), "/usr/bin/tar", "-xzf", archive, "-C", part)
		} else {
			out, err = step(installTimeout, part, loginEnvironment(), "/usr/bin/ditto", "-x", "-k", archive, part)
		}
		if err != nil {
			return unpackProblem(out, "Installing "+name+" failed: couldn’t unpack it: "+tail(out, 1))
		}
		os.Remove(archive)
		if fi, err := os.Stat(filepath.Join(part, p.Command)); err != nil || fi.Mode()&0o111 == 0 {
			return installFailure("Installing " + name + " failed: the download has no " + p.Command)
		}
		args := ""
		for _, a := range p.Arguments {
			args += ` "` + a + `"`
		}
		return writeShim(part, t.shimName(), []string{"#!/bin/sh",
			"# Agents: runs the " + t.runtimeID + " " + t.manifest.Version + " this toolset was installed with.",
			`d=$(cd "$(dirname "$0")/.." && pwd -P)`,
			`exec "$d/` + p.Command + `"` + args + ` "$@"`})
	})
}

func megabytes(n int64) string { return fmt.Sprintf("%d MB", max(1, (n+500_000)/1_000_000)) }

func unpackProblem(out, otherwise string) error {
	if strings.Contains(out, "No space left on device") {
		return syscall.ENOSPC
	}
	return installFailure(otherwise)
}

// npmProblem is MacToolsetInstaller.npmProblem: what npm said was wrong.
func npmProblem(out, name string) error {
	var lines []string
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		for _, p := range []string{"npm error", "npm ERR!"} {
			if strings.HasPrefix(l, p) {
				l = strings.TrimSpace(strings.TrimPrefix(l, p))
			}
		}
		if l != "" && !strings.HasPrefix(l, "A complete log of this run") {
			lines = append(lines, l)
		}
	}
	last := ""
	for i, l := range lines {
		if strings.HasPrefix(l, "code ") && i+1 < len(lines) {
			last = lines[i+1]
			break
		}
	}
	if last == "" && len(lines) > 0 {
		last = lines[len(lines)-1]
	}
	switch {
	case strings.Contains(out, "No space left on device") || strings.Contains(out, "ENOSPC"):
		return syscall.ENOSPC
	case strings.Contains(out, "EINTEGRITY"):
		return installFailure("The download didn’t match its checksum, so nothing was installed.")
	case strings.Contains(out, "ENOTFOUND") || strings.Contains(out, "EAI_AGAIN") || strings.Contains(out, "ECONNREFUSED") || strings.Contains(out, "ETIMEDOUT"):
		return installFailure("Couldn’t reach the internet to download " + name + ".")
	}
	return installFailure("Installing " + name + " failed: " + last)
}

// serveInstall loads the bundle's toolsets from folder, tidies what is left of older ones
// and serves runtimes/install, on a Mac into tools; install_darwin.go calls it.
func (d *Daemon) serveInstall(tools, folder string) {
	macToolsHome, toolsHome, serverToolsets = tools, tools, false
	d.loadAndServeInstall(folder)
}

// serveServerInstall is serveInstall on a server (#1312): from the toolsets in folder into
// ~/.agents-server/tools, where discovery looks first. install_linux.go calls it.
func (d *Daemon) serveServerInstall(folder string) {
	toolsHome, serverToolsets = filepath.Dir(toolsetFolder("claude")), true
	d.loadAndServeInstall(folder)
}

func (d *Daemon) loadAndServeInstall(folder string) {
	d.toolsets = loadToolsets(folder)
	ids := make([]string, 0, len(d.toolsets))
	for id := range d.toolsets {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		d.toolsets[id].tidy()
	}
	On(d, wire.CallRuntimesInstall, func(_ context.Context, c *Client, r wire.RuntimeRequest) (wire.RuntimeStatus, error) {
		return d.installRuntime(c, r.RuntimeID)
	})
}

// thisMachine is how an install's words name the machine: this Mac, or this server.
func thisMachine() string {
	if serverToolsets {
		return "this server"
	}
	return "this Mac"
}

// glibcAtLeast says whether libc, as getconf says it ("glibc 2.36"), is that glibc or later.
func glibcAtLeast(libc string, major, minor int) bool {
	version, ok := strings.CutPrefix(libc, "glibc ")
	if !ok {
		return false
	}
	var have [2]int
	for i, p := range strings.SplitN(version, ".", 3) {
		if i > 1 {
			break
		}
		n := 0
		for _, c := range p {
			if c < '0' || c > '9' {
				break
			}
			n = n*10 + int(c-'0')
		}
		have[i] = n
	}
	return have[0] > major || have[0] == major && have[1] >= minor
}

// untarXZ unpacks Node's tar.xz into dest, dropping its first folder (tar
// --strip-components=1): files, folders and the links npm and npx are. Nothing may land
// outside dest.
func untarXZ(file, dest string) error {
	f, err := os.Open(file)
	if err != nil {
		return err
	}
	defer f.Close()
	x, err := xz.NewReader(f)
	if err != nil {
		return err
	}
	r := tar.NewReader(x)
	for {
		h, err := r.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		_, rest, found := strings.Cut(strings.TrimPrefix(h.Name, "./"), "/")
		rest = strings.TrimSuffix(rest, "/")
		if !found || rest == "" {
			continue
		}
		target := filepath.Join(dest, rest)
		if !strings.HasPrefix(target, filepath.Clean(dest)+string(filepath.Separator)) {
			return fmt.Errorf("%s is outside the archive", h.Name)
		}
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(h.Mode)&0o755|0o600)
			if err != nil {
				return err
			}
			_, err = io.Copy(out, r)
			if cerr := out.Close(); err == nil {
				err = cerr
			}
			if err != nil {
				return err
			}
		case tar.TypeSymlink:
			if filepath.IsAbs(h.Linkname) || !strings.HasPrefix(filepath.Join(filepath.Dir(target), h.Linkname), filepath.Clean(dest)+string(filepath.Separator)) {
				return fmt.Errorf("%s links outside the archive", h.Name)
			}
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			os.Remove(target)
			if err := os.Symlink(h.Linkname, target); err != nil {
				return err
			}
		}
	}
}
