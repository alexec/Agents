package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

// What a new session's form offers (DaemonCore.options): agents/options asks the runtime
// for its options and commands, and keeps them in <cache>/option-cache.json as the Swift
// host does, so the next form shows them at once and is told of any change after.
//
// The Swift host keeps the session it opened, and the start takes it. This host opens one
// only to ask, and lets it go: the start opens its own (#1136).

// optionBook is the drafts a form holds open, and the remembered offers, under optionMu.
type optionBook struct {
	optionMu   sync.Mutex
	openDrafts map[wire.UUID]bool
}

// optionEntry is OptionCache.Entry.
type optionEntry struct {
	Options  []wire.ConfigOption `json:"options"`
	Commands []wire.SlashCommand `json:"commands"`
	SavedAt  wire.Date           `json:"savedAt"`
}

func (e optionEntry) worthKeeping() bool { return len(e.Options) > 0 || len(e.Commands) > 0 }

const optionCacheLimit = 50

// commandsWait is how long a new session waits for its commands, which come as an update a
// moment after the session itself (whatItOffers).
var commandsWait = 500 * time.Millisecond

func (d *Daemon) optionCachePath() string {
	return filepath.Join(d.Store.Loc.Cache, "option-cache.json")
}

// optionKey is OptionCache.key: the runtime, the folder and the servers' names.
func optionKey(runtimeID string, cwd wire.URL, servers []wire.MCPServer) string {
	names := make([]string, 0, len(servers))
	for _, s := range servers {
		names = append(names, mcpServerName(s))
	}
	sort.Strings(names)
	return runtimeID + "\t" + filepath.Clean(store.FolderPath(cwd)) + "\t" + strings.Join(names, ",")
}

func mcpServerName(s wire.MCPServer) string {
	b, _ := json.Marshal(s)
	var v struct {
		Name string `json:"name"`
	}
	json.Unmarshal(b, &v)
	return v.Name
}

func (d *Daemon) remembered(key string) (optionEntry, bool) {
	d.optionMu.Lock()
	defer d.optionMu.Unlock()
	var cache map[string]optionEntry
	b, err := os.ReadFile(d.optionCachePath())
	if err != nil || diskjson.Unmarshal(b, &cache) != nil {
		return optionEntry{}, false
	}
	e, ok := cache[key]
	return e, ok && e.worthKeeping()
}

// runtimeOffers is the options a runtime last offered in any folder, newest first, or nil:
// what a start's model is matched with before its session says its own (#2274).
func (d *Daemon) runtimeOffers(runtimeID string) []wire.ConfigOption {
	d.optionMu.Lock()
	defer d.optionMu.Unlock()
	var cache map[string]optionEntry
	b, err := os.ReadFile(d.optionCachePath())
	if err != nil || diskjson.Unmarshal(b, &cache) != nil {
		return nil
	}
	var newest optionEntry
	for k, e := range cache {
		if strings.HasPrefix(k, runtimeID+"\t") && len(e.Options) > 0 && e.SavedAt > newest.SavedAt {
			newest = e
		}
	}
	return newest.Options
}

// remember keeps what a runtime offered, the 50 newest.
func (d *Daemon) remember(key string, e optionEntry) {
	if !e.worthKeeping() {
		return
	}
	d.optionMu.Lock()
	defer d.optionMu.Unlock()
	cache := map[string]optionEntry{}
	if b, err := os.ReadFile(d.optionCachePath()); err == nil {
		diskjson.Unmarshal(b, &cache)
	}
	e.SavedAt = now()
	cache[key] = e
	if len(cache) > optionCacheLimit {
		keys := make([]string, 0, len(cache))
		for k := range cache {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool { return cache[keys[i]].SavedAt > cache[keys[j]].SavedAt })
		for _, k := range keys[optionCacheLimit:] {
			delete(cache, k)
		}
	}
	os.MkdirAll(d.Store.Loc.Cache, 0o755)
	if err := writeStore(d.optionCachePath(), cache); err != nil {
		log.Printf("option-cache.json: could not save: %v", err)
	}
}

// options is agents/options.
func (d *Daemon) options(r wire.OptionsRequest) (wire.OptionsResponse, error) {
	rt := runtimeByID(r.RuntimeID)
	if rt == nil {
		return wire.OptionsResponse{}, &Error{Code: CodeRuntimeNotFound, Message: "no runtime " + r.RuntimeID}
	}
	path := store.FolderPath(r.Cwd)
	if !isDir(path) {
		return wire.OptionsResponse{}, &Error{Code: CodeFolderGone, Message: path + " is not there any more."}
	}
	if err := d.needsSignIn(r.RuntimeID); err != nil {
		return wire.OptionsResponse{}, err
	}
	draft := store.NewUUID()
	d.optionMu.Lock()
	if d.openDrafts == nil {
		d.openDrafts = map[wire.UUID]bool{}
	}
	d.openDrafts[draft] = true
	d.optionMu.Unlock()
	key := optionKey(r.RuntimeID, r.Cwd, r.McpServers)
	if shown, ok := d.remembered(key); ok {
		// Shown at once; the runtime is asked after, and a change is said (settleDraft).
		safe.Go("draft options", func() { d.settleDraft(draft, key, rt, path, shown) })
		return wire.OptionsResponse{DraftID: draft, Options: d.markOptions(r.RuntimeID, shown.Options), Commands: shown.Commands}, nil
	}
	e, err := d.whatItOffers(rt, path)
	if err != nil {
		d.closeDraft(draft)
		return wire.OptionsResponse{}, err
	}
	d.remember(key, e)
	return wire.OptionsResponse{DraftID: draft, Options: d.markOptions(r.RuntimeID, e.Options), Commands: e.Commands}, nil
}

