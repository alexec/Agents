package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// What the work costs, as the Swift host keeps it: <root>/spend.json (SpendLedger: each
// day's spend by currency and tokens, seven days, never a history), the person's limits in
// <settings>/limits.json (LimitStore, read again when it changes, failing closed when it
// cannot be read), and <root>/usage-history.json (UsageLedger: 168 hours and 90 days of
// cost and tokens per runtime, for the charts). A day is the host's own local day.

const (
	spendDaysKept  = 7
	usageHoursKept = 168
	usageDaysKept  = 90
	// limitsUnreadableWords is CostWords.limitsUnreadable.
	limitsUnreadableWords = "The spending limits could not be read, so nothing new starts until they are set again in Settings ▸ Cost. What was in the file is kept."
)

type spendFile struct {
	Days   map[string]map[string]float64 `json:"days"`
	Tokens map[string]int64              `json:"tokens,omitempty"`
}

type usageFile struct {
	Days  map[string]map[string]wire.UsageBucket `json:"days"`
	Hours map[string]map[string]wire.UsageBucket `json:"hours"`
	Now   string                                 `json:"now"`
}

type costBook struct {
	costMu       sync.Mutex
	spend        *spendFile
	spendNote    string
	usage        *usageFile
	limits       wire.CostLimits
	limitsStamp  string
	limitsBroken bool
	limitsNote   string
	// reader's running total of a session's cost, by currency (usage_update says a total)
	sessionCost map[wire.UUID]map[string]float64
	held        map[wire.UUID]bool // agents whose queue waits for a limit, told once
	lastSeenDay string
}

func dayStamp(t time.Time) string  { return t.Local().Format("2006-01-02") }
func hourStamp(t time.Time) string { return t.Local().Format("2006-01-02T15") }

// zoneName is the IANA name of the zone those stamps are in, sent with the histories so a
// viewer in another zone can put each hour in its own day (#1267): TZ when it names one,
// else what /etc/localtime links to, else UTC when the clock is UTC. Nil when none can be
// named, and a viewer reads the stamps as its own.
var zoneName = sync.OnceValue(func() *string { return namedZone(os.LookupEnv, os.Readlink, time.Now) })

func namedZone(env func(string) (string, bool), readlink func(string) (string, error), now func() time.Time) *string {
	fromPath := func(p string) string {
		if i := strings.LastIndex(p, "zoneinfo/"); i >= 0 {
			return p[i+len("zoneinfo/"):]
		}
		return ""
	}
	name := ""
	if tz, ok := env("TZ"); ok {
		tz = strings.TrimPrefix(tz, ":")
		switch {
		case tz == "":
			name = "UTC"
		case strings.HasPrefix(tz, "/"):
			name = fromPath(tz)
		default:
			if _, err := time.LoadLocation(tz); err == nil {
				name = tz
			}
		}
	} else if link, err := readlink("/etc/localtime"); err == nil {
		name = fromPath(link)
	}
	if name == "" {
		if _, offset := now().Zone(); offset == 0 {
			name = "UTC"
		}
	}
	if name == "" {
		return nil
	}
	return &name
}

func (d *Daemon) spendPath() string  { return filepath.Join(d.Store.Loc.Root, "spend.json") }
func (d *Daemon) usagePath() string  { return filepath.Join(d.Store.Loc.Root, "usage-history.json") }
func (d *Daemon) limitsPath() string { return filepath.Join(d.SettingsDir, "limits.json") }

// readStore is StoreFile.load: a file that cannot be read is set aside, and its absence
// is the empty value; it says what was set aside.
func readStore(path string, v any, meaning string) string {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ""
	}
	if err == nil && diskjson.Unmarshal(b, v) == nil {
		return ""
	}
	aside := fmt.Sprintf("%s.unreadable-%d", path, time.Now().Unix())
	os.Rename(path, aside)
	store.TrimSetAsides(path)
	log.Printf("%s: unreadable, %s; kept as %s", filepath.Base(path), meaning, filepath.Base(aside))
	return filepath.Base(path) + " could not be read, so it was set aside as " + filepath.Base(aside) + "."
}

func writeStore(path string, v any) error {
	b, err := diskjson.Marshal(v)
	if err != nil {
		return err
	}
	return store.WriteAtomically(path, b, 0o644)
}

// The spend ledger, under costMu.

func (d *Daemon) spendLocked() *spendFile {
	if d.spend == nil {
		d.spend = &spendFile{}
		d.spendNote = readStore(d.spendPath(), d.spend, "today's spend starts again from nothing")
		if d.spendNote != "" {
			d.spendNote += " Today's spend may be under-counted."
		}
		if d.spend.Days == nil {
			d.spend.Days = map[string]map[string]float64{}
		}
		if d.spend.Tokens == nil {
			d.spend.Tokens = map[string]int64{}
		}
	}
	return d.spend
}

