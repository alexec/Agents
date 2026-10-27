package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// KeptPrefix is KeptRequests.prefix.
const KeptPrefix = "v1/kept/"

// KeptLimit is KeptRequests.limit: at most this many per host.
const KeptLimit = 20

// KeptRequest is DaemonAPI.KeptRequest: a kept request, as clients draw it, never its
// attachments or options. Kind is prompt (to an agent there, AgentID) or start (a new
// agent in a folder there: Folder and RuntimeID); Text is the prompt's words, or the new
// agent's first prompt; Failed, that it was not sent, and why (US3 AS4).
type KeptRequest = wire.KeptRequest

// KeepRequest is DaemonAPI.KeepRequest: hosts/keep.
type KeepRequest = wire.KeepRequest

// KeptRequestID is DaemonAPI.KeptRequestID: hosts/dropKept, hosts/retryKept.
type KeptRequestID = wire.KeptRequestID

// KeptList is DaemonAPI.KeptList.
type KeptList = wire.KeptList

// KeptDelivered is DaemonAPI.KeptDelivered: control/keptDelivered.
type KeptDelivered = wire.KeptDelivered

// keptRecord is KeptRequests.Record: as it is stored, the request itself and who sent it.
type keptRecord struct {
	ID         string          `json:"id"`
	Host       string          `json:"host"`
	Method     string          `json:"method"`
	Params     json.RawMessage `json:"params,omitempty"`
	Client     string          `json:"client"`
	ClientKind string          `json:"clientKind"`
	At         records.Stamp   `json:"at"`
	Failed     string          `json:"failed,omitempty"`
}

func (r keptRecord) kind() string {
	if r.Method == MethodAgentsStart {
		return "start"
	}
	return "prompt"
}

type keptEntry struct {
	key    string
	record keptRecord
}

// KeptHooks is KeptRequests.Hooks: what it needs of the workspace part.
type KeptHooks struct {
	// Keepable is the host's name when its workspace is stopped or starting and starts when
	// used; "" when its requests are refused as today.
	Keepable func(host string) string
	// Start starts the host's workspace, or joins the start under way, for by.
	Start func(host, by string)
	// OwnerOf is the person a host belongs to: only they are shown what was kept for it.
	OwnerOf func(host string) string
}

// eachSession is a router that tells one person's sessions alone.
type eachSession interface {
	TellPerson(person, method string, params any)
}

// Kept is KeptRequests (#691 US3, research R9): prompts and agent starts for a stopped
// workspace, kept until its host connects. Each is kept in the store at
// v1/kept/<host>/<seq>.json, so it outlives the client that sent it and a restart. When
// the host attaches, what was kept goes in order, each on a channel bound to the client
// that sent it, and is deleted once the host has answered. Each goes with an id of its own
// (sendID, requestID) that the host dedupes.
type Kept struct {
	store  store.Store
	router Router
	hooks  KeptHooks
	log    func(string)

	mu         sync.Mutex
	kept       map[string][]keptEntry
	delivering map[string]bool
	loaded     bool
}

// NewKept is KeptRequests.init.
func NewKept(s store.Store, router Router, hooks KeptHooks, log func(string)) *Kept {
	if log == nil {
		log = func(string) {}
	}
	if hooks.OwnerOf == nil {
		hooks.OwnerOf = func(string) string { return "" }
	}
	return &Kept{store: s, router: router, hooks: hooks, log: log, kept: map[string][]keptEntry{}, delivering: map[string]bool{}}
}

// NewKeptFor is KeptRequests wired to providers as ControlService wires it, and handed to
// them: the router's keeper is its Keep and Attached.
func NewKeptFor(p *Providers, log func(string)) *Kept {
	k := NewKept(p.store, p.router, KeptHooks{Keepable: p.Keepable, Start: p.StartForUse, OwnerOf: p.hooks.OwnerOf}, log)
	p.KeepWith(k)
	return k
}

