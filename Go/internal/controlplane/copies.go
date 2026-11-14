package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// agentsKept is HostCopies.agentsKept: the most agents kept of a host's list.
const agentsKept = 500

const copiesPrefix = "v1/copies/"

// copyRestamp is how often a list that has not changed is written again, only so the
// stored heardAt is not older than this after a restart (#2432). A changed list is
// written at once.
const copyRestamp = 10 * time.Minute

// hostCopies is HostCopies: what each host last listed (#962), its folders and its
// agents, kept in the store, so a window that starts while the host is offline sees what
// it had (machines/lastHeard).
type hostCopies struct {
	store store.Store
	mu    sync.Mutex
	held  map[string]*hostCopy
	read  map[string]bool
	// written is when each host's copy was last put in the store (#2432).
	written map[string]time.Time
}

type hostCopy struct {
	Folders json.RawMessage `json:"folders,omitempty"`
	Agents  json.RawMessage `json:"agents,omitempty"`
	HeardAt records.Stamp   `json:"heardAt"`
}

func newHostCopies(s store.Store) *hostCopies {
	return &hostCopies{store: s, held: map[string]*hostCopy{}, read: map[string]bool{}, written: map[string]time.Time{}}
}

func copyKey(host string) string { return copiesPrefix + host + ".json" }

// keepsList is HostCopies.keeps: only the whole lists a window opens with, folders/list,
// agents/list asked lean with nothing narrowing it, and client/catchUp's live agents, whole
// or what changed since (#4794), which take lays on the list kept.
func keepsList(method string, params json.RawMessage) bool {
	switch method {
	case "folders/list":
		return true
	case "agents/list":
		return wholeLeanList(params, false)
	case wire.CallClientCatchUp.Name:
		var asked struct {
			Agents json.RawMessage `json:"agents"`
		}
		if json.Unmarshal(params, &asked) != nil {
			return false
		}
		// None asked is the first page: live and lean.
		return len(asked.Agents) == 0 || string(asked.Agents) == "null" || wholeLeanList(asked.Agents, true)
	}
	return false
}

// wholeLeanList is a lean list of the live agents with nothing narrowing it; with changes,
// one asked only for what changed since a point (#4794) is one too.
func wholeLeanList(params json.RawMessage, changes bool) bool {
	var asked map[string]json.RawMessage
	if json.Unmarshal(params, &asked) != nil || asked == nil {
		return false
	}
	absent := func(k string) bool { v, ok := asked[k]; return !ok || string(v) == "null" }
	off := func(k string) bool { return absent(k) || string(asked[k]) == "false" }
	if string(asked["lean"]) != "true" || !off("includeArchived") || !off("archivedOnly") {
		return false
	}
	narrowing := []string{"folder", "startedByWorkflow", "agentID", "after", "query"}
	if !changes {
		narrowing = append(narrowing, "changedSince")
	}
	for _, k := range narrowing {
		if !absent(k) {
			return false
		}
	}
	return true
}

// caughtUp is the agents of a client/catchUp's answer as the list to keep (#4794): the
// whole live list, or what changed laid on the one held. False when it is not one.
func caughtUp(result json.RawMessage, held json.RawMessage) ([]json.RawMessage, bool) {
	var snapshot struct {
		Agents  []json.RawMessage `json:"agents"`
		Changes *struct {
			Removed []string `json:"removed"`
			All     bool     `json:"all"`
		} `json:"agentChanges"`
	}
	if json.Unmarshal(result, &snapshot) != nil || snapshot.Agents == nil {
		return nil, false
	}
	if snapshot.Changes == nil || snapshot.Changes.All {
		return snapshot.Agents, true
	}
	// Changes on nothing held are not the list.
	var kept []json.RawMessage
	if len(held) == 0 || json.Unmarshal(held, &kept) != nil {
		return nil, false
	}
	type record struct {
		ID    string `json:"id"`
		State string `json:"state"`
	}
	idOf := func(raw json.RawMessage) record {
		var r record
		_ = json.Unmarshal(raw, &r)
		r.ID = strings.ToUpper(r.ID)
		return r
	}
	drop := map[string]bool{}
	for _, id := range snapshot.Changes.Removed {
		drop[strings.ToUpper(id)] = true
	}
	// The changed ones first, newest activity first as the host lists them; an archived one
	// leaves the live list.
	out := []json.RawMessage{}
	for _, raw := range snapshot.Agents {
		r := idOf(raw)
		drop[r.ID] = true
		if r.State != string(wire.AgentStateArchived) {
			out = append(out, raw)
		}
	}
	for _, raw := range kept {
		if !drop[idOf(raw).ID] {
			out = append(out, raw)
		}
	}
	return out, true
}