// keepNewest is the newest n keys of a map, and the one being written.
func keepNewest[V any](m map[string]V, n int, keep string) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for i, k := range keys {
		if i < len(keys)-n && k != keep {
			delete(m, k)
		}
	}
}

func (d *Daemon) flushSpendLocked() {
	s := d.spendLocked()
	today := dayStamp(time.Now())
	keepNewest(s.Days, spendDaysKept, today)
	keepNewest(s.Tokens, spendDaysKept, today)
	if err := writeStore(d.spendPath(), s); err != nil {
		log.Printf("spend.json: could not save: %v", err)
	}
}

// The usage history, under costMu.

func (d *Daemon) usageLocked() *usageFile {
	if d.usage == nil {
		d.usage = &usageFile{}
		readStore(d.usagePath(), d.usage, "the usage charts start again")
		if d.usage.Days == nil {
			d.usage.Days = map[string]map[string]wire.UsageBucket{}
		}
		if d.usage.Hours == nil {
			d.usage.Hours = map[string]map[string]wire.UsageBucket{}
		}
	}
	return d.usage
}

func addBucket(m map[string]map[string]wire.UsageBucket, key, runtime string, add wire.UsageBucket) {
	if m[key] == nil {
		m[key] = map[string]wire.UsageBucket{}
	}
	b := m[key][runtime]
	if b.Cost == nil {
		b.Cost = map[string]float64{}
	}
	for c, v := range add.Cost {
		b.Cost[c] += v
	}
	b.InputTokens += add.InputTokens
	b.OutputTokens += add.OutputTokens
	b.ThoughtTokens += add.ThoughtTokens
	b.CachedReadTokens += add.CachedReadTokens
	b.CachedWriteTokens += add.CachedWriteTokens
	b.Turns += add.Turns
	b.UnpricedTurns += add.UnpricedTurns
	m[key][runtime] = b
}

func (d *Daemon) recordUsageLocked(runtime string, add wire.UsageBucket) {
	u := d.usageLocked()
	hour := hourStamp(time.Now())
	addBucket(u.Hours, hour, runtime, add)
	addBucket(u.Days, hour[:10], runtime, add)
	keepNewest(u.Hours, usageHoursKept, "")
	keepNewest(u.Days, usageDaysKept, "")
	u.Now = ""
	if err := writeStore(d.usagePath(), u); err != nil {
		log.Printf("usage-history.json: could not save: %v", err)
	}
}

// The limits, read again when the file changes.

func (d *Daemon) limitsLocked() wire.CostLimits {
	path := d.limitsPath()
	st, err := os.Stat(path)
	stamp := ""
	if err == nil {
		stamp = fmt.Sprintf("%d-%d", st.Size(), st.ModTime().UnixNano())
	}
	if stamp == d.limitsStamp && (d.limitsStamp != "" || d.limitsBroken || err != nil) {
		return d.limits
	}
	d.limitsStamp, d.limits, d.limitsBroken, d.limitsNote = stamp, wire.CostLimits{}, false, ""
	if err != nil {
		return d.limits
	}
	b, rerr := os.ReadFile(path)
	if rerr != nil || diskjson.Unmarshal(b, &d.limits) != nil {
		// Fails closed: nothing new starts until the limits are set again here.
		d.limits, d.limitsBroken = wire.CostLimits{}, true
		d.limitsNote = "limits.json could not be read. Nothing new starts until the limits are set again here."
	}
	return d.limits
}

// costStateLocked is currentCostState.
func (d *Daemon) costStateLocked() wire.CostState {
	limits := d.limitsLocked()
	s := d.spendLocked()
	today := dayStamp(time.Now())
	spent := map[string]float64{}
	for c, v := range s.Days[today] {
		spent[c] = v
	}
	st := wire.CostState{Limits: limits, Today: spent, Day: today, TokensToday: s.Tokens[today]}
	// The organisation's budgets over the person's own limits (#998, FR-016).
	if org := d.orgBudgets(d.orgPolicy()); org != nil {
		st.Organisation = org
		st.SetBy = setBy("budgets", budgetWords(*org))
	}
	var notes []string
	for _, n := range []string{d.limitsNote, d.spendNote} {
		if n != "" {
			notes = append(notes, n)
		}
	}
	if len(notes) > 0 {
		n := strings.Join(notes, " ")
		st.Note = &n
	}
	return st
}

