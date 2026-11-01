package hosted

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Each account's control plane is held to its plan (#2224, spec 1003 FR-021), mostly
// from outside it, so the control plane stays mostly unchanged:
//
//   - its store (limitedStore) refuses a new machine or client over the plan's number, a
//     write that makes the store larger than the plan's storage, and a write that grows it
//     while the disk is past its high-water mark (disk.go);
//   - the proxy counts its open WebSockets (toAccount);
//   - the sweep deletes its events older than the plan keeps (sweepEvents);
//   - its agents running at once (agentsCap) go through the control plane's one hook for
//     it, Config.AgentsRunningGate (#2243, spec 1003 FR-022).
//
// A refusal is a *LimitError, whose words name the limit and the plan. The control plane
// passes a store error's words on as its answer's message. Nothing running is stopped.

// usageKey is where an account's bytes are kept between its copy's runs, in the service's
// own store, so a start does not read the whole store each time.
func usageKey(id string) string { return hostedPrefix + "v1/usage/" + id + ".json" }

// usage is an account's bytes, and when they were last counted from the store.
type usage struct {
	Bytes   int64     `json:"bytes"`
	Counted time.Time `json:"counted"`
}

// recountAfter is how old a kept count may be before a start counts again, so a count
// that drifted (a crash between a write and the keep) is put right within a day.
const recountAfter = 24 * time.Hour

// limitedStore is an account's store, held to its plan.
type limitedStore struct {
	store.Store
	account string
	// Told each refusal's limit, for the metrics; nil in tests.
	onRefuse func(limit string)
	// Whether the disk is past its high-water mark (#3121); nil in tests.
	diskFull func() bool

	mu    sync.Mutex
	plan  Plan
	bytes int64
	// The bytes as last kept, so the sweep writes only a change.
	kept int64
}

// The folders whose live records a plan counts.
var countedFolders = map[string]func(Plan) (int, string, string){
	records.MachinesPrefix: func(p Plan) (int, string, string) { return p.Machines, "machine", "machines" },
	records.ClientsPrefix:  func(p Plan) (int, string, string) { return p.Clients, "client", "clients" },
}

// agentsCap is a copy's gate on agents running at once, held to its plan (#2243, spec
// 1003 FR-022): the control plane asks it how many may run, each time it is asked how
// many run now. setPlan changes it as sweepAccounts rereads the account.
type agentsCap struct {
	account string

	mu   sync.Mutex
	plan Plan
}

func (a *agentsCap) setPlan(p Plan) {
	a.mu.Lock()
	a.plan = p
	a.mu.Unlock()
}

// gate refuses one more agent when as many already run as the plan allows. Nothing
// running is stopped (FR-022): a refusal only turns away the one that would start next.
func (a *agentsCap) gate(running int) error {
	a.mu.Lock()
	p := a.plan
	a.mu.Unlock()
	if p.AgentsRunning <= 0 || running < p.AgentsRunning {
		return nil
	}
	return &LimitError{Plan: p, Limit: "agents running at once",
		Allows: plural(p.AgentsRunning, "agent running at once", "agents running at once"),
		Do:     "Wait for one to finish", Account: a.account}
}

func (l *limitedStore) setPlan(p Plan) {
	l.mu.Lock()
	l.plan = p
	l.mu.Unlock()
}

func (l *limitedStore) planNow() Plan {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.plan
}

func (l *limitedStore) used() int64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.bytes
}

func (l *limitedStore) refuse(p Plan, limit, allows, do string) *LimitError {
	if l.onRefuse != nil {
		l.onRefuse(limit)
	}
	return &LimitError{Plan: p, Limit: limit, Allows: allows, Do: do, Account: l.account}
}

// Put refuses a new machine or client over the plan, and a write that grows the store past
// it. A rewrite that grows nothing is never refused.
func (l *limitedStore) Put(ctx context.Context, key string, data []byte, when store.Condition) (string, error) {
	old, err := l.Store.Get(ctx, key)
	if err != nil {
		return "", err
	}
	oldSize := 0
	if old != nil {
		oldSize = len(old.Data)
	}
	p := l.planNow()
	for folder, limit := range countedFolders {
		if !strings.HasPrefix(key, folder) || forgottenRecord(data) || old != nil && !forgottenRecord(old.Data) {
			continue
		}
		most, one, many := limit(p)
		n, err := l.live(ctx, folder)
		if err != nil {
			return "", err
		}
		if n >= most {
			return "", l.refuse(p, many, plural(most, one, many), "Remove one")
		}
	}
	grow := int64(len(data) - oldSize)
	l.mu.Lock()
	if grow > 0 && l.bytes+grow > p.Storage {
		l.mu.Unlock()
		return "", l.refuse(p, "storage", bytesText(p.Storage)+" of storage", "Delete something")
	}
	l.mu.Unlock()
	if grow > 0 && l.diskFull != nil && l.diskFull() {
		return "", l.refuse(p, limitDisk, "", "")
	}
	tag, err := l.Store.Put(ctx, key, data, when)
	if err == nil {
		l.mu.Lock()
		l.bytes += grow
		l.mu.Unlock()
	}
	return tag, err
}

// Delete deletes, and counts the bytes it frees.
func (l *limitedStore) Delete(ctx context.Context, key string) error {
	old, err := l.Store.Get(ctx, key)
	if err != nil {
		return err
	}
	if err := l.Store.Delete(ctx, key); err != nil {
		return err
	}
	if old != nil {
		l.mu.Lock()
		l.bytes -= int64(len(old.Data))
		if l.bytes < 0 {
			l.bytes = 0
		}
		l.mu.Unlock()
	}
	return nil
}

