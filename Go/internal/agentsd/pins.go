package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A project's pins (#159, #180, #432), in <project>/.agents/pins.json, as the Swift host
// reads and writes them (Pins.swift, DaemonCore+Pins): pages and views, sessions and
// workflows, ten of each at most, in the order shown.

const (
	pinsPerProject = 10
	pinTitleLength = 60
	viewArguments  = 2048
	pinsFilePath   = ".agents/pins.json"
)

type pinner struct {
	Person   *bool   `json:"person,omitempty"`
	Agent    *string `json:"agent,omitempty"`
	Workflow *string `json:"workflow,omitempty"`
}

func thePerson() pinner { yes := true; return pinner{Person: &yes} }

type pinEntry struct {
	path     string // a view pin's is its ui:// address, not written
	title    *string
	pinnedBy pinner
	view     *wire.ViewPin
}

type sessionPin struct {
	Session  wire.UUID `json:"session"`
	PinnedBy pinner    `json:"pinned_by"`
}

type workflowPin struct {
	Workflow string `json:"workflow"`
	PinnedBy pinner `json:"pinned_by"`
}

type pinsFile struct {
	pins []pinEntry
	// unread is the entries this build cannot read, kept and written back after the rest;
	// they count towards the limit.
	unread    []json.RawMessage
	sessions  []sessionPin
	workflows []workflowPin
}

func (f pinsFile) empty() bool {
	return len(f.pins) == 0 && len(f.unread) == 0 && len(f.sessions) == 0 && len(f.workflows) == 0
}

func pinRefused(msg string) error { return &Error{Code: wire.FailurePinRefused, Message: msg} }

var markdownExtensions = map[string]bool{"md": true, "markdown": true, "mdown": true, "mkd": true}

// pinKind is PinRules.kind.
func pinKind(path string) (wire.PinKind, bool) {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	switch {
	case markdownExtensions[ext]:
		return wire.PinKindMarkdown, true
	case ext == "html" || ext == "htm":
		return wire.PinKindHTML, true
	}
	return "", false
}

// normalizePin is PinRules.normalize: relative, tidied, nothing that climbs out.
func normalizePin(path string) (string, bool) {
	if strings.HasPrefix(path, "/") {
		return "", false
	}
	var parts []string
	for _, p := range strings.Split(path, "/") {
		switch p {
		case "", ".":
		case "..":
			return "", false
		default:
			parts = append(parts, p)
		}
	}
	if len(parts) == 0 {
		return "", false
	}
	return strings.Join(parts, "/"), true
}

// relativePin is PinRules.relative: file's path inside folder.
func relativePin(file, folder string) (string, bool) {
	root := strings.TrimSuffix(filepath.Clean(folder), "/") + "/"
	full := filepath.Clean(file)
	if !strings.HasPrefix(full, root) {
		return "", false
	}
	return normalizePin(strings.TrimPrefix(full, root))
}

func personPinPath(given, project string) (string, bool) {
	if strings.HasPrefix(given, "/") {
		return relativePin(given, project)
	}
	return normalizePin(given)
}

// viewProblem is PinRules.problem.
func viewProblem(v wire.ViewPin) string {
	if strings.TrimSpace(v.Server) == "" {
		return "a view pin names its server."
	}
	if !strings.HasPrefix(v.URI, "ui://") || utf8.RuneCountInString(v.URI) <= 5 {
		return "a view's address starts ui://."
	}
	if strings.TrimSpace(v.Tool) == "" {
		return "a view pin names the tool that feeds it."
	}
	if len(v.Arguments) > 0 && string(v.Arguments) != "null" {
		if _, ok := value(v.Arguments).(map[string]any); !ok {
			return "`arguments` is a JSON object."
		}
		if b, _ := json.Marshal(json.RawMessage(v.Arguments)); len(b) > viewArguments {
			return "`arguments` is at most 2 KB of JSON."
		}
	}
	return ""
}

func pinsFileOf(project string) string { return filepath.Join(project, pinsFilePath) }

