package agentsd

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
)

// The calls a client makes before its first list (#4891): how many round trips stand
// between a window, a Remote or a page connecting and its sessions showing. Each
// connection counts the calls it sends, in the order they come, until its first list,
// client/catchUp or agents/list of the live sessions, and says once in the log:
//
//	first list: mac after 3 calls: daemon/hello, presence/set, files/watch
//
// The night's run (scripts/perf-nightly.sh) reads the line for each client from a
// scratch host's log and holds it to `night.counts` in scripts/perf-budgets.json. No app
// has a test that runs its model against a fake host, so the host is where it is counted.

// firstListNames bounds the names one connection keeps: the count goes on past it.
const firstListNames = 32

type firstList struct {
	mu    sync.Mutex
	done  bool
	count int
	names []string
}

// isFirstList is whether a call is a list a client draws its sessions from.
func isFirstList(method string, params json.RawMessage) bool {
	switch method {
	case "client/catchUp":
		return true
	case "agents/list":
		var p struct {
			IncludeArchived bool `json:"includeArchived"`
		}
		_ = json.Unmarshal(params, &p)
		return !p.IncludeArchived
	}
	return false
}

// noteFirstList counts one call as it comes, and logs the count at the first list. It
// returns the line it logged, or "" (for a test).
func (d *Daemon) noteFirstList(c *Client, method string, params json.RawMessage) string {
	f := &c.firstList
	f.mu.Lock()
	if f.done {
		f.mu.Unlock()
		return ""
	}
	if !isFirstList(method, params) {
		f.count++
		if len(f.names) < firstListNames {
			f.names = append(f.names, method)
		}
		f.mu.Unlock()
		return ""
	}
	f.done = true
	count, names := f.count, f.names
	f.names = nil
	f.mu.Unlock()
	who := d.featureClient(c)
	if who == "" || who == featureAgent {
		return "" // a helper or an agent, not a client that draws a list
	}
	more := ""
	if count > len(names) {
		more = ", …"
	}
	line := fmt.Sprintf("first list: %s after %d calls: %s%s", who, count, strings.Join(names, ", "), more)
	log.Print(line)
	return line
}