func (d *Daemon) settleDraft(draft wire.UUID, key string, rt *runtimeDef, path string, shown optionEntry) {
	e, err := d.whatItOffers(rt, path)
	if err != nil {
		if d.closeDraft(draft) {
			msg := err.Error()
			if e, ok := err.(*Error); ok {
				msg = e.Message
			}
			Broadcast(d, wire.NotifyAgentsDraftOptions, wire.DraftOptionsNotification{DraftID: draft,
				Options: []wire.ConfigOption{}, Commands: []wire.SlashCommand{}, Failure: &msg})
		}
		return
	}
	d.remember(key, e)
	d.optionMu.Lock()
	open := d.openDrafts[draft]
	d.optionMu.Unlock()
	if !open || (sameJSON(e.Options, shown.Options) && sameJSON(e.Commands, shown.Commands)) {
		return
	}
	Broadcast(d, wire.NotifyAgentsDraftOptions, wire.DraftOptionsNotification{DraftID: draft, Options: d.markOptions(rt.ID, e.Options), Commands: e.Commands})
}

// closeDraft lets a draft go (agents/discardDraft, or the start that used it), and says
// whether it was open.
func (d *Daemon) closeDraft(draft wire.UUID) bool {
	d.optionMu.Lock()
	defer d.optionMu.Unlock()
	open := d.openDrafts[draft]
	delete(d.openDrafts, draft)
	return open
}

func sameJSON(a, b any) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}

// whatItOffers opens a session in the folder, with the folder's servers and the
// person's, and reads what it offers: its options with the session, its commands a moment
// after.
func (d *Daemon) whatItOffers(rt *runtimeDef, path string) (optionEntry, error) {
	launch, err := d.launchFor(rt, path)
	if err != nil {
		return optionEntry{}, err
	}
	ctx, cancel := context.WithTimeout(d.ctx, 90*time.Second)
	defer cancel()
	p := &probe{commands: make(chan []wire.SlashCommand, 1)}
	meta := sessionMeta(rt.ID)
	s, err := acp.Start(ctx, launch, p, d.sessionMCP(path), meta, meta, "", "")
	if err != nil {
		return optionEntry{}, &Error{Code: CodeRuntimeWillNotStart, Message: rt.Name + " did not start: " + err.Error()}
	}
	defer s.Stop()
	e := optionEntry{Options: []wire.ConfigOption{}, Commands: []wire.SlashCommand{}}
	if opts := configOptions(s.NewResult.ConfigOptions); opts != nil {
		e.Options = opts
	}
	select {
	case cmds := <-p.commands:
		e.Commands = cmds
	case <-time.After(commandsWait):
	}
	if opts := p.lastOptions(); opts != nil {
		e.Options = opts
	}
	// The app's own options beside the runtime's, off for a new chat (#1837).
	e.Options = withAppOptions(rt.ID, nil, e.Options)
	return e, nil
}

// probe is the session whatItOffers opens: it hears the offers, and refuses anything else.
type probe struct {
	mu       sync.Mutex
	options  []wire.ConfigOption
	commands chan []wire.SlashCommand
}

func (p *probe) Update(n sdk.SessionNotification) {
	u := n.Update
	switch {
	case u.ConfigOptionUpdate != nil:
		if opts := configOptions(u.ConfigOptionUpdate.ConfigOptions); opts != nil {
			p.mu.Lock()
			p.options = opts
			p.mu.Unlock()
		}
	case u.AvailableCommandsUpdate != nil:
		b, _ := json.Marshal(u.AvailableCommandsUpdate.AvailableCommands)
		var cmds []wire.SlashCommand
		if json.Unmarshal(b, &cmds) == nil && cmds != nil {
			select {
			case p.commands <- cmds:
			default:
			}
		}
	}
}

func (p *probe) lastOptions() []wire.ConfigOption {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.options
}

func (p *probe) Permission(context.Context, sdk.RequestPermissionRequest) string { return "" }
func (p *probe) Served(string, string)                                           {}
func (p *probe) Elicitation(context.Context, json.RawMessage) (string, map[string]any) {
	return "cancel", nil
}
func (p *probe) ElicitationComplete(string) {}

func (d *Daemon) registerOptions() {
	On(d, wire.CallAgentsOptions, func(ctx context.Context, c *Client, r wire.OptionsRequest) (wire.OptionsResponse, error) {
		return d.options(r)
	})
	On(d, wire.CallAgentsDiscardDraft, func(ctx context.Context, c *Client, r wire.DiscardDraftRequest) (wire.Empty, error) {
		d.closeDraft(r.DraftID)
		return wire.Empty{}, nil
	})
}
