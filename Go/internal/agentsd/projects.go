package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The rest of a project's life, as DaemonCore+Projects, +ProjectDetection, +Cloning and
// +ChatProject serve it on a server: archiving and deleting, its pin, its settings in
// .agents/project.json, finding folders to add, cloning one, and the chat project.

func noSuchProject(msg string) error { return &Error{Code: CodeNoSuchProject, Message: msg} }

type projectState struct {
	// ChatHome is where the chat project lives (~/.agents/chat): the account's home on a
	// server, "" where there is none.
	ChatHome    string
	chatFailure string
	cloneMu     sync.Mutex
	clones      map[string]wire.CloneSummary
}

func (d *Daemon) chatFolder() string {
	if d.ChatHome == "" {
		return ""
	}
	return filepath.Join(d.ChatHome, ".agents", "chat")
}

// summaryFor is the summary of one project, or false.
func (d *Daemon) summaryFor(folder string) (wire.ProjectSummary, bool) {
	real := resolved(folder)
	for _, s := range d.projects(true) {
		if f := store.FolderPath(s.Project.Folder); f == folder || f == real {
			return s, true
		}
	}
	return wire.ProjectSummary{}, false
}

func (d *Daemon) projectRecord(folder string) (wire.Project, int, []wire.Project) {
	ps := d.Store.Projects()
	real := resolved(folder)
	for i, p := range ps {
		if f := store.FolderPath(p.Folder); f == folder || f == real {
			return p, i, ps
		}
	}
	return wire.Project{}, -1, ps
}

// editRecord changes a project's record, making one for a project that has only agents.
func (d *Daemon) editRecord(folder string, edit func(p *wire.Project)) error {
	p, i, ps := d.projectRecord(folder)
	if i < 0 {
		p = wire.Project{Folder: store.FolderURL(folder), AddedAt: now()}
		edit(&p)
		ps = append(ps, p)
	} else {
		edit(&p)
		ps[i] = p
	}
	return d.saveProjects(ps)
}

func (d *Daemon) sendProject(folder string) (wire.ProjectSummary, error) {
	s, ok := d.summaryFor(folder)
	if !ok {
		return wire.ProjectSummary{}, noSuchProject(folder + " is not a project.")
	}
	Broadcast(d, wire.NotifyProjectChanged, s)
	d.reconsider()
	return s, nil
}

func titles(agents []wire.Agent) string {
	var names []string
	for _, a := range agents {
		if a.Title != nil && *a.Title != "" {
			names = append(names, *a.Title)
		} else {
			names = append(names, "an agent")
		}
	}
	return strings.Join(names, ", ")
}

func (d *Daemon) agentsOf(folder string) []wire.Agent {
	var out []wire.Agent
	for _, a := range d.Store.Agents() {
		if projectFolder(&a) == folder {
			out = append(out, a)
		}
	}
	return out
}

func holdsRuntime(s wire.AgentState) bool {
	return s == wire.AgentStateStarting || s == wire.AgentStateRunning || s == wire.AgentStateWaitingOnUser
}

func (d *Daemon) archiveProject(folder string) (wire.ProjectSummary, error) {
	if _, ok := d.summaryFor(folder); !ok {
		return wire.ProjectSummary{}, noSuchProject(folder + " is not a project.")
	}
	var working []wire.Agent
	for _, a := range d.agentsOf(folder) {
		if holdsRuntime(a.State) {
			working = append(working, a)
		}
	}
	if len(working) > 0 {
		return wire.ProjectSummary{}, &Error{Code: wire.FailureProjectHasLiveAgents, Message: "Stop these first: " + titles(working) + "."}
	}
	t := now()
	if err := d.editRecord(folder, func(p *wire.Project) { p.ArchivedAt = &t }); err != nil {
		return wire.ProjectSummary{}, err
	}
	return d.sendProject(folder)
}

func (d *Daemon) unarchiveProject(folder string) (wire.ProjectSummary, error) {
	p, i, _ := d.projectRecord(folder)
	if i < 0 || p.ArchivedAt == nil {
		return wire.ProjectSummary{}, noSuchProject(folder + " is not an archived project.")
	}
	if err := d.editRecord(folder, func(p *wire.Project) { p.ArchivedAt = nil }); err != nil {
		return wire.ProjectSummary{}, err
	}
	return d.sendProject(folder)
}

