package agentsd

import (
	"context"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Runtime accounts and allowances, as the Swift host keeps them on a server: an account
// per runtime, in memory only (unknown until a runtime is started); each credential's
// allowance in <root>/allowances.json, shared sign-ins merged from the Mac by
// pool/applyAllowances (the newer change wins); runtimes/allowances the Pool page's rows,
// runtimes/allowancesChanged at most once a second.

type allowanceBook struct {
	allowMu      sync.Mutex
	allowLoaded  bool
	allowances   map[string]wire.AllowanceState
	accounts     map[string]wire.RuntimeAccount
	allowPending bool
	allowTold    time.Time
	allowStopped bool
}

func (d *Daemon) allowancesPath() string { return filepath.Join(d.Store.Loc.Root, "allowances.json") }

func (d *Daemon) allowancesLocked() map[string]wire.AllowanceState {
	if !d.allowLoaded {
		d.allowLoaded = true
		d.allowances = map[string]wire.AllowanceState{}
		var list []wire.AllowanceState
		readStore(d.allowancesPath(), &list, "starting with every runtime available")
		for _, s := range list {
			d.allowances[s.CredentialKey] = s
		}
	}
	return d.allowances
}

func (d *Daemon) saveAllowancesLocked() {
	list := []wire.AllowanceState{}
	for _, s := range d.allowances {
		list = append(list, s)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].CredentialKey < list[j].CredentialKey })
	writeStore(d.allowancesPath(), list)
}

// ownKey is a runtime's own credential: its sign-in.
func ownKey(runtime string) string {
	return runtime + ":sign-in"
}

func isSharedKey(k string) bool { return strings.HasSuffix(k, ":sign-in") }

func availableState(key string) wire.AllowanceState {
	t := now()
	return wire.AllowanceState{CredentialKey: key, EntryID: store.NewUUID(), Status: wire.AllowanceStateStatus{Available: &struct{}{}},
		Since: t, ChangedAt: t, LearnedFrom: wire.AllowanceStateSourcePerson, Spent: wire.AllowanceStateSpent{Known: &wire.AllowanceStateSpentKnown{}},
		RateLimitStreak: []wire.Date{}}
}

// accounts is runtimes/accounts: one per runtime, unknown until one has started.
func (d *Daemon) runtimeAccounts() []wire.RuntimeAccount {
	d.allowMu.Lock()
	defer d.allowMu.Unlock()
	out := []wire.RuntimeAccount{}
	for _, r := range catalog {
		a, ok := d.accounts[r.ID]
		if !ok {
			a = wire.RuntimeAccount{RuntimeID: r.ID, State: wire.RuntimeAccountStateUnknown, AuthMethods: []wire.ACPAuthMethod{},
				Providers: []wire.ACPProviderInfo{}, CheckedAt: now()}
		}
		out = append(out, a)
	}
	return out
}

// noteAccount is noteAccount: a handshake says the runtime is ready, and how it signs in.
func (d *Daemon) noteAccount(runtime string, canSteer bool, caps wire.ACPPromptCapabilities) {
	d.allowMu.Lock()
	if d.accounts == nil {
		d.accounts = map[string]wire.RuntimeAccount{}
	}
	a, ok := d.accounts[runtime]
	if !ok {
		a = wire.RuntimeAccount{RuntimeID: runtime, AuthMethods: []wire.ACPAuthMethod{}, Providers: []wire.ACPProviderInfo{}}
	}
	if a.State != wire.RuntimeAccountStateNeedsSignIn {
		a.State = wire.RuntimeAccountStateReady
	}
	a.CanSteer, a.PromptCapabilities, a.CheckedAt = canSteer, caps, now()
	d.accounts[runtime] = a
	d.allowMu.Unlock()
	Broadcast(d, wire.NotifyRuntimeAccount, a)
}