// Load reads what was kept before a restart.
func (k *Kept) Load() {
	k.mu.Lock()
	if k.loaded {
		k.mu.Unlock()
		return
	}
	k.loaded = true
	k.mu.Unlock()
	ctx := context.Background()
	keys, err := k.store.List(ctx, KeptPrefix)
	if err != nil {
		return
	}
	names := make([]string, 0, len(keys))
	for _, key := range keys {
		names = append(names, key.Key)
	}
	sort.Strings(names)
	for _, key := range names {
		object, err := k.store.Get(ctx, key)
		if err != nil || object == nil {
			continue
		}
		var record keptRecord
		if decodeJSON(object.Data, &record) != nil || !isUUID(record.ID) || record.Host == "" || record.Method == "" {
			continue
		}
		record.ID, record.Client = strings.ToUpper(record.ID), strings.ToUpper(record.Client)
		k.mu.Lock()
		k.kept[record.Host] = append(k.kept[record.Host], keptEntry{key, record})
		k.mu.Unlock()
	}
}

// Keep is KeptHandling.keep: a prompt or an agent start for a host that cannot take it
// now. The error to answer with, kept when it was kept, another refusal, or nil to refuse
// it as today.
func (k *Kept) Keep(host, method string, params json.RawMessage, caller Caller) *Failure {
	k.Load()
	if !KeptMethods[method] {
		return nil
	}
	name := k.hooks.Keepable(host)
	if name == "" {
		return nil
	}
	k.mu.Lock()
	waiting := 0
	for _, e := range k.kept[host] {
		if e.record.Failed == "" {
			waiting++
		}
	}
	k.mu.Unlock()
	if waiting >= KeptLimit {
		return fail(CodeHostOffline, "%s is starting; too many prompts are waiting.", name)
	}
	record := keptRecord{ID: records.NewUUID(), Host: host, Method: method, Params: once(method, params),
		Client: strings.ToUpper(caller.Client), ClientKind: caller.Kind, At: records.Now()}
	if record.ClientKind == "" {
		record.ClientKind = "unknown"
	}
	key := KeptPrefix + host + "/" + sequence(record.At.Time) + "-" + record.ID + ".json"
	data, err := records.Encode(record)
	if err == nil {
		_, err = k.store.Put(context.Background(), key, data, store.Absent)
	}
	if err != nil {
		return fail(CodeStoreUnavailable, "%s is stopped, and the control plane couldn’t keep this to send later.", name)
	}
	k.mu.Lock()
	k.kept[host] = append(k.kept[host], keptEntry{key, record})
	k.mu.Unlock()
	k.log(fmt.Sprintf("workspace: kept %s for %s from client %s", record.kind(), name, shortID(caller.Client)))
	k.changed()
	k.hooks.Start(host, "kept "+record.kind())
	// It may have come up while this was being written.
	if k.router.Online(host) {
		go k.Attached(host)
	}
	f := fail(CodeKept, "%s is starting. This is sent when it connects.", name)
	f.Data = rawOf(summary(record))
	return f
}