// deleteProject is DaemonCore.deleteProject: an archived project's agents and record go;
// its folder is never touched.
func (d *Daemon) deleteProject(folder string) error {
	p, i, ps := d.projectRecord(folder)
	if i < 0 || p.ArchivedAt == nil {
		return &Error{Code: wire.FailureDeleteRefused, Message: "Only an archived project can be deleted. Archive it first."}
	}
	agents := d.agentsOf(folder)
	var working []wire.Agent
	for _, a := range agents {
		if holdsRuntime(a.State) || a.State == wire.AgentStateQueued {
			working = append(working, a)
		}
	}
	if len(working) > 0 {
		return &Error{Code: wire.FailureDeleteRefused, Message: projectRefusal(working, "It is still working. Stop it first.")}
	}
	for _, a := range agents {
		if a.State != wire.AgentStateArchived {
			d.archive(a.ID)
		}
		d.delete(a.ID)
	}
	ps = append(ps[:i], ps[i+1:]...)
	if err := d.saveProjects(ps); err != nil {
		return err
	}
	Broadcast(d, wire.NotifyProjectRemoved, wire.ProjectRemovedNotification{Folder: store.FolderURL(folder)})
	d.reconsider()
	return nil
}

// projectRefusal is DeletionWords.projectRefusal.
func projectRefusal(agents []wire.Agent, because string) string {
	var named []string
	for _, a := range agents {
		if a.Title != nil && strings.TrimSpace(*a.Title) != "" {
			named = append(named, "“"+strings.TrimSpace(*a.Title)+"”")
		} else {
			named = append(named, "a session")
		}
	}
	who := named[0]
	if len(named) > 1 {
		who = strings.Join(named[:len(named)-1], ", ") + " and " + named[len(named)-1]
	}
	return strings.ToUpper(who[:1]) + who[1:] + " cannot be deleted. " + because
}

func (d *Daemon) setPinned(r wire.SetPinnedRequest) (wire.ProjectSummary, error) {
	folder := store.FolderPath(r.Folder)
	if _, ok := d.summaryFor(folder); !ok {
		return wire.ProjectSummary{}, noSuchProject(folder + " is not a project.")
	}
	pinned := r.Pinned
	if err := d.editRecord(folder, func(p *wire.Project) { p.Pinned = &pinned }); err != nil {
		return wire.ProjectSummary{}, err
	}
	return d.sendProject(folder)
}

// MARK: .agents/project.json (ProjectConfig)

func projectConfigPath(folder string) string { return filepath.Join(folder, ".agents", "project.json") }

func notAnObject() error {
	return Invalid(".agents/project.json is not a JSON object, so it was left as it is. Fix it or remove it, then try again.")
}

// readProjectConfig is the file as an object, empty where there is none.
func readProjectConfig(folder string) (map[string]any, error) {
	if !ownFolders(folder, ".agents") {
		return nil, linkedFolder(".agents", folder)
	}
	b, err := os.ReadFile(projectConfigPath(folder))
	if os.IsNotExist(err) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	m, ok := value(b).(map[string]any)
	if !ok {
		return nil, notAnObject()
	}
	return m, nil
}

