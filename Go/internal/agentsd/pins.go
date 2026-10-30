package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A folder's pins (#159, #180, #432), in <folder>/.agents/pins.json, as the Swift host
// reads and writes them (Pins.swift, DaemonCore+Pins): pages and views, sessions and
// workflows, ten of each at most, in the order shown.

const (
	pinsPerFolder  = 10
	pinTitleLength = 60
	viewArguments  = 2048
	pinsFilePath   = ".agents/pins.json"
	// hiddenViewsPerFolder bounds the server views hidden in one folder (#2032).
	hiddenViewsPerFolder = 50
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
	// hiddenViews is the ui:// addresses of the server views a person hid (#2032).
	hiddenViews []string
}

func (f pinsFile) empty() bool {
	return len(f.pins) == 0 && len(f.unread) == 0 && len(f.sessions) == 0 && len(f.workflows) == 0 &&
		len(f.hiddenViews) == 0
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
		// The same folder by another way (on a Mac, /var is /private/var).
		root, full = strings.TrimSuffix(resolved(folder), "/")+"/", resolved(file)
		if !strings.HasPrefix(full, root) {
			return "", false
		}
	}
	return normalizePin(strings.TrimPrefix(full, root))
}

func personPinPath(given, folder string) (string, bool) {
	if strings.HasPrefix(given, "/") {
		return relativePin(given, folder)
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

func pinsFileOf(folder string) string { return filepath.Join(folder, pinsFilePath) }

// readPinsFile is PinsFile.read: good entries, each once, at most the limit.
func readPinsFile(data []byte) (pinsFile, error) {
	var raw struct {
		Pins      []json.RawMessage `json:"pins"`
		Sessions  []sessionPin      `json:"sessions"`
		Workflows []workflowPin     `json:"workflows"`
		Hidden    []string          `json:"hidden_views"`
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
	room := pinsPerFolder - len(f.unread)
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
		if !sessions[s.Session] && len(f.sessions) < pinsPerFolder {
			sessions[s.Session] = true
			f.sessions = append(f.sessions, s)
		}
	}
	workflows := map[string]bool{}
	for _, w := range raw.Workflows {
		if !workflows[w.Workflow] && len(f.workflows) < pinsPerFolder {
			workflows[w.Workflow] = true
			f.workflows = append(f.workflows, w)
		}
	}
	for _, h := range raw.Hidden {
		if strings.HasPrefix(h, "ui://") && !slices.Contains(f.hiddenViews, h) && len(f.hiddenViews) < hiddenViewsPerFolder {
			f.hiddenViews = append(f.hiddenViews, h)
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
	if len(f.hiddenViews) > 0 {
		tree["hidden_views"] = asTree(f.hiddenViews)
	}
	b, err := diskjson.Pretty(tree)
	return append(b, '\n'), err
}

func (d *Daemon) readPins(folder string) pinsFile {
	// The approved copy while a change made outside the app waits (#502).
	b, ok := d.guardedContent(folder, pinsFilePath)
	if !ok {
		return pinsFile{}
	}
	f, err := readPinsFile(b)
	if err != nil {
		return pinsFile{} // a file that does not decode reads as empty
	}
	return f
}

// writePins removes an empty file, writes only what differs, and tells every client.
func (d *Daemon) writePins(f pinsFile, folder string) error {
	if !d.settled(folder, pinsFilePath) {
		return pinRefused(guardedRefusal(pinsFilePath, "The pins were not changed: ").(*Error).Message)
	}
	defer d.approveWrite(folder, pinsFilePath)
	path := pinsFileOf(folder)
	if !ownFolders(folder, ".agents") {
		return pinRefused(linkedFolder(".agents", folder).Message)
	}
	if f.empty() {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return pinRefused("The pins could not be written in " + folder + "/.agents: " + err.Error())
		}
	} else {
		b, err := f.data()
		if err == nil {
			if old, rerr := os.ReadFile(path); rerr != nil || !bytes.Equal(old, b) {
				err = store.WriteAtomically(path, b, 0o644)
			}
		}
		if err != nil {
			return pinRefused("The pins could not be written in " + folder + "/.agents: " + err.Error())
		}
	}
	d.pinsChanged(folder)
	return nil
}

// pinsChanged says pins/changed for a folder, at most once a second.
func (d *Daemon) pinsChanged(folder string) {
	d.pinMu.Lock()
	defer d.pinMu.Unlock()
	if d.pinsStopped {
		return
	}
	if d.pinTimers == nil {
		d.pinTimers = map[string]*time.Timer{}
	}
	if d.pinTimers[folder] != nil {
		return
	}
	d.pinTimers[folder] = time.AfterFunc(time.Second, func() {
		d.pinMu.Lock()
		delete(d.pinTimers, folder)
		stopped := d.pinsStopped
		d.pinMu.Unlock()
		if stopped {
			return
		}
		pp := d.folderPins(folder)
		Broadcast(d, wire.NotifyPinsChanged, wire.PinsChangedNotification{Folder: pp.Folder, Pins: pp.Pins,
			Sessions: pp.Sessions, Workflows: pp.Workflows, Views: pp.Views})
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
		name := "an agent not on this machine"
		if a := d.Store.Agent(wire.UUID(id)); a != nil && a.Title != nil {
			name = *a.Title
		}
		return wire.PinnerView{Kind: wire.PinnerKindAgent, ID: id, Name: name}
	}
	return wire.PinnerView{Kind: wire.PinnerKindPerson, ID: "", Name: "the person"}
}

func (d *Daemon) pinViews(folder string, f pinsFile) []wire.PinView {
	out := []wire.PinView{}
	for _, e := range f.pins {
		v := wire.PinView{Path: e.path, PinnedBy: d.pinnerView(e.pinnedBy), View: e.view}
		if e.view != nil {
			v.Kind, v.Title = wire.PinKindView, defaultViewTitle(*e.view)
			if reason := d.viewPinMissing(*e.view, folder); reason != "" {
				v.Missing, v.MissingReason = true, &reason
			}
		} else {
			v.Kind, _ = pinKind(e.path)
			v.Title = defaultPinTitle(e.path)
			fi, err := os.Stat(filepath.Join(folder, e.path))
			v.Missing = err != nil || fi.IsDir()
		}
		if e.title != nil {
			v.Title = *e.title
		}
		out = append(out, v)
	}
	return out
}

func (d *Daemon) folderPins(folder string) wire.FolderPins {
	f := d.readPins(folder)
	pp := wire.FolderPins{Folder: fileURL(folder, true), Pins: d.pinViews(folder, f), Views: d.serverViews(folder, f)}
	for _, s := range f.sessions {
		pp.Sessions = append(pp.Sessions, s.Session)
	}
	for _, w := range f.workflows {
		pp.Workflows = append(pp.Workflows, w.Workflow)
	}
	return pp
}

// knownPinFolder is a folder this host has as a folder.
func (d *Daemon) knownPinFolder(folder wire.URL) (string, error) {
	path := store.FolderPath(folder)
	for _, s := range d.folders(true) {
		if store.FolderPath(s.Folder.Folder) == path {
			return path, nil
		}
	}
	return "", pinRefused("This machine has no folder at " + path + ".")
}

// pageURL is a file in the folder, its links resolved, still in the folder.
func pageURL(path, folder string) (string, error) {
	rel, ok := personPinPath(path, folder)
	if !ok {
		return "", Invalid("%s is not in this folder.", path)
	}
	full := filepath.Join(folder, rel)
	root, err := store.Resolve(folder)
	if err != nil {
		root = folder
	}
	if r, err := store.Resolve(full); err == nil {
		if !inside(root, r) {
			return "", Invalid("%s is not in this folder.", path)
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
	On(d, wire.CallPinsList, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.FolderPins, error) {
		ps := d.folders(false)
		sort.SliceStable(ps, func(i, j int) bool { return ps[i].LastActivityAt > ps[j].LastActivityAt })
		out := []wire.FolderPins{}
		for _, s := range ps {
			pp := d.folderPins(store.FolderPath(s.Folder.Folder))
			if len(pp.Pins) > 0 || len(pp.Sessions) > 0 || len(pp.Workflows) > 0 || len(pp.Views) > 0 {
				out = append(out, pp)
			}
		}
		return out, nil
	})
	On(d, wire.CallPinsRead, func(ctx context.Context, c *Client, r wire.PinReadRequest) (wire.FileReading, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.FileReading{}, err
		}
		path, err := pageURL(r.Path, folder)
		if err != nil {
			return wire.FileReading{}, err
		}
		return reading(path, r.KnownStamp)
	})
	On(d, wire.CallPinsWrite, func(ctx context.Context, c *Client, r wire.PinWriteRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		path, err := pageURL(r.Path, folder)
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
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return nil, err
		}
		const lead = "Nothing was pinned: "
		entry := pinEntry{title: r.Title, pinnedBy: thePerson()}
		if r.View != nil {
			if why := d.viewPinRefusal(*r.View, folder); why != "" {
				return nil, pinRefused(lead + why)
			}
			entry.path, entry.view = r.View.URI, r.View
			if entry.title == nil && !d.pinned(folder, r.View.URI) {
				entry.title = d.viewPinTitle(*r.View, folder)
			}
			if err := d.pin(entry, folder, lead); err != nil {
				return nil, err
			}
			return d.pinViews(folder, d.readPins(folder)), nil
		}
		path, ok := personPinPath(r.Path, folder)
		if !ok {
			return nil, pinRefused(lead + r.Path + " is not in this folder.")
		}
		if fi, err := os.Stat(filepath.Join(folder, path)); err != nil || !fi.Mode().IsRegular() {
			return nil, pinRefused(lead + "there is no file at " + path + " in the folder.")
		}
		entry.path = path
		if err := d.pin(entry, folder, lead); err != nil {
			return nil, err
		}
		return d.pinViews(folder, d.readPins(folder)), nil
	})
	On(d, wire.CallPinsUnpin, func(ctx context.Context, c *Client, r wire.PinPathRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		key := r.Path
		if !strings.HasPrefix(key, "ui://") {
			if p, ok := personPinPath(r.Path, folder); ok {
				key = p
			}
		}
		f := d.readPins(folder)
		for i, e := range f.pins {
			if e.path == key {
				f.pins = append(f.pins[:i], f.pins[i+1:]...)
				return wire.Empty{}, d.writePins(f, folder)
			}
		}
		return wire.Empty{}, pinRefused("Nothing was unpinned: " + r.Path + " is not pinned in this folder.")
	})
	On(d, wire.CallPinsHideView, func(ctx context.Context, c *Client, r wire.PinHideViewRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		if !strings.HasPrefix(r.URI, "ui://") {
			return wire.Empty{}, Invalid("A view's address starts ui://.")
		}
		f := d.readPins(folder)
		at := slices.Index(f.hiddenViews, r.URI)
		switch {
		case r.Hidden && at < 0:
			if len(f.hiddenViews) >= hiddenViewsPerFolder {
				return wire.Empty{}, pinRefused("Nothing was hidden: this folder already hides 50 views, the most it can.")
			}
			f.hiddenViews = append(f.hiddenViews, r.URI)
		case !r.Hidden && at >= 0:
			f.hiddenViews = slices.Delete(f.hiddenViews, at, at+1)
		default:
			return wire.Empty{}, nil
		}
		return wire.Empty{}, d.writePins(f, folder)
	})
	On(d, wire.CallPinsArrange, func(ctx context.Context, c *Client, r wire.PinArrangeRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		f := d.readPins(folder)
		f.pins = arrange(f.pins, func(e pinEntry) string { return e.path }, r.Paths)
		return wire.Empty{}, d.writePins(f, folder)
	})
	On(d, wire.CallPinsPinSession, func(ctx context.Context, c *Client, r wire.PinSessionRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		const lead = "Nothing was pinned: "
		a := d.Store.Agent(r.AgentID)
		if a == nil || folderPath(a) != folder {
			return wire.Empty{}, pinRefused(lead + "that session is not in this folder.")
		}
		if a.State == wire.AgentStateArchived {
			return wire.Empty{}, pinRefused(lead + "an archived session can't be pinned.")
		}
		f := d.readPins(folder)
		for _, s := range f.sessions {
			if s.Session == a.ID {
				return wire.Empty{}, nil
			}
		}
		if len(f.sessions) >= pinsPerFolder {
			return wire.Empty{}, pinRefused(lead + "this folder already has 10 pinned sessions, the most it can have. Unpin one first.")
		}
		f.sessions = append(f.sessions, sessionPin{Session: a.ID, PinnedBy: thePerson()})
		return wire.Empty{}, d.writePins(f, folder)
	})
	On(d, wire.CallPinsUnpinSession, func(ctx context.Context, c *Client, r wire.PinSessionRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		return wire.Empty{}, d.unpinSession(folder, r.AgentID)
	})
	On(d, wire.CallPinsArrangeSessions, func(ctx context.Context, c *Client, r wire.PinArrangeSessionsRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		order := make([]string, len(r.AgentIDs))
		for i, id := range r.AgentIDs {
			order[i] = strings.ToUpper(string(id))
		}
		f := d.readPins(folder)
		f.sessions = arrange(f.sessions, func(s sessionPin) string { return strings.ToUpper(string(s.Session)) }, order)
		return wire.Empty{}, d.writePins(f, folder)
	})
	On(d, wire.CallPinsPinWorkflow, func(ctx context.Context, c *Client, r wire.WorkflowRequest) (wire.Empty, error) {
		if _, err := d.knownPinFolder(r.Folder); err != nil {
			return wire.Empty{}, err
		}
		// This host keeps no workflows yet.
		return wire.Empty{}, pinRefused("Nothing was pinned: there is no workflow called " + r.WorkflowID + " in this folder.")
	})
	On(d, wire.CallPinsUnpinWorkflow, func(ctx context.Context, c *Client, r wire.WorkflowRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		f := d.readPins(folder)
		for i, w := range f.workflows {
			if w.Workflow == r.WorkflowID {
				f.workflows = append(f.workflows[:i], f.workflows[i+1:]...)
				return wire.Empty{}, d.writePins(f, folder)
			}
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallPinsArrangeWorkflows, func(ctx context.Context, c *Client, r wire.PinArrangeWorkflowsRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		f := d.readPins(folder)
		f.workflows = arrange(f.workflows, func(w workflowPin) string { return w.Workflow }, r.WorkflowIDs)
		return wire.Empty{}, d.writePins(f, folder)
	})
}

// pin is DaemonCore.pin: retitled where it is, or added under the limit.
func (d *Daemon) pin(entry pinEntry, folder, lead string) error {
	if _, ok := pinKind(entry.path); entry.view == nil && !ok {
		return pinRefused(lead + "only a Markdown (.md) or HTML (.html) page can be pinned.")
	}
	if entry.title != nil && utf8.RuneCountInString(*entry.title) > pinTitleLength {
		return pinRefused(lead + "`title` is at most 60 characters.")
	}
	f := d.readPins(folder)
	for i, e := range f.pins {
		if e.path == entry.path {
			if entry.title != nil {
				f.pins[i].title = entry.title
			}
			if entry.view != nil {
				f.pins[i].view = entry.view
			}
			return d.writePins(f, folder)
		}
	}
	if len(f.pins)+len(f.unread) >= pinsPerFolder {
		return pinRefused(lead + "this folder already has 10 pins, pages and views together, the most it can have. Unpin one first.")
	}
	f.pins = append(f.pins, entry)
	return d.writePins(f, folder)
}

func (d *Daemon) unpinSession(folder string, id wire.UUID) error {
	f := d.readPins(folder)
	for i, s := range f.sessions {
		if strings.EqualFold(string(s.Session), string(id)) {
			f.sessions = append(f.sessions[:i], f.sessions[i+1:]...)
			return d.writePins(f, folder)
		}
	}
	return nil
}

// stopPins stops the pins/changed waiting to be said, and says none again: a stopped
// host reading a folder's pins reads its servers' views too, and the person's servers are
// found by the environment, so a host that stopped would read another one's (#2673).
func (d *Daemon) stopPins() {
	d.pinMu.Lock()
	defer d.pinMu.Unlock()
	d.pinsStopped = true
	for folder, t := range d.pinTimers {
		t.Stop()
		delete(d.pinTimers, folder)
	}
}

func (d *Daemon) pinsHaveStopped() bool {
	d.pinMu.Lock()
	defer d.pinMu.Unlock()
	return d.pinsStopped
}

// pinState is the Daemon's: pins/changed waiting to be said, by folder.
type pinState struct {
	pinMu       sync.Mutex
	pinTimers   map[string]*time.Timer
	pinsStopped bool
}