// take keeps a host's answer to a whole list. The store is written only when the list
// changed, or copyRestamp after it was last written (#2432): Live Now asks every machine
// again and again, and most answers are the same.
func (c *hostCopies) take(host, method, reply string) {
	var answer struct {
		Result json.RawMessage `json:"result"`
	}
	if json.Unmarshal([]byte(reply), &answer) != nil {
		return
	}
	ctx := context.Background()
	copy := c.current(ctx, host)
	next := hostCopy{}
	if copy != nil {
		next = *copy
	}
	var items []json.RawMessage
	if method == wire.CallClientCatchUp.Name {
		listed, ok := caughtUp(answer.Result, next.Agents)
		if !ok {
			return
		}
		items = listed
	} else if json.Unmarshal(answer.Result, &items) != nil {
		return
	}
	same := false
	if method == "folders/list" {
		same = copy != nil && bytes.Equal(next.Folders, answer.Result)
		next.Folders = answer.Result
	} else {
		if len(items) > agentsKept {
			items = items[:agentsKept]
		}
		agents, _ := json.Marshal(items)
		same = copy != nil && bytes.Equal(next.Agents, agents)
		next.Agents = agents
	}
	next.HeardAt = records.Now()
	c.mu.Lock()
	c.held[host] = &next
	written, ok := c.written[host]
	due := !same || !ok || next.HeardAt.Sub(written) >= copyRestamp
	if due {
		c.written[host] = next.HeardAt.Time
	}
	c.mu.Unlock()
	if !due {
		return
	}
	if data, err := records.Encode(next); err == nil {
		c.store.Put(ctx, copyKey(host), data, store.Always)
	}
}

// lastHeard is machines/lastHeard: what the host last listed, and when; only its id when
// nothing is kept.
func (c *hostCopies) lastHeard(host string) map[string]any {
	said := map[string]any{"host": host}
	copy := c.current(context.Background(), host)
	if copy == nil {
		return said
	}
	if copy.Folders != nil {
		said["folders"] = copy.Folders
	}
	if copy.Agents != nil {
		said["agents"] = copy.Agents
	}
	said["heardAt"] = dateOf(copy.HeardAt.Time)
	return said
}

// forget lets a removed host's lists go.
func (c *hostCopies) forget(host string) {
	c.mu.Lock()
	delete(c.held, host)
	delete(c.written, host)
	c.read[host] = true
	c.mu.Unlock()
	c.store.Delete(context.Background(), copyKey(host))
}

func (c *hostCopies) current(ctx context.Context, host string) *hostCopy {
	c.mu.Lock()
	if c.read[host] {
		defer c.mu.Unlock()
		return c.held[host]
	}
	c.read[host] = true
	c.mu.Unlock()
	if object, err := c.store.Get(ctx, copyKey(host)); err == nil && object != nil {
		var stored hostCopy
		if json.Unmarshal(object.Data, &stored) == nil {
			c.mu.Lock()
			if c.held[host] == nil {
				c.held[host] = &stored
			}
			c.mu.Unlock()
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.held[host]
}