// setProjectConfig is ProjectConfig.set: one key written, the rest left as they are; nil
// takes it away, and an empty file goes.
func setProjectConfig(folder, key string, v any) error {
	m, err := readProjectConfig(folder)
	if err != nil {
		return err
	}
	if v == nil {
		delete(m, key)
	} else {
		b, _ := json.Marshal(v)
		m[key] = value(b)
	}
	path := projectConfigPath(folder)
	if !ownFolders(folder, ".agents") {
		return linkedFolder(".agents", folder)
	}
	if len(m) == 0 {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	b, err := diskjson.Pretty(m)
	if err != nil {
		return err
	}
	os.MkdirAll(filepath.Dir(path), 0o755)
	return store.WriteAtomically(path, append(b, '\n'), 0o644)
}

func configWriteError(err error) error {
	if e, ok := err.(*Error); ok {
		return e
	}
	return &Error{Code: CodeInternal, Message: ".agents/project.json could not be written: " + err.Error()}
}

func helperLimitsProblem(l wire.HelperLimits) string {
	if l.Running != nil && (*l.Running < 1 || *l.Running > 10) {
		return "Running helpers must be between 1 and 10."
	}
	if l.NotArchived != nil && (*l.NotArchived < 1 || *l.NotArchived > 20) {
		return "Helpers not yet archived must be between 1 and 20."
	}
	if l.Queued != nil && (*l.Queued < 1 || *l.Queued > 20) {
		return "Queued helpers must be between 1 and 20."
	}
	running, places := int64(3), int64(5)
	if l.Running != nil {
		running = *l.Running
	}
	if l.NotArchived != nil {
		places = *l.NotArchived
	}
	if running > places {
		return fmt.Sprintf("Running helpers (%d) cannot be more than helpers not yet archived (%d).", running, places)
	}
	return ""
}

func (d *Daemon) setHelperLimits(r wire.SetHelperLimitsRequest) (wire.ProjectSummary, error) {
	folder := store.FolderPath(r.Folder)
	if _, ok := d.summaryFor(folder); !ok {
		return wire.ProjectSummary{}, noSuchProject(folder + " is not a project.")
	}
	if why := helperLimitsProblem(r.Limits); why != "" {
		return wire.ProjectSummary{}, Invalid("%s", why)
	}
	if !isDir(folder) {
		return wire.ProjectSummary{}, noSuchProject(folder + " is not there, so its settings cannot be written.")
	}
	if !d.settled(folder, ".agents/project.json") {
		return wire.ProjectSummary{}, guardedRefusal(".agents/project.json", "The helper limits were not changed: ")
	}
	defer d.approveWrite(folder, ".agents/project.json")
	// HelperLimits.orNilIfDefault: the switch at its default is no choice at all.
	l := r.Limits
	if l.AgentsMayArchive != nil && *l.AgentsMayArchive {
		l.AgentsMayArchive = nil
	}
	var v any
	if l.Running != nil || l.NotArchived != nil || l.Queued != nil || l.AgentsMayArchive != nil {
		v = l
	}
	if err := setProjectConfig(folder, "helperLimits", v); err != nil {
		return wire.ProjectSummary{}, configWriteError(err)
	}
	if p, i, _ := d.projectRecord(folder); i >= 0 && p.HelperLimits != nil {
		d.editRecord(folder, func(p *wire.Project) { p.HelperLimits = nil })
	}
	return d.sendProject(folder)
}

func diskSpaceProblem(t wire.DiskThresholds) string {
	low, lowPercent, critical := int64(20), int64(5), int64(2)
	if t.LowGB != nil {
		low = *t.LowGB
	}
	if t.LowPercent != nil {
		lowPercent = *t.LowPercent
	}
	if t.CriticalGB != nil {
		critical = *t.CriticalGB
	}
	switch {
	case t.LowGB != nil && (low < 1 || low > 10000):
		return "Low disk space must be between 1 and 10000 GB."
	case t.LowPercent != nil && (lowPercent < 0 || lowPercent > 90):
		return "Low disk space must be between 0 and 90 percent."
	case t.CriticalGB != nil && (critical < 0 || critical > 10000):
		return "Critical disk space must be between 0 and 10000 GB."
	case critical > low:
		return "Critical disk space can't be more than low disk space."
	}
	return ""
}

func (d *Daemon) setDiskSpace(r wire.SetDiskSpaceRequest) (wire.ProjectSummary, error) {
	folder := store.FolderPath(r.Folder)
	if _, ok := d.summaryFor(folder); !ok || !isDir(folder) {
		return wire.ProjectSummary{}, noSuchProject(folder + " is not a project, or is not there.")
	}
	if why := diskSpaceProblem(r.DiskSpace); why != "" {
		return wire.ProjectSummary{}, Invalid("%s", why)
	}
	if !d.settled(folder, ".agents/project.json") {
		return wire.ProjectSummary{}, guardedRefusal(".agents/project.json", "The disk space lines were not changed: ")
	}
	defer d.approveWrite(folder, ".agents/project.json")
	// DiskThresholds.orNilIfDefault: a file says only what was chosen.
	t := r.DiskSpace
	if t.LowGB != nil && *t.LowGB == 20 {
		t.LowGB = nil
	}
	if t.LowPercent != nil && *t.LowPercent == 5 {
		t.LowPercent = nil
	}
	if t.CriticalGB != nil && *t.CriticalGB == 2 {
		t.CriticalGB = nil
	}
	var v any
	if t.LowGB != nil || t.LowPercent != nil || t.CriticalGB != nil {
		v = t
	}
	if err := setProjectConfig(folder, "diskSpace", v); err != nil {
		return wire.ProjectSummary{}, configWriteError(err)
	}
	s, err := d.sendProject(folder)
	safe.Go("disk", d.checkDisk)
	return s, err
}

// MARK: finding folders (projects/find)

func hasGit(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, ".git"))
	return err == nil
}