// Attached is KeptHandling.attached: a host's uplink is up, and what was kept for it goes
// now, in order.
func (k *Kept) Attached(host string) {
	k.Load()
	k.mu.Lock()
	if k.delivering[host] {
		k.mu.Unlock()
		return
	}
	k.delivering[host] = true
	k.mu.Unlock()
	defer func() {
		k.mu.Lock()
		delete(k.delivering, host)
		k.mu.Unlock()
	}()
	for {
		k.mu.Lock()
		var next *keptRecord
		for _, e := range k.kept[host] {
			if e.record.Failed == "" {
				r := e.record
				next = &r
				break
			}
		}
		k.mu.Unlock()
		if next == nil {
			break
		}
		reply := k.router.DeliverKept(next.Method, next.Params, next.Client, next.ClientKind, host, time.Minute)
		if reply == nil {
			// Gone again before it answered, or not answering: it stays for next time.
			return
		}
		if reply.Error != nil {
			// The host said no (its folder has gone, say): not sent, in its words.
			k.log(fmt.Sprintf("workspace: kept %s for %s refused: %s", next.kind(), host, reply.Error.Message))
			k.fail(host, next.ID, reply.Error.Message)
			continue
		}
		k.remove(host, next.ID)
		k.log(fmt.Sprintf("workspace: delivered kept %s to %s", next.kind(), host))
		delivered := KeptDelivered{Host: wire.MachineRef(host), ID: wire.UUID(next.ID)}
		if next.Method == MethodAgentsStart {
			var agent string
			if json.Unmarshal(reply.Result, &agent) == nil {
				delivered.AgentID = optional(wire.UUID(uuidOf(agent)))
			}
		}
		if tell, ok := k.router.(eachSession); ok {
			tell.TellPerson(k.hooks.OwnerOf(host), NoticeKeptDelivered, delivered)
		} else {
			k.router.BroadcastControl(NoticeKeptDelivered, delivered)
		}
	}
	k.changed()
}

// All is every kept request, by host, each host's in order.
func (k *Kept) All() []KeptRequest {
	k.Load()
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.allLocked()
}

// For is the kept requests of the person's own hosts: no one sees another's (FR-018).
func (k *Kept) For(person string) []KeptRequest {
	k.Load()
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.listLocked(func(host string) bool { return k.hooks.OwnerOf(host) == person })
}

func (k *Kept) allLocked() []KeptRequest {
	return k.listLocked(func(string) bool { return true })
}

func (k *Kept) listLocked(shown func(host string) bool) []KeptRequest {
	hosts := make([]string, 0, len(k.kept))
	for h := range k.kept {
		if shown(h) {
			hosts = append(hosts, h)
		}
	}
	sort.Strings(hosts)
	out := []KeptRequest{}
	for _, h := range hosts {
		for _, e := range k.kept[h] {
			out = append(out, summary(e.record))
		}
	}
	return out
}

// Answer is hosts/listKept, hosts/dropKept and hosts/retryKept, for the person who asked:
// only of their own hosts.
func (k *Kept) Answer(method string, params json.RawMessage, person string) (any, error) {
	k.Load()
	switch method {
	case MethodHostsListKept:
		return KeptList{Kept: k.For(person)}, nil
	case MethodHostsDropKept:
		which, err := requireKeptID(params)
		if err != nil {
			return nil, err
		}
		if k.hooks.OwnerOf(string(which.Host)) != person {
			return nil, invalid("That was sent or dropped already.")
		}
		k.remove(string(which.Host), string(which.ID))
		k.log("workspace: dropped kept request for " + string(which.Host))
		k.changed()
		return map[string]any{}, nil
	case MethodHostsRetryKept:
		which, err := requireKeptID(params)
		if err != nil {
			return nil, err
		}
		host := string(which.Host)
		if k.hooks.OwnerOf(host) != person {
			return nil, invalid("That was sent or dropped already.")
		}
		k.mu.Lock()
		index := -1
		for i, e := range k.kept[host] {
			if e.record.ID == string(which.ID) {
				index = i
			}
		}
		if index < 0 {
			k.mu.Unlock()
			return nil, invalid("That was sent or dropped already.")
		}
		entry := &k.kept[host][index]
		entry.record.Failed = ""
		key, record := entry.key, entry.record
		k.mu.Unlock()
		if data, err := records.Encode(record); err == nil {
			k.store.Put(context.Background(), key, data, store.Always)
		}
		k.changed()
		if k.router.Online(host) {
			go k.Attached(host)
		} else {
			k.hooks.Start(host, "kept "+record.kind()+", tried again")
		}
		return map[string]any{}, nil
	}
	return nil, methodNotFound(method)
}

// StartFailed is KeptRequests.startFailed: every request waiting on the start is shown not
// sent, with why (US3 AS4).
func (k *Kept) StartFailed(host, reason string) {
	k.Load()
	k.fail(host, "", reason)
	k.changed()
}