func (d *Daemon) costState() wire.CostState {
	d.costMu.Lock()
	defer d.costMu.Unlock()
	return d.costStateLocked()
}

func (d *Daemon) tellCost() { Broadcast(d, wire.NotifyCostChanged, d.costState()) }

// bankSessionCost is DaemonCore.bank: a usage_update's cost is the session's running
// total, so what is new is what it rose by.
func (d *Daemon) bankSessionCost(id wire.UUID, c wire.Cost) {
	if c.Amount == 0 || c.Currency == "" {
		return
	}
	d.costMu.Lock()
	if d.sessionCost == nil {
		d.sessionCost = map[wire.UUID]map[string]float64{}
	}
	if d.sessionCost[id] == nil {
		d.sessionCost[id] = map[string]float64{}
	}
	prev := d.sessionCost[id][c.Currency]
	added := c.Amount
	if c.Amount >= prev {
		added = c.Amount - prev
	}
	d.sessionCost[id][c.Currency] = c.Amount
	if added <= 0 {
		d.costMu.Unlock()
		return
	}
	s := d.spendLocked()
	today := dayStamp(time.Now())
	if s.Days[today] == nil {
		s.Days[today] = map[string]float64{}
	}
	s.Days[today][c.Currency] += added
	d.flushSpendLocked()
	a := d.Store.Agent(id)
	runtime := ""
	if a != nil {
		runtime = a.RuntimeID
	}
	d.recordUsageLocked(runtime, wire.UsageBucket{Cost: map[string]float64{c.Currency: added}})
	d.addReport(a, runtime, time.Now(), wire.UsageRollupRow{Cost: map[string]float64{c.Currency: added}})
	d.costMu.Unlock()
	// On the work the session is on now (#2350).
	d.bankWork(a, wire.LineageCost{Cost: map[string]float64{c.Currency: added}})
	d.change(id, func(a *wire.Agent) {
		to := map[string]float64{}
		for k, v := range a.CostToDate {
			to[k] = v
		}
		to[c.Currency] += added
		a.CostToDate = to
	})
	d.tellCost()
}

// limitTokens is TurnUsage.limitTokens: fresh input and output, no cache reads or thoughts.
// On an org account it is the relay's count of the provider's answers (#999, FR-022).
func limitTokens(u wire.TurnUsage) int64 {
	if t := u.RelayTokens; t != nil {
		return max(0, t.Input+t.CacheWrite+t.Output)
	}
	read, write, thought := int64(0), int64(0), int64(0)
	if u.CachedReadTokens != nil {
		read = *u.CachedReadTokens
	}
	if u.CachedWriteTokens != nil {
		write = *u.CachedWriteTokens
	}
	if u.ThoughtTokens != nil {
		thought = *u.ThoughtTokens
	}
	fresh := u.InputTokens + write
	if read > 0 && read <= u.InputTokens && (u.TotalTokens == u.InputTokens+u.OutputTokens || u.TotalTokens == u.InputTokens+u.OutputTokens+thought) {
		fresh = u.InputTokens - read
	}
	return max(0, fresh+u.OutputTokens)
}

// bankTurnUsage is finishTurn's banking: the turn's tokens on the agent, the day and the
// charts.
func (d *Daemon) bankTurnUsage(id wire.UUID, u wire.TurnUsage) {
	a := d.Store.Agent(id)
	if a == nil {
		return
	}
	priced := !(len(a.CostToDate) == 0 && u.Cost == nil && (a.Usage == nil || a.Usage.Cost == nil))
	counted := limitTokens(u)
	d.costMu.Lock()
	if counted > 0 {
		s := d.spendLocked()
		s.Tokens[dayStamp(time.Now())] += counted
		d.flushSpendLocked()
	}
	b := wire.UsageBucket{Cost: map[string]float64{}, InputTokens: u.InputTokens, OutputTokens: u.OutputTokens, Turns: 1}
	if u.ThoughtTokens != nil {
		b.ThoughtTokens = *u.ThoughtTokens
	}
	if u.CachedReadTokens != nil {
		b.CachedReadTokens = *u.CachedReadTokens
	}
	if u.CachedWriteTokens != nil {
		b.CachedWriteTokens = *u.CachedWriteTokens
	}
	if !priced {
		b.UnpricedTurns = 1
	}
	d.recordUsageLocked(a.RuntimeID, b)
	d.addReport(a, a.RuntimeID, time.Now(), wire.UsageRollupRow{Route: u.Route, Cost: b.Cost, InputTokens: b.InputTokens,
		OutputTokens: b.OutputTokens, ThoughtTokens: b.ThoughtTokens, CachedReadTokens: b.CachedReadTokens,
		CachedWriteTokens: b.CachedWriteTokens, Turns: b.Turns, UnpricedTurns: b.UnpricedTurns, LimitTokens: &counted})
	d.costMu.Unlock()
	d.bankWork(a, wire.LineageCost{Cost: map[string]float64{}, InputTokens: b.InputTokens, OutputTokens: b.OutputTokens,
		LimitTokens: &counted, Turns: 1})
	d.change(id, func(a *wire.Agent) {
		a.LastTurnUsage = &u
		if counted > 0 {
			n := counted
			if a.TokensToDate != nil {
				n += *a.TokensToDate
			}
			a.TokensToDate = &n
		}
	})
	if counted > 0 {
		d.tellCost()
		// An org account's row says its tokens today (#999, FR-025).
		if reportRoute(a) != "" {
			d.tellAllowances()
		}
	}
}