// unusable is why a runtime's own sign-in cannot be used now, or nil; installed is each
// runtime runtimeAllowances located once for all its rows (#2251).
func (d *Daemon) unusable(runtime string, installed map[string]bool) *string {
	rt := runtimeByID(runtime)
	if rt == nil {
		s := "not a runtime this app knows"
		return &s
	}
	if !installed[runtime] {
		s := "not installed"
		return &s
	}
	if d.needsSignIn(runtime) != nil {
		s := "not signed in"
		return &s
	}
	return nil
}

// runtimeAllowances is runtimes/allowances: a row each credential, by runtime name, each
// runtime's own sign-in first, then its added accounts in the order they were added
// (#840); the shared sign-ins.
func (d *Daemon) runtimeAllowances() wire.RuntimeAllowances {
	profiles := map[string]wire.AccountProfile{}
	added := map[string]int{}
	for i, p := range d.accountProfiles() {
		k := accountKey(p.RuntimeID, &p.ID)
		profiles[k], added[k] = p, i
	}
	d.allowMu.Lock()
	states := d.allowancesLocked()
	keys := map[string]bool{}
	installed := map[string]bool{}
	for i := range catalog {
		if p, _, _ := locateFor(&catalog[i]); p != "" {
			keys[ownKey(catalog[i].ID)] = true
			installed[catalog[i].ID] = true
		}
	}
	for k := range states {
		// A removed account's state is not a row.
		if keyAccount(k) == "" || profiles[k].ID != "" {
			keys[k] = true
		}
	}
	for k := range profiles {
		keys[k] = true
	}
	order := map[string]int{}
	for i, r := range catalog {
		order[r.ID] = i
	}
	var list []string
	for k := range keys {
		list = append(list, k)
	}
	runtimeOf := func(k string) string { r, _, _ := strings.Cut(k, ":"); return r }
	sort.Slice(list, func(i, j int) bool {
		ri, rj := runtimeOf(list[i]), runtimeOf(list[j])
		oi, ok1 := order[ri]
		oj, ok2 := order[rj]
		if !ok1 {
			oi = len(order)
		}
		if !ok2 {
			oj = len(order)
		}
		if oi != oj {
			return oi < oj
		}
		if (list[i] == ownKey(ri)) != (list[j] == ownKey(rj)) {
			return list[i] == ownKey(ri)
		}
		ai, ok1 := added[list[i]]
		aj, ok2 := added[list[j]]
		if ok1 && ok2 {
			return ai < aj
		}
		if ok1 != ok2 {
			return ok2
		}
		return list[i] < list[j]
	})
	out := wire.RuntimeAllowances{Rows: []wire.RuntimeAllowancesRow{}, At: now(), Shared: []wire.AllowanceState{}}
	for _, k := range list {
		s, ok := states[k]
		if !ok {
			s = availableState(k)
		}
		row := wire.RuntimeAllowancesRow{CredentialKey: k, State: s}
		if p, ok := profiles[k]; ok {
			row.AccountID, row.AccountName = &p.ID, &p.Name
		}
		out.Rows = append(out.Rows, row)
		if ok && isSharedKey(k) {
			out.Shared = append(out.Shared, s)
		}
	}
	d.allowMu.Unlock()
	for i := range out.Rows {
		rt := runtimeOf(out.Rows[i].CredentialKey)
		if p, ok := profiles[out.Rows[i].CredentialKey]; ok {
			out.Rows[i].Unusable = d.accountUnusable(p, installed)
			// An org account has no plan reading: its tokens today instead (#999, FR-025).
			if route := accountRoute(&p); route != "" {
				out.Rows[i].TokensToday = new(d.routeTokensToday(p.RuntimeID, route, time.Now()))
			}
			continue
		}
		out.Rows[i].Unusable = d.unusable(rt, installed)
		if rt == "claude" && out.Rows[i].CredentialKey == ownKey(rt) && out.Rows[i].Unusable == nil {
			out.Rows[i].SetupNote = chromeHostNote()
		}
	}
	sort.Slice(out.Shared, func(i, j int) bool { return out.Shared[i].CredentialKey < out.Shared[j].CredentialKey })
	return out
}

