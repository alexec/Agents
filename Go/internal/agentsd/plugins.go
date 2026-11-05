package agentsd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A folder's plugins, each approved or waiting (DaemonCore+PluginApproval). A plugin in
// .agents/plugins can carry hooks and MCP servers that a runtime runs by itself, so a
// digest of its folder is kept here, outside the folder, in plugin-approvals.json, and one
// that no longer matches waits for the person's Approve. Every plugin present when approval
// began is approved as it stands.
//
// This host lists and approves them, in the same file as the Swift host; it does not yet
// hand plugins to a session.

func (d *Daemon) registerPlugins() {
	On(d, wire.CallPluginsList, func(ctx context.Context, c *Client, r wire.PluginsListRequest) (wire.PluginsList, error) {
		folder := pluginFolder(store.FolderPath(r.Folder))
		return wire.PluginsList{Folder: store.FolderURL(folder), Plugins: d.folderPlugins(folder)}, nil
	})
	On(d, wire.CallPluginsApprove, func(ctx context.Context, c *Client, r wire.PluginApproveRequest) (wire.PluginsList, error) {
		return d.approvePlugin(r)
	})
}

// pluginApprovals is plugin-approvals.json.
type pluginApprovals struct {
	ApprovalsBegan *wire.Date        `json:"approvalsBegan,omitempty"`
	Approved       map[string]string `json:"approved"`
	// Denied is the person's Deny, by plugin: the digest denied. Kept as it is.
	Denied map[string]string `json:"denied,omitempty"`
}

var pluginMu sync.Mutex

func (d *Daemon) pluginApprovalsPath() string {
	return filepath.Join(d.Store.Loc.Root, "plugin-approvals.json")
}

func beganMarker(path string) string {
	return filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".began")
}

// loadPluginApprovals reads the file (ApprovalFile.read). One that is there and cannot be
// read approves nothing, and so does one that lost approvalsBegan once it had begun.
// Approval begins here the first time, with every plugin in a folder approved as it is.
func (d *Daemon) loadPluginApprovals() (r pluginApprovals, unreadable bool) {
	path := d.pluginApprovalsPath()
	_, markErr := os.Stat(beganMarker(path))
	marked := markErr == nil
	b, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist) && marked:
		return pluginApprovals{Approved: map[string]string{}}, true
	case errors.Is(err, os.ErrNotExist):
	case err != nil || diskjson.Unmarshal(b, &r) != nil:
		return pluginApprovals{Approved: map[string]string{}}, true
	case r.ApprovalsBegan == nil && marked:
		return pluginApprovals{Approved: map[string]string{}}, true
	}
	if r.Approved == nil {
		r.Approved = map[string]string{}
	}
	if r.ApprovalsBegan == nil {
		for _, p := range d.folders(true) {
			for _, plugin := range pluginFolders(store.FolderPath(p.Folder.Folder)) {
				if digest, ok := pluginDigest(plugin); ok {
					r.Approved[pluginKey(plugin)] = digest
				}
			}
		}
		began := now()
		r.ApprovalsBegan = &began
		d.savePluginApprovals(r)
	} else if !marked {
		os.WriteFile(beganMarker(path), []byte(approvalsBeganNote), 0o644)
	}
	return r, false
}

// savePluginApprovals writes the file; over one that could not be read, only the person's
// Approve writes, and the old one is kept aside first.
func (d *Daemon) savePluginApprovals(r pluginApprovals) error {
	path := d.pluginApprovalsPath()
	if err := writeStore(path, r); err != nil {
		return err
	}
	if r.ApprovalsBegan != nil {
		if _, err := os.Stat(beganMarker(path)); err != nil {
			os.WriteFile(beganMarker(path), []byte(approvalsBeganNote), 0o644)
		}
	}
	return nil
}

// folderPlugins is every plugin in the folder belongs to, approved or waiting.
func (d *Daemon) folderPlugins(folder string) []wire.FolderPlugin {
	pluginMu.Lock()
	records, unreadable := d.loadPluginApprovals()
	pluginMu.Unlock()
	parent := pluginFolder(folder)
	out := []wire.FolderPlugin{}
	for _, plugin := range pluginFolders(folder) {
		out = append(out, wire.FolderPlugin{FolderPath: store.FolderURL(parent), Folder: store.FolderURL(plugin),
			Name: filepath.Base(plugin), Carries: pluginCarries(plugin),
			AwaitingApproval: d.pluginAwaiting(plugin, records, unreadable)})
	}
	return out
}

// pluginAwaiting is what a plugin waits on, or nil when its folder is the one approved.
func (d *Daemon) pluginAwaiting(plugin string, r pluginApprovals, unreadable bool) *wire.WorkflowApproval {
	digest, ok := pluginDigest(plugin)
	if !ok {
		return nil
	}
	approved, had := r.Approved[pluginKey(plugin)]
	if had && approved == digest && !unreadable {
		return nil
	}
	a := &wire.WorkflowApproval{Digest: digest, IsNew: !had || unreadable}
	if unreadable {
		note := filepath.Base(d.pluginApprovalsPath()) + " could not be read, so nothing is approved until you approve it again."
		a.Note = &note
	}
	return a
}