func (d *Daemon) findProjects(r wire.ProjectsFindRequest) []wire.FoundFolder {
	known := map[string]bool{}
	for _, p := range d.Store.Projects() {
		known[store.FolderPath(p.Folder)] = true
	}
	out := []wire.FoundFolder{}
	seen := map[string]bool{}
	for _, p := range r.Paths {
		base := expandHome(strings.TrimSpace(p))
		entries, _ := os.ReadDir(base)
		var found []string
		for _, e := range entries {
			child := filepath.Join(base, e.Name())
			if strings.HasPrefix(e.Name(), ".") || !isDir(child) || !hasGit(child) {
				continue
			}
			found = append(found, child)
		}
		sort.Strings(found)
		for _, f := range found {
			if !seen[f] {
				seen[f] = true
				out = append(out, wire.FoundFolder{Folder: store.FolderURL(f), Exists: true, IsRepository: true, IsProject: known[f]})
			}
		}
	}
	for _, typed := range r.Folders {
		if strings.TrimSpace(typed) == "" {
			continue
		}
		t := typed
		f := filepath.Clean(expandHome(strings.TrimSpace(typed)))
		if r, err := store.Resolve(f); err == nil {
			f = r
		}
		exists := isDir(f)
		out = append(out, wire.FoundFolder{Typed: &t, Folder: store.FolderURL(f), Exists: exists, IsRepository: exists && hasGit(f), IsProject: known[f]})
	}
	return out
}

// MARK: the chat project (DaemonCore+ChatProject)

// EnsureChatProject makes ~/.agents/chat and its record, unless it was archived.
func (d *Daemon) EnsureChatProject() {
	folder := d.chatFolder()
	if folder == "" {
		return
	}
	if fi, err := os.Stat(folder); err == nil && !fi.IsDir() {
		d.chatFailure = folder + " is a file, so there is no chat project."
		return
	}
	p, i, _ := d.projectRecord(folder)
	if i >= 0 && p.ArchivedAt != nil {
		return
	}
	if err := os.MkdirAll(folder, 0o755); err != nil {
		d.chatFailure = err.Error()
		return
	}
	if i < 0 {
		d.editRecord(folder, func(*wire.Project) {})
	}
}

func (d *Daemon) chatProjectState() wire.ChatProjectState {
	folder := d.chatFolder()
	if folder == "" {
		return wire.ChatProjectState{NoPersonalHome: &struct{}{}}
	}
	url := store.FolderURL(folder)
	if strings.HasSuffix(string(url), "/") == false {
		url += "/"
	}
	p, i, _ := d.projectRecord(folder)
	switch {
	case i >= 0 && p.ArchivedAt != nil:
		return wire.ChatProjectState{Archived: &wire.ChatProjectStateArchived{Folder: url}}
	case i >= 0 && isDir(folder):
		return wire.ChatProjectState{Ready: &wire.ChatProjectStateReady{Folder: url}}
	}
	why := d.chatFailure
	if why == "" {
		why = folder + " is not there. It is made again when this host's daemon starts."
	}
	return wire.ChatProjectState{Failed: &wire.ChatProjectStateFailed{Message: why}}
}

// MARK: cloning (DaemonCore+Cloning)

type gitRemote struct{ url, host, path, folderName string }

