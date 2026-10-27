package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
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
// it had (hosts/lastHeard).
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
// and agents/list asked lean with nothing narrowing it.
func keepsList(method string, params json.RawMessage) bool {
	switch method {
	case "folders/list":
		return true
	case "agents/list":
		var asked map[string]json.RawMessage
		if json.Unmarshal(params, &asked) != nil || asked == nil {
			return false
		}
		absent := func(k string) bool { v, ok := asked[k]; return !ok || string(v) == "null" }
		off := func(k string) bool { return absent(k) || string(asked[k]) == "false" }
		if string(asked["lean"]) != "true" || !off("includeArchived") || !off("archivedOnly") {
			return false
		}
		for _, k := range []string{"folder", "startedByWorkflow", "agentID", "after", "query"} {
			if !absent(k) {
				return false
			}
		}
		return true
	}
	return false
}

// take keeps a host's answer to a whole list. The store is written only when the list
// changed, or copyRestamp after it was last written (#2432): Live Now asks every machine
// again and again, and most answers are the same.
func (c *hostCopies) take(host, method, reply string) {
	var answer struct {
		Result json.RawMessage `json:"result"`
	}
	var items []json.RawMessage
	if json.Unmarshal([]byte(reply), &answer) != nil || json.Unmarshal(answer.Result, &items) != nil {
		return
	}
	ctx := context.Background()
	copy := c.current(ctx, host)
	next := hostCopy{}
	if copy != nil {
		next = *copy
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

// lastHeard is hosts/lastHeard: what the host last listed, and when; only its id when
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