// usageHistory is usage/history: bounded, and saying the host's hour.
func (d *Daemon) usageHistory() wire.UsageHistory {
	d.costMu.Lock()
	defer d.costMu.Unlock()
	u := d.usageLocked()
	keepNewest(u.Hours, usageHoursKept, "")
	keepNewest(u.Days, usageDaysKept, "")
	h := wire.UsageHistory{Hours: map[string]map[string]wire.UsageBucket{}, Days: map[string]map[string]wire.UsageBucket{}, Now: hourStamp(time.Now()), TimeZone: zoneName()}
	for k, v := range u.Hours {
		h.Hours[k] = v
	}
	for k, v := range u.Days {
		h.Days[k] = v
	}
	return h
}

// setLimits is cost/setLimits: a key absent leaves its limit; null takes it away; zero is
// a limit.
func (d *Daemon) setLimits(raw json.RawMessage) (wire.CostState, error) {
	var keys map[string]json.RawMessage
	if len(raw) > 0 && json.Unmarshal(raw, &keys) != nil {
		return wire.CostState{}, Invalid("cost/setLimits: the limits are not an object")
	}
	d.costMu.Lock()
	limits := d.limitsLocked()
	if d.limitsBroken {
		limits = wire.CostLimits{}
	}
	var err error
	cost := func(k string, to **wire.Cost) {
		v, ok := keys[k]
		if !ok || err != nil {
			return
		}
		if string(v) == "null" {
			*to = nil
			return
		}
		var c wire.Cost
		if e := json.Unmarshal(v, &c); e != nil {
			err = Invalid("cost/setLimits: %s: %v", k, e)
			return
		}
		*to = &c
	}
	count := func(k string, to **int64) {
		v, ok := keys[k]
		if !ok || err != nil {
			return
		}
		if string(v) == "null" {
			*to = nil
			return
		}
		var n int64
		if e := json.Unmarshal(v, &n); e != nil {
			err = Invalid("cost/setLimits: %s: %v", k, e)
			return
		}
		*to = &n
	}
	cost("perAgent", &limits.PerAgent)
	cost("daily", &limits.Daily)
	count("perAgentTokens", &limits.PerAgentTokens)
	count("dailyTokens", &limits.DailyTokens)
	if err != nil {
		d.costMu.Unlock()
		return wire.CostState{}, err
	}
	os.MkdirAll(d.SettingsDir, 0o755)
	if werr := writeStore(d.limitsPath(), limits); werr != nil {
		d.costMu.Unlock()
		return wire.CostState{}, &Error{Code: wire.FailureCouldNotSave, Message: "The spending limit could not be saved: " + werr.Error()}
	}
	d.limitsStamp = "" // read again, as written
	st := d.costStateLocked()
	d.costMu.Unlock()
	Broadcast(d, wire.NotifyCostChanged, st)
	// A limit raised lets what waited go now.
	d.drainHeld()
	return st, nil
}

func (d *Daemon) registerCost() {
	On(d, wire.CallCostState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.CostState, error) { return d.costState(), nil })
	d.handlers[wire.CallCostSetLimits.Name] = func(ctx context.Context, c *Client, raw json.RawMessage) (any, error) {
		return d.setLimits(raw)
	}
	On(d, wire.CallUsageHistory, func(ctx context.Context, c *Client, _ wire.Empty) (wire.UsageHistory, error) {
		return d.usageHistory(), nil
	})
	On(d, wire.CallTimeHistory, func(ctx context.Context, c *Client, _ wire.Empty) (wire.TimeHistory, error) {
		return d.timeHistory(), nil
	})
	On(d, wire.CallMilestonesState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.Milestones, error) {
		return d.milestones(), nil
	})
}