// tellAllowances is runtimes/allowancesChanged, at most once a second.
func (d *Daemon) tellAllowances() {
	d.allowMu.Lock()
	if d.allowPending {
		d.allowMu.Unlock()
		return
	}
	wait := time.Until(d.allowTold.Add(time.Second))
	d.allowPending = true
	d.allowMu.Unlock()
	safe.Go("allowances changed", func() {
		if wait > 0 {
			time.Sleep(wait)
		}
		d.allowMu.Lock()
		d.allowPending, d.allowTold = false, time.Now()
		stopped := d.allowStopped
		d.allowMu.Unlock()
		if stopped {
			return
		}
		Broadcast(d, wire.NotifyRuntimesAllowancesChanged, d.runtimeAllowances())
	})
}

// raiseAllowanceBack is cost.allowance_back for a credential, how it came back.
func (d *Daemon) raiseAllowanceBack(key, how string) {
	runtime, _, _ := strings.Cut(key, ":")
	details := map[string]string{"runtime": runtime, "how": how}
	if id := keyAccount(key); id != "" {
		details["account"] = id
	}
	d.raise(wire.EventDraft{Name: "cost.allowance_back", At: now(), Scope: macScope(), Sentence: d.credentialName(key) + "’s allowance came back.",
		Details: details})
}

func isOutState(s wire.AllowanceState) bool { return s.Status.Out != nil }

// markAvailable is runtimes/markAvailable: the person says it works again.
func (d *Daemon) markAvailable(key string) wire.RuntimeAllowances {
	d.allowMu.Lock()
	states := d.allowancesLocked()
	s, ok := states[key]
	changed := false
	if ok && s.Status.Available == nil {
		t := now()
		s.Status = wire.AllowanceStateStatus{Available: &struct{}{}}
		s.Since, s.ChangedAt, s.LearnedFrom = t, t, wire.AllowanceStateSourcePerson
		s.Spent = wire.AllowanceStateSpent{Known: &wire.AllowanceStateSpentKnown{}}
		states[key] = s
		d.saveAllowancesLocked()
		changed = true
	}
	d.allowMu.Unlock()
	if changed {
		d.raiseAllowanceBack(key, "person")
		d.allowanceBack(key)
		d.tellAllowances()
	}
	return d.runtimeAllowances()
}

// applyAllowances is pool/applyAllowances: the Mac's shared sign-ins, the newer change winning.
func (d *Daemon) applyAllowances(states []wire.AllowanceState) bool {
	d.allowMu.Lock()
	mine := d.allowancesLocked()
	changed := false
	for _, s := range states {
		if !isSharedKey(s.CredentialKey) {
			continue
		}
		had, ok := mine[s.CredentialKey]
		switch {
		case !ok || s.ChangedAt > had.ChangedAt:
			if ok && isOutState(had) && isOutState(s) && had.Since < s.Since {
				s.Since = had.Since
			}
			mine[s.CredentialKey], changed = s, true
		case s.Reading != nil && (had.Reading == nil || s.Reading.At > had.Reading.At):
			had.Reading = s.Reading
			mine[s.CredentialKey], changed = had, true
		}
	}
	if changed {
		d.saveAllowancesLocked()
	}
	d.allowMu.Unlock()
	if changed {
		d.tellAllowances()
	}
	return changed
}

func (d *Daemon) registerAllowances() {
	On(d, wire.CallRuntimesAccounts, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.RuntimeAccount, error) {
		return d.runtimeAccounts(), nil
	})
	On(d, wire.CallRuntimesAllowances, func(ctx context.Context, c *Client, _ *string) (wire.RuntimeAllowances, error) {
		return d.runtimeAllowances(), nil
	})
	On(d, wire.CallRuntimesMarkAvailable, func(ctx context.Context, c *Client, r wire.MarkRuntimeAvailable) (wire.RuntimeAllowances, error) {
		return d.markAvailable(r.CredentialKey), nil
	})
	On(d, wire.CallPoolApplyAllowances, func(ctx context.Context, c *Client, r wire.ApplyAllowancesRequest) (wire.Changed, error) {
		return wire.Changed(d.applyAllowances(r.States)), nil
	})
}
