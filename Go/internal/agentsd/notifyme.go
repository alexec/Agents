package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Notify me (#2034, specs/2034-notify-me): the person chooses events of the project's
// github, gitlab and linear servers that tell them. Each chosen event is a subscription, as a
// workflow's trigger makes one, shared with a workflow that names the same. What it brings is
// a notice: a need of the kind notice, which spec 021's ladder offers as it offers the
// others, to the window or through the control plane to a device. A notice is not a Needs
// you row: it goes when it is opened (notice/open), or after a day. The choices are the
// person's, kept on this host in <root>/notify-me.json, by project, server and event.

// noticeFor is how long a notice that nobody opened is offered.
var noticeFor = 24 * time.Hour

// notifyDef is one event a server can tell the person of, the arguments that make it theirs,
// and whether it is on before the person chooses.
type notifyDef struct {
	event, title string
	arguments    map[string]json.RawMessage
	on           bool
}

var mine = map[string]json.RawMessage{"mine": json.RawMessage("true")}

// notifyDefs are the events each made-by-Agents server offers to Notify me, in the list's order.
var notifyDefs = map[string][]notifyDef{
	"agents/github": {
		{event: "checks.failed", title: "A PR of mine failed its checks", arguments: mine, on: true},
		{event: "pr.conflicted", title: "A PR of mine is in conflict", arguments: mine},
		{event: "review.requested", title: "A review was requested from me", on: true},
		{event: "issue.assigned", title: "An issue was assigned to me"},
	},
	"agents/gitlab": {
		{event: "checks.failed", title: "A merge request of mine failed its pipeline", arguments: mine, on: true},
		{event: "pr.conflicted", title: "A merge request of mine is in conflict", arguments: mine},
		{event: "review.requested", title: "A review was requested from me", on: true},
		{event: "issue.assigned", title: "An issue was assigned to me"},
	},
	"agents/linear": {
		{event: "issue.assigned", title: "An issue was assigned to me"},
	},
}

// notice is what a chosen event brought, until it is opened or a day old.
type notice struct {
	id, folder, title, sentence, url string
	at                                       time.Time
}

type notifyBook struct {
	notifyMu sync.Mutex
	// notifyChoices is notify-me.json: folder → server → event → on; nil until read.
	notifyChoices map[string]map[string]map[string]bool
	// notices are under attentionMu, as the needs are.
	notices map[string]notice
}

func (d *Daemon) registerNotifyMe() {
	On(d, wire.CallNotifyList, func(_ context.Context, _ *Client, r wire.NotifyListRequest) (wire.NotifyList, error) {
		folder, err := d.setupProject(r.Folder)
		if err != nil {
			return wire.NotifyList{}, err
		}
		return d.notifyList(folder), nil
	})
	On(d, wire.CallNotifySet, func(_ context.Context, _ *Client, r wire.NotifySetRequest) (wire.NotifyList, error) {
		folder, err := d.setupProject(r.Folder)
		if err != nil {
			return wire.NotifyList{}, err
		}
		if _, ok := d.notifyDef(folder, r.Server, r.Event); !ok {
			return wire.NotifyList{}, invalid(r.Server + " has no " + r.Event + " to notify you of here.")
		}
		d.notifyMu.Lock()
		choices := d.notifyChoicesLocked()
		if choices[folder] == nil {
			choices[folder] = map[string]map[string]bool{}
		}
		if choices[folder][r.Server] == nil {
			choices[folder][r.Server] = map[string]bool{}
		}
		choices[folder][r.Server][r.Event] = r.On
		d.saveNotifyLocked()
		d.notifyMu.Unlock()
		log.Printf("notify me: %s %s %s", r.Server, r.Event, map[bool]string{true: "on", false: "off"}[r.On])
		d.kickMCPEvents()
		return d.notifyList(folder), nil
	})
	On(d, wire.CallNoticeOpen, func(_ context.Context, _ *Client, r wire.NoticeOpenRequest) (wire.Empty, error) {
		d.attentionMu.Lock()
		delete(d.notices, r.ID)
		d.attentionMu.Unlock()
		d.reconsider()
		return wire.Empty{}, nil
	})
}

func (d *Daemon) notifyPath() string { return filepath.Join(d.Store.Loc.Root, "notify-me.json") }

// notifyChoicesLocked reads the file once. notifyMu is held.
func (d *Daemon) notifyChoicesLocked() map[string]map[string]map[string]bool {
	if d.notifyChoices == nil {
		d.notifyChoices = map[string]map[string]map[string]bool{}
		if b, err := os.ReadFile(d.notifyPath()); err == nil {
			if err := json.Unmarshal(b, &d.notifyChoices); err != nil {
				log.Printf("notify me: notify-me.json could not be read, so every event is as it is at first")
				d.notifyChoices = map[string]map[string]map[string]bool{}
			}
		}
	}
	return d.notifyChoices
}

// saveNotifyLocked writes the choices of projects this host still has. notifyMu is held.
func (d *Daemon) saveNotifyLocked() {
	for folder := range d.notifyChoices {
		if _, ok := d.summaryFor(folder); !ok {
			delete(d.notifyChoices, folder)
		}
	}
	b, err := json.Marshal(d.notifyChoices)
	if err == nil {
		err = store.WriteAtomically(d.notifyPath(), b, 0o600)
	}
	if err != nil {
		log.Printf("notify me: the choices were not kept: %v", err)
	}
}

// notifyServer is a server of the project that Notify me knows: its name there, and which of ours it is.
type notifyServer struct {
	name string
	ours mcpcatalog.Ours
}

// notifyServers are the project's made-by-Agents servers with events for Notify me: its own
// entries, then the person's, each name once.
func (d *Daemon) notifyServers(folder string) []notifyServer {
	entries, _ := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
	if home := d.personalHome(); home != "" {
		personal, _ := readMCPFile(filepath.Join(home, ".agents", "mcp.json"))
		entries = append(entries, personal...)
	}
	var out []notifyServer
	seen := map[string]bool{}
	for _, e := range entries {
		if seen[e.name] || e.server.Stdio == nil {
			continue
		}
		seen[e.name] = true
		if o, ok := mcpcatalog.OursByCommand(e.server.Stdio.Command); ok && len(notifyDefs[o.ID]) > 0 {
			out = append(out, notifyServer{name: e.name, ours: o})
		}
	}
	return out
}

func (d *Daemon) notifyDef(folder, server, event string) (notifyDef, bool) {
	for _, s := range d.notifyServers(folder) {
		if s.name != server {
			continue
		}
		for _, def := range notifyDefs[s.ours.ID] {
			if def.event == event {
				return def, true
			}
		}
	}
	return notifyDef{}, false
}

// notifyOn is whether the person chose the event, or it is on at first.
func (d *Daemon) notifyOn(folder, server string, def notifyDef) bool {
	d.notifyMu.Lock()
	defer d.notifyMu.Unlock()
	if on, ok := d.notifyChoicesLocked()[folder][server][def.event]; ok {
		return on
	}
	return def.on
}

func (d *Daemon) notifyList(folder string) wire.NotifyList {
	out := wire.NotifyList{Folder: folder, Servers: []wire.NotifyServer{}}
	for _, s := range d.notifyServers(folder) {
		ns := wire.NotifyServer{Server: s.name, Title: s.ours.Title, Events: []wire.NotifyEvent{}}
		for _, def := range notifyDefs[s.ours.ID] {
			ns.Events = append(ns.Events, wire.NotifyEvent{Event: def.event, Title: def.title, On: d.notifyOn(folder, s.name, def)})
		}
		out.Servers = append(out.Servers, ns)
	}
	return out
}

// addNotifyMe adds a subscription for each event the person has on, in each project, beside
// the workflows' and the waits'. An event the server does not offer (an older server) is left out.
func (d *Daemon) addNotifyMe(wanted map[string]*mcpSubscription, servers func(folder string) map[string]found) {
	for _, p := range d.Store.Projects() {
		if p.ArchivedAt != nil {
			continue
		}
		folder := store.FolderPath(p.Folder)
		for _, s := range d.notifyServers(folder) {
			var listing *mcpListing
			for _, def := range notifyDefs[s.ours.ID] {
				if !d.notifyOn(folder, s.name, def) {
					continue
				}
				f, ok := servers(folder)[s.name]
				if !ok || f.problem != "" {
					break
				}
				if listing == nil {
					l := d.mcpEventListing(f.server)
					listing = &l
				}
				var offered *mcpEventDef
				for i, e := range listing.events {
					if e.Name == def.event && e.offersPoll() {
						offered = &listing.events[i]
					}
				}
				if offered == nil {
					continue
				}
				t := mcpTrigger{event: def.event, arguments: def.arguments}
				key := t.subscriptionKey(s.name)
				id := mcpRecordKey(folder, key)
				if sub := wanted[id]; sub != nil {
					sub.notify = true
					continue
				}
				wanted[id] = &mcpSubscription{id: id, key: key, project: folder, server: s.name, event: def.event,
					arguments: def.arguments, notify: true, pool: f.server.pool(), filled: f.server.filled,
					cwd: f.server.cwd, fingerprint: offered.wireText() + "\n" + f.server.entry}
			}
		}
	}
}

// addNotice keeps what a chosen event brought, and offers it. The same item and event from
// two projects (one repo, two folders) is one notice.
func (d *Daemon) addNotice(e mcpPolled, s *mcpSubscription) {
	title := s.server
	for _, ns := range d.notifyServers(s.project) {
		if ns.name == s.server {
			title = ns.ours.Title
		}
	}
	sentence, url := noticeWords(s.event, e.Data)
	sum := sha256.Sum256([]byte(title + "\n" + s.event + "\n" + url + "\n" + sentence))
	id := hex.EncodeToString(sum[:])[:16]
	d.attentionMu.Lock()
	if d.notices == nil {
		d.notices = map[string]notice{}
	}
	if _, ok := d.notices[id]; !ok {
		d.notices[id] = notice{id: id, folder: s.project, title: title, sentence: sentence, url: url, at: time.Now()}
		log.Printf("notify me: %s %s brought a notice", s.server, s.event)
	}
	d.attentionMu.Unlock()
	d.reconsider()
}

// noticeWords is a notice's line and the address it opens, from the event's data.
func noticeWords(event string, data json.RawMessage) (string, string) {
	var payload struct {
		PR    *noticeItem `json:"pr"`
		Issue *noticeItem `json:"issue"`
	}
	_ = json.Unmarshal(data, &payload)
	item := noticeItem{}
	if payload.PR != nil {
		item = *payload.PR
	} else if payload.Issue != nil {
		item = *payload.Issue
	}
	name := item.name()
	switch event {
	case "checks.failed":
		return "Checks failed on " + name, item.URL
	case "pr.conflicted":
		return name + " is in conflict", item.URL
	case "review.requested":
		return "Review requested on " + name, item.URL
	case "issue.assigned":
		return "Assigned to you: " + name, item.URL
	}
	return event + ": " + name, item.URL
}

type noticeItem struct {
	Number     int    `json:"number"`
	Identifier string `json:"identifier"`
	Title      string `json:"title"`
	URL        string `json:"url"`
}

// name is "#12 Fix the walk", or Linear's "ENG-12 Fix the walk".
func (i noticeItem) name() string {
	switch {
	case i.Identifier != "":
		return i.Identifier + " " + i.Title
	case i.Number > 0:
		return fmt.Sprintf("#%d %s", i.Number, i.Title)
	}
	return i.Title
}

// noticeNeeds are the notices as needs, the oldest first; one a day old goes. Called with
// attentionMu held.
func (d *Daemon) noticeNeedsLocked(at time.Time) []wire.Need {
	var out []wire.Need
	for id, n := range d.notices {
		if at.Sub(n.at) >= noticeFor {
			delete(d.notices, id)
			continue
		}
		nid, url := n.id, n.url
		need := wire.Need{ID: wire.NeedID{Notice: &nid}, Folder: fileURL(n.folder, true), Kind: wire.NeedKindNotice,
			RaisedAt: wire.DateOf(n.at), Headline: truncating(wire.Headline{H1: filepath.Base(n.folder), H2: n.title, H3: n.sentence})}
		if url != "" {
			need.URL = &url
		}
		out = append(out, need)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RaisedAt < out[j].RaisedAt })
	return out
}