// live is how many records in a folder are not tombstones.
func (l *limitedStore) live(ctx context.Context, folder string) (int, error) {
	keys, err := l.Store.List(ctx, folder)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, k := range keys {
		o, err := l.Store.Get(ctx, k.Key)
		if err != nil {
			return 0, err
		}
		if o != nil && !forgottenRecord(o.Data) {
			n++
		}
	}
	return n, nil
}

// forgottenRecord says whether a record is a tombstone (records' "forgotten").
func forgottenRecord(data []byte) bool {
	var r struct {
		Forgotten bool `json:"forgotten"`
	}
	return json.Unmarshal(data, &r) == nil && r.Forgotten
}

// count counts the store's bytes from one listing (#3103): a start must not read the
// whole store on the request path. Only an object whose size the listing does not say
// is read.
func count(ctx context.Context, st store.Store) (int64, error) {
	keys, err := st.List(ctx, "")
	if err != nil {
		return 0, err
	}
	var n int64
	for _, k := range keys {
		if k.Size >= 0 {
			n += k.Size
			continue
		}
		o, err := st.Get(ctx, k.Key)
		if err != nil {
			return 0, err
		}
		if o != nil {
			n += int64(len(o.Data))
		}
	}
	return n, nil
}

// limitedFor is an account's store held to its plan, its bytes from the kept count, or
// counted again when there is none or it is old.
func (s *Service) limitedFor(ctx context.Context, acc *Account) (*limitedStore, error) {
	l := &limitedStore{Store: accountStore(s.cfg.Store, acc.ID), account: "https://" + s.cfg.Domain + "/account",
		plan: PlanOf(acc), onRefuse: s.metrics.refused, diskFull: s.disk.full}
	var u usage
	if o, err := s.cfg.Store.Get(ctx, usageKey(acc.ID)); err != nil {
		return nil, err
	} else if o != nil {
		_ = json.Unmarshal(o.Data, &u)
	}
	if u.Counted.IsZero() || s.cfg.Now().Sub(u.Counted) > recountAfter {
		n, err := count(ctx, l.Store)
		if err != nil {
			return nil, err
		}
		u = usage{Bytes: n, Counted: s.cfg.Now().UTC()}
		data, _ := json.Marshal(u)
		if _, err := s.cfg.Store.Put(ctx, usageKey(acc.ID), data, store.Always); err != nil {
			return nil, err
		}
	}
	l.bytes, l.kept = u.Bytes, u.Bytes
	return l, nil
}

// keepUsage writes an account's bytes when they changed since last kept.
func (s *Service) keepUsage(ctx context.Context, id string, l *limitedStore) {
	l.mu.Lock()
	n, kept := l.bytes, l.kept
	l.mu.Unlock()
	if n == kept {
		return
	}
	var u usage
	if o, err := s.cfg.Store.Get(ctx, usageKey(id)); err == nil && o != nil {
		_ = json.Unmarshal(o.Data, &u)
	}
	u.Bytes = n
	data, _ := json.Marshal(u)
	if _, err := s.cfg.Store.Put(ctx, usageKey(id), data, store.Always); err == nil {
		l.mu.Lock()
		l.kept = n
		l.mu.Unlock()
	}
}

// keptUsage is an account's bytes as last kept, for a copy not running.
func (s *Service) keptUsage(ctx context.Context, id string) int64 {
	var u usage
	if o, err := s.cfg.Store.Get(ctx, usageKey(id)); err == nil && o != nil {
		_ = json.Unmarshal(o.Data, &u)
	}
	return u.Bytes
}

// eventsFolder is where a control plane keeps its events, one folder a day
// (v1/events/2026-10-22/…), as its own sweep reads them.
const eventsFolder = "v1/events/"

// sweepEvents deletes an account's events from the days before its plan keeps.
func (s *Service) sweepEvents(ctx context.Context, l *limitedStore) (int, error) {
	keys, err := l.Store.List(ctx, eventsFolder)
	if err != nil {
		return 0, err
	}
	cutoff := s.cfg.Now().UTC().Add(-l.planNow().EventsKept).Format("2006-01-02")
	n := 0
	for _, k := range keys {
		day, _, ok := strings.Cut(strings.TrimPrefix(k.Key, eventsFolder), "/")
		if !ok || len(day) != len("2006-01-02") || day >= cutoff {
			continue
		}
		if err := l.Delete(ctx, k.Key); err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}

// isWebSocket says whether a request asks to become a WebSocket.
func isWebSocket(h interface{ Get(string) string }) bool {
	return strings.EqualFold(h.Get("Upgrade"), "websocket")
}

// Use is how much of each limit an account uses, for its page (FR-024).
type Use struct {
	Plan              Plan
	Machines, Clients int
	Storage           int64
}

// useOf reads an account's use: from its running copy's store, or the store and the kept
// size.
func (s *Service) useOf(ctx context.Context, acc *Account) (Use, error) {
	u := Use{Plan: PlanOf(acc)}
	s.mu.Lock()
	c := s.copies[acc.ID]
	s.mu.Unlock()
	l := &limitedStore{Store: accountStore(s.cfg.Store, acc.ID)}
	if c != nil && c.limits != nil {
		l = c.limits
		u.Storage = l.used()
	} else {
		u.Storage = s.keptUsage(ctx, acc.ID)
	}
	var err error
	if u.Machines, err = l.live(ctx, records.MachinesPrefix); err != nil {
		return u, err
	}
	u.Clients, err = l.live(ctx, records.ClientsPrefix)
	return u, err
}