// Forget is KeptRequests.forget: a host was removed, and what was kept for it goes, not sent.
func (k *Kept) Forget(host string) {
	k.Load()
	k.mu.Lock()
	entries := k.kept[host]
	delete(k.kept, host)
	k.mu.Unlock()
	for _, e := range entries {
		k.store.Delete(context.Background(), e.key)
	}
	k.changed()
}

func (k *Kept) fail(host, only, reason string) {
	k.mu.Lock()
	var writes []keptEntry
	for i := range k.kept[host] {
		e := &k.kept[host][i]
		if e.record.Failed == "" && (only == "" || e.record.ID == only) {
			e.record.Failed = reason
			writes = append(writes, *e)
		}
	}
	k.mu.Unlock()
	for _, e := range writes {
		if data, err := records.Encode(e.record); err == nil {
			k.store.Put(context.Background(), e.key, data, store.Always)
		}
	}
}

func (k *Kept) remove(host, id string) {
	k.mu.Lock()
	entries := k.kept[host]
	key := ""
	for i, e := range entries {
		if e.record.ID == id {
			key = e.key
			entries = append(entries[:i:i], entries[i+1:]...)
			break
		}
	}
	if len(entries) == 0 {
		delete(k.kept, host)
	} else {
		k.kept[host] = entries
	}
	k.mu.Unlock()
	if key != "" {
		k.store.Delete(context.Background(), key)
	}
}

// changed tells each person what is kept for their own hosts.
func (k *Kept) changed() {
	if each, ok := k.router.(eachPerson); ok {
		each.BroadcastControlEach(NoticeKeptChanged, func(person string) any {
			return KeptList{Kept: k.For(person)}
		})
		return
	}
	k.router.BroadcastControl(NoticeKeptChanged, KeptList{Kept: k.All()})
}

// once is KeptRequests.once: the request with an id the host dedupes by, filled in when the
// client left it out, and without a draft runtime, which a stopped host cannot have.
func once(method string, params json.RawMessage) json.RawMessage {
	var object map[string]json.RawMessage
	if json.Unmarshal(params, &object) != nil || object == nil {
		return params
	}
	key := "sendID"
	if method == MethodAgentsStart {
		key = "requestID"
	}
	if raw, ok := object[key]; !ok || string(raw) == "null" {
		object[key] = rawOf(records.NewUUID())
	}
	if method == MethodAgentsStart {
		delete(object, "draftID")
	}
	return rawOf(object)
}

// summary is KeptRequests.summary.
func summary(r keptRecord) KeptRequest {
	var object map[string]any
	decodeJSON(r.Params, &object)
	start := r.Method == MethodAgentsStart
	out := KeptRequest{ID: wire.UUID(r.ID), Host: wire.MachineRef(r.Host), Kind: r.kind(), At: *dateOf(r.At.Time),
		Failed: optional(r.Failed)}
	if start {
		out.Text = strOr(object["prompt"])
		out.Folder = optional(wire.URL(strOr(object["cwd"])))
		out.RuntimeID = optional(strOr(object["runtimeID"]))
	} else {
		out.Text = strOr(object["text"])
		out.AgentID = optional(wire.UUID(uuidOf(strOr(object["agentID"]))))
	}
	return out
}

// sequence is KeptRequests.sequence: milliseconds since 1970, sixteen digits, so keys sort
// as they were kept.
func sequence(t time.Time) string { return fmt.Sprintf("%016d", t.UnixMilli()) }

func requireKeptID(params json.RawMessage) (KeptRequestID, error) {
	var which KeptRequestID
	if requireParams(params, &which, "KeptRequestID", "host", "id") != nil || !isUUID(string(which.ID)) {
		return which, invalid("Which kept request?")
	}
	which.ID = wire.UUID(strings.ToUpper(string(which.ID)))
	return which, nil
}