// parseRemote is GitRemote(url:): an HTTPS or SSH address, or scp style.
func parseRemote(raw string) (gitRemote, bool) {
	u := strings.TrimSpace(raw)
	if u == "" || strings.HasPrefix(u, "-") || strings.ContainsAny(u, " \t\n") {
		return gitRemote{}, false
	}
	var host, path string
	if rest, ok := strings.CutPrefix(u, "https://"); ok {
		host, path, _ = strings.Cut(rest, "/")
	} else if rest, ok := strings.CutPrefix(u, "ssh://"); ok {
		host, path, _ = strings.Cut(rest, "/")
	} else if h, p, ok := strings.Cut(u, ":"); ok && !strings.Contains(h, "/") {
		host, path = h, p
	} else {
		return gitRemote{}, false
	}
	if at := strings.LastIndex(host, "@"); at >= 0 {
		host = host[at+1:]
	}
	if c := strings.Index(host, ":"); c >= 0 && !strings.HasPrefix(u, "ssh://") {
		host = host[:c]
	}
	path = strings.Trim(path, "/")
	if host == "" || path == "" {
		return gitRemote{}, false
	}
	name := strings.TrimSuffix(filepath.Base(path), ".git")
	if name == "" || name == "." || name == ".." {
		return gitRemote{}, false
	}
	return gitRemote{url: u, host: strings.ToLower(host), path: strings.ToLower(strings.TrimSuffix(path, ".git")), folderName: name}, true
}

func (r gitRemote) identity() string { return r.host + "/" + r.path }

func cloneParent() string {
	if p := os.Getenv("AGENTS_CLONE_PARENT"); p != "" {
		return expandHome(p)
	}
	home, _ := os.UserHomeDir()
	return home
}

// cloneFailure is CloneFailure.explain, in a server's words.
func cloneFailure(r gitRemote, stderr string) string {
	low := strings.ToLower(stderr)
	where := r.host + "/" + r.path
	switch {
	case strings.Contains(low, "could not resolve host"):
		return "Could not reach " + r.host + ". Check the address and the network."
	case strings.Contains(low, "repository not found"):
		return "There is no repository at " + where + ", or this server is not allowed to read it."
	case strings.Contains(low, "could not read username"), strings.Contains(low, "could not read password"), strings.Contains(low, "authentication failed"):
		return where + " needs a sign-in this server does not have."
	case strings.Contains(low, "permission denied (publickey)"):
		return r.host + " did not accept this server's SSH key for " + where + "."
	case strings.Contains(low, "host key verification failed"):
		return r.host + " is not a known SSH host on this server. Connect to it once with ssh, then try again."
	}
	for _, l := range strings.Split(stderr, "\n") {
		if m, ok := strings.CutPrefix(l, "fatal: "); ok {
			return "Could not clone " + where + ": " + m
		}
	}
	return "Could not clone " + where + "."
}