// approvePlugin is the person's Approve. Only the folder they were shown: if it has changed
// since, nothing is approved and they are told.
func (d *Daemon) approvePlugin(r wire.PluginApproveRequest) (wire.PluginsList, error) {
	plugin := filepath.Clean(store.FolderPath(r.Plugin))
	folder := filepath.Dir(filepath.Dir(filepath.Dir(plugin)))
	listed := false
	if strings.HasSuffix(filepath.Dir(plugin), "/.agents/plugins") {
		for _, p := range pluginFolders(folder) {
			if pluginKey(p) == pluginKey(plugin) {
				listed = true
			}
		}
	}
	if !listed {
		return wire.PluginsList{}, Invalid("%s is not a plugin in a folder's .agents/plugins.", filepath.Base(plugin))
	}
	if digest, _ := pluginDigest(plugin); digest != r.Digest {
		return wire.PluginsList{}, &Error{Code: wire.FailureNotChanged,
			Message: filepath.Base(plugin) + " changed after you looked at it, so it was not approved. Look again."}
	}
	pluginMu.Lock()
	records, unreadable := d.loadPluginApprovals()
	if unreadable {
		path := d.pluginApprovalsPath()
		if b, err := os.ReadFile(path); err == nil {
			os.WriteFile(fmt.Sprintf("%s.unreadable-%d", path, time.Now().Unix()), b, 0o644)
			store.TrimSetAsides(path)
		}
		began := now()
		records = pluginApprovals{ApprovalsBegan: &began, Approved: map[string]string{}}
	}
	records.Approved[pluginKey(plugin)] = r.Digest
	err := d.savePluginApprovals(records)
	pluginMu.Unlock()
	if err != nil {
		return wire.PluginsList{}, &Error{Code: CodeServer, Message: "The plugin approval could not be saved: " + err.Error()}
	}
	log.Printf("plugins: %s in %s approved", filepath.Base(plugin), folder)
	list := wire.PluginsList{Folder: store.FolderURL(folder), Plugins: d.folderPlugins(folder)}
	Broadcast(d, wire.NotifyPluginsChanged, list)
	return list, nil
}

// pluginKey is the folder as listed, cleaned: what an approval is kept under.
func pluginKey(plugin string) string { return filepath.Clean(plugin) }

// pluginFolder is the folder a working folder belongs to: itself, or for one of the
// app's worktrees, the folder it was made from (DotAgents.folderPath).
func pluginFolder(cwd string) string {
	path := filepath.Clean(cwd)
	if resolved, err := store.Resolve(path); err == nil {
		path = resolved
	}
	if i := strings.Index(path, "/.agents/worktrees/"); i >= 0 {
		path = path[:i]
	}
	return path
}

// pluginFolders is every folder in the folder's .agents/plugins, by name, a link to a
// folder included.
func pluginFolders(cwd string) []string {
	dir := filepath.Join(pluginFolder(cwd), ".agents", "plugins")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	var out []string
	for _, n := range names {
		if strings.HasPrefix(n, ".") {
			continue
		}
		p := filepath.Join(dir, n)
		if info, err := os.Stat(p); err == nil && info.IsDir() {
			out = append(out, p)
		}
	}
	return out
}

// The digest is of the folder as a runtime loads it: every file's path and content, every
// folder's path, every link's path and destination, and for a link to a file, that file's
// content too. .DS_Store is left out. It is kept per folder against a stamp of what lstat
// says of every entry, so a folder carrying node_modules is not read again unchanged.
var pluginDigests = struct {
	sync.Mutex
	m map[string][2]string // key → stamp, digest
}{m: map[string][2]string{}}

// pluginDigest is the digest of plugin's folder; false when it cannot be read at all.
func pluginDigest(plugin string) (string, bool) {
	key := filepath.Clean(plugin)
	stamp, stamped := pluginStamp(plugin)
	pluginDigests.Lock()
	if c, ok := pluginDigests.m[key]; ok && stamped && c[0] == stamp {
		pluginDigests.Unlock()
		return c[1], c[1] != ""
	}
	pluginDigests.Unlock()
	digest, ok := computePluginDigest(plugin)
	if stamped {
		pluginDigests.Lock()
		if len(pluginDigests.m) >= 256 {
			pluginDigests.m = map[string][2]string{}
		}
		pluginDigests.m[key] = [2]string{stamp, digest}
		pluginDigests.Unlock()
	}
	return digest, ok
}