// readPinsFile is PinsFile.read: good entries, each once, at most the limit.
func readPinsFile(data []byte) (pinsFile, error) {
	var raw struct {
		Pins      []json.RawMessage `json:"pins"`
		Sessions  []sessionPin      `json:"sessions"`
		Workflows []workflowPin     `json:"workflows"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return pinsFile{}, err
	}
	var f pinsFile
	var entries []pinEntry
	for _, r := range raw.Pins {
		var e struct {
			Path     *string       `json:"path"`
			View     *wire.ViewPin `json:"view"`
			Title    *string       `json:"title"`
			PinnedBy *pinner       `json:"pinned_by"`
		}
		if json.Unmarshal(r, &e) != nil || (e.Path == nil) == (e.View == nil) || e.PinnedBy == nil {
			f.unread = append(f.unread, r)
			continue
		}
		entry := pinEntry{title: e.Title, pinnedBy: *e.PinnedBy, view: e.View}
		if e.View != nil {
			entry.path = e.View.URI
		} else {
			entry.path = *e.Path
		}
		entries = append(entries, entry)
	}
	seen := map[string]bool{}
	room := pinsPerProject - len(f.unread)
	for _, e := range entries {
		if e.view != nil {
			if viewProblem(*e.view) != "" {
				continue
			}
		} else {
			p, ok := normalizePin(e.path)
			if _, kind := pinKind(p); !ok || !kind {
				continue
			}
			e.path = p
		}
		if seen[e.path] || len(f.pins) >= room {
			continue
		}
		seen[e.path] = true
		f.pins = append(f.pins, e)
	}
	sessions := map[wire.UUID]bool{}
	for _, s := range raw.Sessions {
		if !sessions[s.Session] && len(f.sessions) < pinsPerProject {
			sessions[s.Session] = true
			f.sessions = append(f.sessions, s)
		}
	}
	workflows := map[string]bool{}
	for _, w := range raw.Workflows {
		if !workflows[w.Workflow] && len(f.workflows) < pinsPerProject {
			workflows[w.Workflow] = true
			f.workflows = append(f.workflows, w)
		}
	}
	return f, nil
}

// tree is the file as PinsFile.encode writes it.
func (f pinsFile) data() ([]byte, error) {
	var pins []any
	asTree := func(v any) any {
		b, _ := json.Marshal(v)
		return value(b)
	}
	for _, e := range f.pins {
		m := map[string]any{"pinned_by": asTree(e.pinnedBy)}
		if e.view != nil {
			m["view"] = asTree(e.view)
		} else {
			m["path"] = e.path
		}
		if e.title != nil {
			m["title"] = *e.title
		}
		pins = append(pins, m)
	}
	for _, r := range f.unread {
		pins = append(pins, value(r))
	}
	if pins == nil {
		pins = []any{}
	}
	tree := map[string]any{"pins": pins}
	if len(f.sessions) > 0 {
		tree["sessions"] = asTree(f.sessions)
	}
	if len(f.workflows) > 0 {
		tree["workflows"] = asTree(f.workflows)
	}
	b, err := diskjson.Pretty(tree)
	return append(b, '\n'), err
}

func (d *Daemon) readPins(project string) pinsFile {
	b, err := os.ReadFile(pinsFileOf(project))
	if err != nil {
		return pinsFile{}
	}
	f, err := readPinsFile(b)
	if err != nil {
		return pinsFile{} // a file that does not decode reads as empty
	}
	return f
}

// writePins removes an empty file, writes only what differs, and tells every client.
func (d *Daemon) writePins(f pinsFile, project string) error {
	path := pinsFileOf(project)
	if f.empty() {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return pinRefused("The pins could not be written in " + project + "/.agents: " + err.Error())
		}
	} else {
		b, err := f.data()
		if err == nil {
			if old, rerr := os.ReadFile(path); rerr != nil || !bytes.Equal(old, b) {
				err = store.WriteAtomically(path, b, 0o644)
			}
		}
		if err != nil {
			return pinRefused("The pins could not be written in " + project + "/.agents: " + err.Error())
		}
	}
	d.pinsChanged(project)
	return nil
}

// pinsChanged says pins/changed for a project, at most once a second.
func (d *Daemon) pinsChanged(project string) {
	d.pinMu.Lock()
	defer d.pinMu.Unlock()
	if d.pinTimers == nil {
		d.pinTimers = map[string]*time.Timer{}
	}
	if d.pinTimers[project] != nil {
		return
	}
	d.pinTimers[project] = time.AfterFunc(time.Second, func() {
		d.pinMu.Lock()
		delete(d.pinTimers, project)
		d.pinMu.Unlock()
		pp := d.projectPins(project)
		Broadcast(d, wire.NotifyPinsChanged, wire.PinsChangedNotification{Folder: pp.Folder, Pins: pp.Pins,
			Sessions: pp.Sessions, Workflows: pp.Workflows})
	})
}

func defaultPinTitle(path string) string {
	name := filepath.Base(path)
	stem := strings.TrimSuffix(name, filepath.Ext(name))
	if l := strings.ToLower(stem); l == "readme" || l == "index" {
		if folder := filepath.Base(filepath.Dir(path)); folder != "." && folder != "/" && folder != "" {
			return folder
		}
	}
	return stem
}

func defaultViewTitle(v wire.ViewPin) string {
	parts := strings.Split(v.URI, "/")
	name := strings.ReplaceAll(parts[len(parts)-1], "-", " ")
	words := strings.Fields(name)
	for i, w := range words {
		words[i] = strings.ToUpper(w[:1]) + strings.ToLower(w[1:])
	}
	return strings.Join(words, " ")
}

func (d *Daemon) pinnerView(p pinner) wire.PinnerView {
	switch {
	case p.Person != nil && *p.Person:
	case p.Workflow != nil:
		return wire.PinnerView{Kind: wire.PinnerKindWorkflow, ID: *p.Workflow, Name: *p.Workflow}
	case p.Agent != nil:
		id := strings.ToUpper(*p.Agent)
		name := "an agent not on this host"
		if a := d.Store.Agent(wire.UUID(id)); a != nil && a.Title != nil {
			name = *a.Title
		}
		return wire.PinnerView{Kind: wire.PinnerKindAgent, ID: id, Name: name}
	}
	return wire.PinnerView{Kind: wire.PinnerKindPerson, ID: "", Name: "the person"}
}

func (d *Daemon) pinViews(project string, f pinsFile) []wire.PinView {
	out := []wire.PinView{}
	for _, e := range f.pins {
		v := wire.PinView{Path: e.path, PinnedBy: d.pinnerView(e.pinnedBy), View: e.view}
		if e.view != nil {
			v.Kind, v.Title = wire.PinKindView, defaultViewTitle(*e.view)
			// No server's views are read on this host yet.
			v.Missing = true
			reason := "server not set up here"
			v.MissingReason = &reason
		} else {
			v.Kind, _ = pinKind(e.path)
			v.Title = defaultPinTitle(e.path)
			fi, err := os.Stat(filepath.Join(project, e.path))
			v.Missing = err != nil || fi.IsDir()
		}
		if e.title != nil {
			v.Title = *e.title
		}
		out = append(out, v)
	}
	return out
}

func (d *Daemon) projectPins(project string) wire.ProjectPins {
	f := d.readPins(project)
	pp := wire.ProjectPins{Folder: fileURL(project, true), Pins: d.pinViews(project, f)}
	for _, s := range f.sessions {
		pp.Sessions = append(pp.Sessions, s.Session)
	}
	for _, w := range f.workflows {
		pp.Workflows = append(pp.Workflows, w.Workflow)
	}
	return pp
}

// knownPinProject is a folder this host has as a project.
func (d *Daemon) knownPinProject(folder wire.URL) (string, error) {
	path := store.FolderPath(folder)
	for _, s := range d.projects(true) {
		if store.FolderPath(s.Project.Folder) == path {
			return path, nil
		}
	}
	return "", pinRefused("This host has no project at " + path + ".")
}

// pageURL is a file in the project folder, its links resolved, still in the folder.
func pageURL(path, project string) (string, error) {
	rel, ok := personPinPath(path, project)
	if !ok {
		return "", Invalid("%s is not in this project.", path)
	}
	full := filepath.Join(project, rel)
	root, err := filepath.EvalSymlinks(project)
	if err != nil {
		root = project
	}
	if r, err := filepath.EvalSymlinks(full); err == nil {
		if !inside(root, r) {
			return "", Invalid("%s is not in this project.", path)
		}
		return r, nil
	}
	return full, nil
}

func arrange[T any](items []T, key func(T) string, order []string) []T {
	byKey := map[string]T{}
	for _, it := range items {
		byKey[key(it)] = it
	}
	used := map[string]bool{}
	var out []T
	for _, k := range order {
		if it, ok := byKey[k]; ok && !used[k] {
			used[k] = true
			out = append(out, it)
		}
	}
	for _, it := range items {
		if !used[key(it)] {
			out = append(out, it)
		}
	}
	return out
}

func (d *Daemon) registerPins() {
	On(d, wire.CallPinsList, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.ProjectPins, error) {
		ps := d.projects(false)
		sort.SliceStable(ps, func(i, j int) bool { return ps[i].LastActivityAt > ps[j].LastActivityAt })
		out := []wire.ProjectPins{}
		for _, s := range ps {
			pp := d.projectPins(store.FolderPath(s.Project.Folder))
			if len(pp.Pins) > 0 || len(pp.Sessions) > 0 || len(pp.Workflows) > 0 {
				out = append(out, pp)
			}
		}
		return out, nil
	})
	On(d, wire.CallPinsRead, func(ctx context.Context, c *Client, r wire.PinReadRequest) (wire.FileReading, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return wire.FileReading{}, err
		}
		path, err := pageURL(r.Path, project)
		if err != nil {
			return wire.FileReading{}, err
		}
		return reading(path, r.KnownStamp)
	})
	On(d, wire.CallPinsWrite, func(ctx context.Context, c *Client, r wire.PinWriteRequest) (wire.Empty, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		path, err := pageURL(r.Path, project)
		if err != nil {
			return wire.Empty{}, err
		}
		if kind, ok := pinKind(path); !ok || kind != wire.PinKindMarkdown {
			return wire.Empty{}, Invalid("Only a Markdown page can be typed on.")
		}
		if old, err := os.ReadFile(path); err == nil && string(old) == r.Text {
			return wire.Empty{}, nil
		}
		if err := store.WriteAtomically(path, []byte(r.Text), 0o644); err != nil {
			return wire.Empty{}, &Error{Code: CodeInternal, Message: "Could not save " + filepath.Base(path) + ": " + err.Error()}
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallPinsPin, func(ctx context.Context, c *Client, r wire.PinRequest) ([]wire.PinView, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return nil, err
		}
		const lead = "Nothing was pinned: "
		entry := pinEntry{title: r.Title, pinnedBy: thePerson()}
		if r.View != nil {
			if why := viewProblem(*r.View); why != "" {
				return nil, pinRefused(lead + why)
			}
			// This host reads no server's views yet (DaemonCore.thirdPartyPinRefusal).
			return nil, pinRefused(lead + "the app hasn't read " + r.View.Server + "'s views yet. Show one in a chat first.")
		}
		path, ok := personPinPath(r.Path, project)
		if !ok {
			return nil, pinRefused(lead + r.Path + " is not in this project.")
		}
		if fi, err := os.Stat(filepath.Join(project, path)); err != nil || !fi.Mode().IsRegular() {
			return nil, pinRefused(lead + "there is no file at " + path + " in the project folder.")
		}
		entry.path = path
		if err := d.pin(entry, project, lead); err != nil {
			return nil, err
		}
		return d.pinViews(project, d.readPins(project)), nil
	})
	On(d, wire.CallPinsUnpin, func(ctx context.Context, c *Client, r wire.PinPathRequest) (wire.Empty, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		key := r.Path
		if !strings.HasPrefix(key, "ui://") {
			if p, ok := personPinPath(r.Path, project); ok {
				key = p
			}
		}
		f := d.readPins(project)
		for i, e := range f.pins {
			if e.path == key {
				f.pins = append(f.pins[:i], f.pins[i+1:]...)
				return wire.Empty{}, d.writePins(f, project)
			}
		}
		return wire.Empty{}, pinRefused("Nothing was unpinned: " + r.Path + " is not pinned in this project.")
	})
	On(d, wire.CallPinsArrange, func(ctx context.Context, c *Client, r wire.PinArrangeRequest) (wire.Empty, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		f := d.readPins(project)
		f.pins = arrange(f.pins, func(e pinEntry) string { return e.path }, r.Paths)
		return wire.Empty{}, d.writePins(f, project)
	})
	On(d, wire.CallPinsPinSession, func(ctx context.Context, c *Client, r wire.PinSessionRequest) (wire.Empty, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		const lead = "Nothing was pinned: "
		a := d.Store.Agent(r.AgentID)
		if a == nil || projectFolder(a) != project {
			return wire.Empty{}, pinRefused(lead + "that session is not in this project.")
		}
		if a.State == wire.AgentStateArchived {
			return wire.Empty{}, pinRefused(lead + "an archived session can't be pinned.")
		}
		f := d.readPins(project)
		for _, s := range f.sessions {
			if s.Session == a.ID {
				return wire.Empty{}, nil
			}
		}
		if len(f.sessions) >= pinsPerProject {
			return wire.Empty{}, pinRefused(lead + "this project already has 10 pinned sessions, the most it can have. Unpin one first.")
		}
		f.sessions = append(f.sessions, sessionPin{Session: a.ID, PinnedBy: thePerson()})
		return wire.Empty{}, d.writePins(f, project)
	})
	On(d, wire.CallPinsUnpinSession, func(ctx context.Context, c *Client, r wire.PinSessionRequest) (wire.Empty, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		return wire.Empty{}, d.unpinSession(project, r.AgentID)
	})
	On(d, wire.CallPinsArrangeSessions, func(ctx context.Context, c *Client, r wire.PinArrangeSessionsRequest) (wire.Empty, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		order := make([]string, len(r.AgentIDs))
		for i, id := range r.AgentIDs {
			order[i] = strings.ToUpper(string(id))
		}
		f := d.readPins(project)
		f.sessions = arrange(f.sessions, func(s sessionPin) string { return strings.ToUpper(string(s.Session)) }, order)
		return wire.Empty{}, d.writePins(f, project)
	})
	On(d, wire.CallPinsPinWorkflow, func(ctx context.Context, c *Client, r wire.WorkflowRequest) (wire.Empty, error) {
		if _, err := d.knownPinProject(r.Folder); err != nil {
			return wire.Empty{}, err
		}
		// This host keeps no workflows yet.
		return wire.Empty{}, pinRefused("Nothing was pinned: there is no workflow called " + r.WorkflowID + " in this project.")
	})
	On(d, wire.CallPinsUnpinWorkflow, func(ctx context.Context, c *Client, r wire.WorkflowRequest) (wire.Empty, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		f := d.readPins(project)
		for i, w := range f.workflows {
			if w.Workflow == r.WorkflowID {
				f.workflows = append(f.workflows[:i], f.workflows[i+1:]...)
				return wire.Empty{}, d.writePins(f, project)
			}
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallPinsArrangeWorkflows, func(ctx context.Context, c *Client, r wire.PinArrangeWorkflowsRequest) (wire.Empty, error) {
		project, err := d.knownPinProject(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		f := d.readPins(project)
		f.workflows = arrange(f.workflows, func(w workflowPin) string { return w.Workflow }, r.WorkflowIDs)
		return wire.Empty{}, d.writePins(f, project)
	})
}

// pin is DaemonCore.pin: retitled where it is, or added under the limit.
func (d *Daemon) pin(entry pinEntry, project, lead string) error {
	if _, ok := pinKind(entry.path); entry.view == nil && !ok {
		return pinRefused(lead + "only a Markdown (.md) or HTML (.html) page can be pinned.")
	}
	if entry.title != nil && utf8.RuneCountInString(*entry.title) > pinTitleLength {
		return pinRefused(lead + "`title` is at most 60 characters.")
	}
	f := d.readPins(project)
	for i, e := range f.pins {
		if e.path == entry.path {
			if entry.title != nil {
				f.pins[i].title = entry.title
			}
			if entry.view != nil {
				f.pins[i].view = entry.view
			}
			return d.writePins(f, project)
		}
	}
	if len(f.pins)+len(f.unread) >= pinsPerProject {
		return pinRefused(lead + "this project already has 10 pins, pages and views together, the most it can have. Unpin one first.")
	}
	f.pins = append(f.pins, entry)
	return d.writePins(f, project)
}

func (d *Daemon) unpinSession(project string, id wire.UUID) error {
	f := d.readPins(project)
	for i, s := range f.sessions {
		if strings.EqualFold(string(s.Session), string(id)) {
			f.sessions = append(f.sessions[:i], f.sessions[i+1:]...)
			return d.writePins(f, project)
		}
	}
	return nil
}

// pinState is the Daemon's: pins/changed waiting to be said, by project.
type pinState struct {
	pinMu     sync.Mutex
	pinTimers map[string]*time.Timer
}