func (d *Daemon) cloneProject(r wire.CloneRequest) (wire.ProjectSummary, error) {
	remote, ok := parseRemote(r.URL)
	if !ok {
		return wire.ProjectSummary{}, &Error{Code: wire.FailureNotACloneURL, Message: "That is not a Git URL this app can clone. Paste an HTTPS or SSH address."}
	}
	dest := filepath.Join(canonical(cloneParent()), remote.folderName)
	d.cloneMu.Lock()
	if d.clones == nil {
		d.clones = map[string]wire.CloneSummary{}
	}
	if _, busy := d.clones[dest]; busy {
		d.cloneMu.Unlock()
		return wire.ProjectSummary{}, &Error{Code: wire.FailureFolderInTheWay, Message: shortPath(dest) + " is already being cloned."}
	}
	if _, err := os.Stat(dest); err == nil {
		d.cloneMu.Unlock()
		return d.adoptClone(dest, remote)
	}
	c := wire.CloneSummary{ID: store.NewUUID(), URL: remote.url, Folder: store.FolderURL(dest), StartedAt: now()}
	d.clones[dest] = c
	d.cloneMu.Unlock()
	Broadcast(d, wire.NotifyCloneChanged, wire.CloneNotification{Clone: c, Finished: false})
	staging := filepath.Join(d.Store.Loc.Root, "Clones", string(c.ID))
	defer func() {
		os.RemoveAll(staging)
		d.cloneMu.Lock()
		delete(d.clones, dest)
		d.cloneMu.Unlock()
		Broadcast(d, wire.NotifyCloneChanged, wire.CloneNotification{Clone: c, Finished: true})
	}()
	os.MkdirAll(staging, 0o755)
	staged := filepath.Join(staging, remote.folderName)
	ctx, cancel := context.WithTimeout(d.ctx, time.Hour)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "clone", "--", remote.url, staged)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return wire.ProjectSummary{}, &Error{Code: wire.FailureCloneFailed, Message: "Git is not installed on this server."}
		}
		return wire.ProjectSummary{}, &Error{Code: wire.FailureCloneFailed, Message: cloneFailure(remote, stderr.String())}
	}
	if _, err := os.Stat(dest); err == nil {
		return wire.ProjectSummary{}, &Error{Code: wire.FailureFolderInTheWay, Message: shortPath(dest) + " appeared while the clone ran. Nothing in it was changed."}
	}
	if err := os.Rename(staged, dest); err != nil {
		return wire.ProjectSummary{}, &Error{Code: wire.FailureCloneFailed, Message: "Cloned, but could not move it to " + shortPath(dest) + ": " + err.Error()}
	}
	return d.addProject(store.FolderURL(dest))
}

// adoptClone is a folder already there that is a clone of the same repository: made a
// project, or brought back from the archive.
func (d *Daemon) adoptClone(dest string, remote gitRemote) (wire.ProjectSummary, error) {
	same := false
	if isDir(dest) {
		out, _ := git(dest, "remote", "-v")
		for _, l := range strings.Split(out, "\n") {
			if f := strings.Fields(l); len(f) >= 2 {
				if r, ok := parseRemote(f[1]); ok && r.identity() == remote.identity() {
					same = true
				}
			}
		}
	}
	if !same {
		return wire.ProjectSummary{}, &Error{Code: wire.FailureFolderInTheWay,
			Message: shortPath(dest) + " is already there and is not a clone of " + remote.identity() + ". Nothing in it was changed."}
	}
	if p, i, _ := d.projectRecord(dest); i >= 0 && p.ArchivedAt != nil {
		return d.unarchiveProject(dest)
	}
	return d.addProject(store.FolderURL(dest))
}

// approvedConfig is .agents/project.json as last approved, without checking it again.
func (d *Daemon) approvedConfig(folder string) (map[string]any, error) {
	d.guardedMu.Lock()
	s, known := d.stateOf(folder, ".agents/project.json")
	pending, content := s.Pending != nil, s.ApprovedContent
	d.guardedMu.Unlock()
	if !known || !pending {
		return readProjectConfig(folder)
	}
	if content == nil {
		return map[string]any{}, nil
	}
	m, ok := value(content).(map[string]any)
	if !ok {
		return nil, notAnObject()
	}
	return m, nil
}

// archiveApprovals is the sessions asking to be archived, oldest first.
func (d *Daemon) archiveApprovals(folder string) []wire.Approval {
	var asking []wire.Agent
	for _, a := range d.agentsOf(folder) {
		if a.ArchiveRequest != nil && a.ArchiveRequest.Requested != nil && a.State != wire.AgentStateArchived {
			asking = append(asking, a)
		}
	}
	sort.Slice(asking, func(i, j int) bool {
		return asking[i].ArchiveRequest.Requested.At < asking[j].ArchiveRequest.Requested.At
	})
	var out []wire.Approval
	for _, a := range asking {
		title, id, at := "Untitled", a.ID, a.ArchiveRequest.Requested.At
		if a.Title != nil {
			title = *a.Title
		}
		out = append(out, wire.Approval{Kind: wire.ApprovalKindArchive, Key: string(a.ID), Title: title, Line: "Asks to be archived",
			Since: &at, Actions: []wire.ApprovalAction{wire.ApprovalActionApprove, wire.ApprovalActionDeny}, AgentID: &id})
	}
	return out
}