func pluginStamp(plugin string) (string, bool) {
	h := sha256.New()
	if dest, err := os.Readlink(plugin); err == nil {
		fmt.Fprintln(h, dest)
	}
	root, err := store.Resolve(plugin)
	if err != nil {
		return "", false
	}
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		return "", false
	}
	fmt.Fprintln(h, statLine(root, false))
	filepath.WalkDir(root, func(path string, e fs.DirEntry, err error) error {
		if err != nil || path == root || e.Name() == ".DS_Store" {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		fmt.Fprintln(h, rel, statLine(path, false))
		if dest, err := os.Readlink(path); err == nil {
			fmt.Fprintln(h, dest, statLine(path, true))
		}
		return nil
	})
	return hex.EncodeToString(h.Sum(nil)), true
}

func statLine(path string, follow bool) string {
	var st syscall.Stat_t
	stat := syscall.Lstat
	if follow {
		stat = syscall.Stat
	}
	if stat(path, &st) != nil {
		return "?"
	}
	m, c := statTimes(&st)
	return fmt.Sprintf("%d %d %d.%d %d.%d", st.Ino, st.Size, m.Sec, m.Nsec, c.Sec, c.Nsec)
}

func computePluginDigest(plugin string) (string, bool) {
	var lines []string
	if dest, err := os.Readlink(plugin); err == nil {
		lines = append(lines, "R "+dest)
	}
	root, err := store.Resolve(plugin)
	if err != nil {
		return "", false
	}
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		return "", false
	}
	type entry struct{ rel, path string }
	var entries []entry
	filepath.WalkDir(root, func(path string, e fs.DirEntry, err error) error {
		if path == root {
			return nil
		}
		if e != nil && e.Name() == ".DS_Store" {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		entries = append(entries, entry{rel, path})
		if err != nil && e != nil && e.IsDir() {
			return fs.SkipDir
		}
		return nil
	})
	sort.Slice(entries, func(i, j int) bool { return entries[i].rel < entries[j].rel })
	for _, e := range entries {
		info, err := os.Lstat(e.path)
		switch {
		case err == nil && info.Mode()&os.ModeSymlink != 0:
			dest, _ := os.Readlink(e.path)
			line := "L " + e.rel + " -> " + dest
			if t, err := os.Stat(e.path); err == nil && !t.IsDir() {
				if data, err := os.ReadFile(e.path); err == nil {
					line += " " + sha256Hex(string(data))
				}
			}
			lines = append(lines, line)
		case err == nil && info.IsDir():
			lines = append(lines, "D "+e.rel)
		default:
			if data, err := os.ReadFile(e.path); err == nil {
				lines = append(lines, "F "+e.rel+" "+sha256Hex(string(data)))
			} else {
				lines = append(lines, "U "+e.rel)
			}
		}
	}
	return sha256Hex(strings.Join(lines, "\n")), true
}

// pluginManifest is the first manifest the plugin has, in the order the runtimes agree on.
func pluginManifest(plugin string) map[string]any {
	for _, place := range []string{".claude-plugin/plugin.json", "plugin.json", ".codex-plugin/plugin.json",
		".cursor-plugin/plugin.json", ".grok-plugin/plugin.json", ".github/plugin/plugin.json"} {
		if m := jsonObjectAt(filepath.Join(plugin, place)); m != nil {
			return m
		}
	}
	return map[string]any{}
}

func jsonObjectAt(path string) map[string]any {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var m map[string]any
	if dec.Decode(&m) != nil {
		return nil
	}
	return m
}

// pluginMCPServers is the plugin's MCP servers, from its .mcp.json or its manifest.
func pluginMCPServers(plugin string, manifest map[string]any) any {
	var servers map[string]any
	if file := jsonObjectAt(filepath.Join(plugin, ".mcp.json")); file != nil {
		if s, ok := file["mcpServers"].(map[string]any); ok {
			servers = s
		} else {
			servers = file
		}
	} else if s, ok := manifest["mcpServers"].(map[string]any); ok {
		servers = s
	}
	if len(servers) == 0 {
		return nil
	}
	b, err := json.Marshal(servers)
	if err != nil {
		return nil
	}
	b = bytes.ReplaceAll(b, []byte("${CLAUDE_PLUGIN_ROOT}"), []byte("${extensionPath}"))
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var out any
	if dec.Decode(&out) != nil {
		return nil
	}
	return out
}

// pluginCarries is what the plugin brings, in the words its row uses: hooks and
// connectors, which run by themselves, first.
func pluginCarries(plugin string) []string {
	manifest := pluginManifest(plugin)
	has := func(p string) bool { _, err := os.Lstat(filepath.Join(plugin, p)); return err == nil }
	carries := []string{}
	if _, ok := manifest["hooks"]; ok || has("hooks") {
		carries = append(carries, "hooks")
	}
	gemini, _ := jsonObjectAt(filepath.Join(plugin, "gemini-extension.json"))["mcpServers"].(map[string]any)
	if pluginMCPServers(plugin, manifest) != nil || len(gemini) > 0 {
		carries = append(carries, "connectors")
	}
	for _, f := range []string{"skills", "commands", "agents"} {
		if has(f) {
			carries = append(carries, f)
		}
	}
	return carries
}