// dress is what a summary says beyond the record: the chat project, pinned unless the
// person unpinned it, and the settings in .agents/project.json (#126), the record's own
// older ones where the file has none.
func (d *Daemon) dress(s *wire.ProjectSummary) {
	folder := store.FolderPath(s.Project.Folder)
	if chat := d.chatFolder(); chat != "" && folder == chat {
		yes := true
		s.IsChat = &yes
		if s.Project.Pinned == nil {
			s.Project.Pinned = &yes
		}
	}
	if s.Project.Pinned != nil && !*s.Project.Pinned {
		s.Project.Pinned = nil
	}
	s.GuardedChanges = d.guardedChanges(folder)
	for _, c := range s.GuardedChanges {
		if _, ok := workflowIDInPath(c.Path); ok {
			s.Approvals = append(s.Approvals, d.workflowApproval(folder, c))
		} else {
			s.Approvals = append(s.Approvals, fileApproval(c))
		}
	}
	s.Approvals = append(s.Approvals, d.archiveApprovals(folder)...)
	if m, err := d.approvedConfig(folder); err == nil {
		if v, ok := m["helperLimits"]; ok {
			var l wire.HelperLimits
			if b, _ := json.Marshal(v); json.Unmarshal(b, &l) == nil {
				s.Project.HelperLimits = &l
			}
		}
		if v, ok := m["diskSpace"]; ok {
			var t wire.DiskThresholds
			if b, _ := json.Marshal(v); json.Unmarshal(b, &t) == nil {
				s.Project.DiskSpace = &t
			}
		}
	}
}

func (d *Daemon) registerProjects() {
	os.RemoveAll(filepath.Join(d.Store.Loc.Root, "Clones"))
	folderOf := func(u wire.URL) string {
		f := store.FolderPath(u)
		if r, err := store.Resolve(f); err == nil {
			f = r
		}
		return f
	}
	On(d, wire.CallProjectsArchive, func(ctx context.Context, c *Client, r wire.ProjectRequest) (wire.ProjectSummary, error) {
		return d.archiveProject(folderOf(r.Folder))
	})
	On(d, wire.CallProjectsUnarchive, func(ctx context.Context, c *Client, r wire.ProjectRequest) (wire.ProjectSummary, error) {
		return d.unarchiveProject(folderOf(r.Folder))
	})
	On(d, wire.CallProjectsDelete, func(ctx context.Context, c *Client, r wire.ProjectRequest) (wire.Empty, error) {
		return wire.Empty{}, d.deleteProject(folderOf(r.Folder))
	})
	On(d, wire.CallProjectsSetPinned, func(ctx context.Context, c *Client, r wire.SetPinnedRequest) (wire.ProjectSummary, error) {
		r.Folder = store.FolderURL(folderOf(r.Folder))
		return d.setPinned(r)
	})
	On(d, wire.CallProjectsSetHelperLimits, func(ctx context.Context, c *Client, r wire.SetHelperLimitsRequest) (wire.ProjectSummary, error) {
		r.Folder = store.FolderURL(folderOf(r.Folder))
		return d.setHelperLimits(r)
	})
	On(d, wire.CallProjectsSetDiskSpace, func(ctx context.Context, c *Client, r wire.SetDiskSpaceRequest) (wire.ProjectSummary, error) {
		r.Folder = store.FolderURL(folderOf(r.Folder))
		return d.setDiskSpace(r)
	})
	On(d, wire.CallProjectsFind, func(ctx context.Context, c *Client, r wire.ProjectsFindRequest) ([]wire.FoundFolder, error) {
		return d.findProjects(r), nil
	})
	On(d, wire.CallProjectsChatState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.ChatProjectState, error) {
		return d.chatProjectState(), nil
	})
	On(d, wire.CallProjectsClone, func(ctx context.Context, c *Client, r wire.CloneRequest) (wire.ProjectSummary, error) {
		return d.cloneProject(r)
	})
	On(d, wire.CallProjectsClones, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.CloneSummary, error) {
		d.cloneMu.Lock()
		out := []wire.CloneSummary{}
		for _, c := range d.clones {
			out = append(out, c)
		}
		d.cloneMu.Unlock()
		sort.Slice(out, func(i, j int) bool { return out[i].StartedAt < out[j].StartedAt })
		return out, nil
	})
}
