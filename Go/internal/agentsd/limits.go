package agentsd

import (
	"errors"
	"log"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

// What a turn's ending says about the runtime's allowance (052, LimitRecognition), in
// three layers: the runtime's own typed failure in _meta, then words that have been seen,
// then nothing. Spent, credit gone and paid overage take it out of the pool, tried again
// after four hours, and the agent stops saying so; a rate limit sends the same prompt
// again after 30 s, then 2 min, and three in ten minutes take the runtime out.

type limitKind int

const (
	limitNone limitKind = iota
	limitSpent
	limitCreditGone
	limitRateLimited
	limitOverage
	// limitOtherTyped is a typed failure of another kind: said, never switched on.
	limitOtherTyped
)

// limit is a recognition: its kind, and when the runtime said the allowance comes back.
type limit struct {
	kind     limitKind
	resetsAt *wire.Date
}

// sessionFailure is a failure a runtime reported in a shape (SessionFailure): JetBrains'
// AIR extension, which Claude's and Codex's adapters speak to a client that asks for it.
// A refused turn then ends end_turn with this under _meta.jetbrains.air.sessionFailure,
// on the prompt's answer or on a session_info_update.
type sessionFailure struct {
	ID, Category, Severity, Title, Details, Reason string
	Revision                                       int
	Actions                                        []string
}

// isError is anything but a warning, which is a retry in progress and changes nothing.
func (f *sessionFailure) isError() bool { return f.Severity != "warning" }

// failureIn is the failure in a _meta; a shape not understood is no failure.
func failureIn(meta map[string]any) *sessionFailure {
	jb, _ := meta["jetbrains"].(map[string]any)
	air, _ := jb["air"].(map[string]any)
	m, _ := air["sessionFailure"].(map[string]any)
	str := func(k string) string { s, _ := m[k].(string); return s }
	f := &sessionFailure{ID: str("id"), Category: str("category"), Severity: str("severity"), Title: str("title"),
		Details: str("details"), Reason: str("reason"), Revision: 1}
	if f.ID == "" || f.Category == "" || f.Title == "" {
		return nil
	}
	if f.Severity == "" {
		f.Severity = "error"
	}
	if n, ok := m["revision"].(float64); ok {
		f.Revision = int(n)
	}
	as, _ := m["actions"].([]any)
	for _, a := range as {
		if s, ok := a.(string); ok {
			f.Actions = append(f.Actions, s)
		}
	}
	return f
}

// supersededBy is the later of two reports of the same failure; a different one replaces it.
func (f *sessionFailure) supersededBy(o *sessionFailure) *sessionFailure {
	if f == nil || o == nil {
		if o != nil {
			return o
		}
		return f
	}
	if o.ID != f.ID || o.Revision >= f.Revision {
		return o
	}
	return f
}

// rateLimitIn is Claude's plan window on a usage_update, _meta["_claude/rateLimit"]
// (RateLimitInfo): the one place the app hears when an allowance comes back, and whether
// paid extra usage has begun.
func rateLimitIn(meta map[string]any) *wire.RateLimitInfo {
	m, ok := meta["_claude/rateLimit"].(map[string]any)
	if !ok {
		return nil
	}
	str := func(k string) *string {
		if s, ok := m[k].(string); ok {
			return &s
		}
		return nil
	}
	num := func(k string) *float64 {
		if n, ok := m[k].(float64); ok {
			return &n
		}
		return nil
	}
	secs := func(k string) *wire.Date {
		if n := num(k); n != nil {
			d := wire.DateOf(time.Unix(0, int64(*n*1e9)))
			return &d
		}
		return nil
	}
	flag := func(k string) *bool {
		if b, ok := m[k].(bool); ok {
			return &b
		}
		return nil
	}
	return &wire.RateLimitInfo{Status: str("status"), ResetsAt: secs("resetsAt"), RateLimitType: str("rateLimitType"),
		Utilization: num("utilization"), OverageStatus: str("overageStatus"), OverageResetsAt: secs("overageResetsAt"),
		IsUsingOverage: flag("isUsingOverage"), OverageInUse: flag("overageInUse"), OverageDisabledReason: str("overageDisabledReason")}
}

func rateLimitRejected(r *wire.RateLimitInfo) bool {
	return r != nil && r.Status != nil && *r.Status == "rejected"
}

// payingOverage is whether the account has started paying beyond its plan.
func payingOverage(r *wire.RateLimitInfo) bool {
	return r != nil && ((r.IsUsingOverage != nil && *r.IsUsingOverage) || (r.OverageInUse != nil && *r.OverageInUse))
}

// rateLimitPolicy is RateLimitPolicy.standard: the waits before the first and later
// retries, and three refusals of one chat within ten minutes make the limit persisted.
var rateLimitPolicy = struct {
	delays        []time.Duration
	window        time.Duration
	persistsAfter int
}{[]time.Duration{30 * time.Second, 2 * time.Minute}, 10 * time.Minute, 3}

var claudeUsageLimitPrefixes = []string{
	"You've hit your", "You've reached your", "You're out of usage credits",
	"Your org is out of usage · add funds to continue", "Your org is out of usage · contact your admin",
	"Your seat type doesn't include usage credits", "Your seat type doesn't include usage",
	"Your usage allocation has been disabled by your admin", "Your group's usage limit is set to $0",
	"Fable 5 requires usage credits", "You're out of extra usage", "Your seat type doesn't include extra usage",
}

const retryWithoutATime = 4 * time.Hour

// classifyLimit is LimitRecognition.classify: the runtime's typed failure, its latest
// plan window, a refusal's code and message, and the turn's own words where a runtime
// says a refusal there.
func classifyLimit(runtimeID string, failure *sessionFailure, window *wire.RateLimitInfo, code *int, message, said string) limit {
	var resets *wire.Date
	if rateLimitRejected(window) {
		resets = window.ResetsAt
	}
	spent := limit{limitSpent, resets}
	// Layer 1: the runtime's own classification.
	if failure != nil && failure.isError() {
		switch {
		case failure.Category != "limit":
			return limit{kind: limitOtherTyped}
		case len(failure.Actions) == 0:
			return spent
		case slices.Contains(failure.Actions, "retry"):
			return limit{kind: limitRateLimited}
		}
		return limit{kind: limitOtherTyped}
	}
	// Paid use has begun on a plan: out, whatever the turn itself did (R3).
	if payingOverage(window) {
		at := window.OverageResetsAt
		if at == nil {
			at = window.ResetsAt
		}
		return limit{limitOverage, at}
	}
	// Layer 2: words that have been seen.
	return limit{wordsLimit(runtimeID, code, message, said), nil}.resetting(resets)
}

func (l limit) resetting(at *wire.Date) limit {
	if l.kind == limitSpent {
		l.resetsAt = at
	}
	return l
}

// wordsLimit is the words layer: a refusal's code and message, and the turn's own words.
func wordsLimit(runtimeID string, code *int, message, said string) limitKind {
	saids := []string{}
	if code != nil {
		saids = append(saids, message)
	}
	if said != "" {
		saids = append(saids, said)
	}
	says := func(f func(string) bool) bool { return slices.ContainsFunc(saids, f) }
	switch runtimeID {
	case "copilot":
		const q = "You have exceeded your monthly quota"
		if says(func(s string) bool { return strings.HasPrefix(s, q) || strings.HasPrefix(s, "Error: "+q) }) {
			return limitSpent
		}
	case "cursor":
		if says(func(s string) bool { return strings.HasPrefix(s, "Upgrade your plan to continue") }) {
			return limitSpent
		}
	case "antigravity":
		if says(func(s string) bool {
			t := strings.TrimSpace(s)
			return strings.HasPrefix(t, "Usage Limit Reached") || strings.HasPrefix(t, "You have reached your current quota")
		}) {
			return limitSpent
		}
	case "grok":
		if says(func(s string) bool { return strings.Contains(strings.ToLower(s), "usage balance exhausted") }) {
			return limitSpent
		}
	}
	if code != nil {
		lower := strings.ToLower(message)
		switch {
		case strings.Contains(lower, "insufficient_quota") || strings.Contains(lower, "credit balance is too low"):
			return limitCreditGone
		case runtimeID == "claude" && slices.ContainsFunc(claudeUsageLimitPrefixes, func(p string) bool {
			return strings.HasPrefix(message, p) || strings.Contains(message, ": "+p)
		}):
			return limitSpent
		case strings.Contains(lower, "exhausted your daily quota"):
			return limitSpent
		case *code == 429 || strings.Contains(lower, "rate limit") || strings.Contains(lower, "resource_exhausted"):
			return limitRateLimited
		}
	}
	// Antigravity's 429: Google says the same for a rate limit and a spent quota, so it is
	// a rate limit until it keeps coming.
	if l := strings.ToLower(said); strings.Contains(l, "resource has been exhausted") || strings.Contains(l, "check quota") {
		return limitRateLimited
	}
	return limitNone
}

// authRequired is ACP's auth_required (JSONRPCError.authRequired): the runtime has no
// sign-in to use.
const authRequired = -32000

// refusal is a prompt's error as a code and message, when the runtime refused it.
func refusal(err error) (*int, string) {
	var re *sdk.RequestError
	if errors.As(err, &re) {
		code := re.Code
		msg := re.Message
		if s, ok := re.Data.(string); ok && s != "" {
			msg += ": " + s
		} else if m, ok := re.Data.(map[string]any); ok {
			for _, k := range []string{"message", "error", "details"} {
				if s, ok := m[k].(string); ok && s != "" {
					msg += ": " + s
				}
			}
		}
		return &code, msg
	}
	return nil, ""
}

// poolTime is PoolWords.time on a server: the time today, else the day and the time.
func poolTime(t, now time.Time) string {
	t, now = t.Local(), now.Local()
	if t.YearDay() == now.YearDay() && t.Year() == now.Year() {
		return t.Format("15:04")
	}
	if t.Sub(now) < 6*24*time.Hour {
		return t.Format("Mon 15:04")
	}
	return t.Format("2 Jan")
}

// noteFailure is a typed failure's own sentence in the conversation (052). The details
// are for whoever debugs the runtime: logged, never shown.
func (d *Daemon) noteFailure(id wire.UUID, runtimeID string, f *sessionFailure) {
	d.record(id, runtimeNote(runtimeName(runtimeID)+": "+f.Title))
	log.Printf("agent %s: %s %s %v %s %s", id, f.Severity, f.Category, f.Actions, f.Reason, f.Details)
}

// markOut is AllowanceState.markOut on a credential (the agent's account, #840): out since
// it went out, back when the provider said, tried again after four hours either way.
func (d *Daemon) markOut(key string, why wire.AllowanceStateOutReason, until *wire.Date, source wire.AllowanceStateSource,
	window *wire.RateLimitInfo) wire.AllowanceState {
	at := time.Now()
	retry := wire.DateOf(at.Add(retryWithoutATime))
	d.allowMu.Lock()
	defer d.allowMu.Unlock()
	states := d.allowancesLocked()
	s, ok := states[key]
	if !ok {
		s = availableState(key)
	}
	t := wire.DateOf(at)
	// Out since the moment it went out: marked again while out, only the stamp moves.
	if s.Status.Out == nil {
		s.Since = t
	}
	s.Status = wire.AllowanceStateStatus{Out: &wire.AllowanceStateStatusOut{Until: until, RetryAfter: &retry, Why: why}}
	s.ChangedAt, s.LearnedFrom, s.RateLimitStreak = t, source, []wire.Date{}
	if window != nil {
		s.LastRateLimit = window
	}
	states[key] = s
	d.saveAllowancesLocked()
	return s
}

func (d *Daemon) raiseAllowanceOut(key, reason string, s wire.AllowanceState) {
	runtimeID, _, _ := strings.Cut(key, ":")
	details := map[string]string{"runtime": runtimeID, "reason": reason}
	if id := keyAccount(key); id != "" {
		details["account"] = id
	}
	if o := s.Status.Out; o != nil && o.RetryAfter != nil {
		details["retry_after"] = o.RetryAfter.Time().UTC().Format(time.RFC3339)
	}
	if o := s.Status.Out; o != nil && o.Until != nil {
		details["until"] = o.Until.Time().UTC().Format(time.RFC3339)
	}
	log.Printf("%s's %s", key, reason)
	d.raise(wire.EventDraft{Name: "cost.allowance_out", At: now(), Scope: macScope(), Sentence: d.credentialName(key) + "’s allowance ran out.",
		Details: details})
	d.tellAllowances()
}

// applyLimit is applyRecognition: say the limit on the chat, mark the runtime, and give
// the reason its turn ends with; stops is false for nothing recognised, and for paid
// overage beginning on a turn that worked, which stays worked. retryAt is when the same
// prompt goes again, for a rate limit being retried.
func (d *Daemon) applyLimit(l *live, lim limit, worked bool) (why wire.EndedReason, stops bool, retryAt time.Time) {
	a := d.Store.Agent(l.id)
	if a == nil {
		return "", false, time.Time{}
	}
	key := agentKey(a)
	name := d.credentialName(key)
	l.mu.Lock()
	window := l.rateLimit
	l.mu.Unlock()
	at := time.Now()
	switch lim.kind {
	case limitSpent:
		s := d.markOut(key, wire.AllowanceStateOutReasonAllowanceSpent, lim.resetsAt, wire.AllowanceStateSourceTypedFailure, window)
		d.raiseAllowanceOut(key, "allowance spent", s)
		note := name + "’s allowance ran out. It is tried again after " + poolTime(s.Status.Out.RetryAfter.Time(), at) + "."
		if lim.resetsAt != nil {
			note = name + "’s allowance ran out. Its provider says it resets at " + poolTime(lim.resetsAt.Time(), at) + "; the app checks before using it again."
		}
		d.record(l.id, runtimeNote(note))
		// The wait's own turn refused again: it waits again, for the next time (#1859).
		l.mu.Lock()
		sent := l.lastSent
		l.mu.Unlock()
		// So does a workflow's run or a helper set to (#1918): nobody watches those.
		if sentToContinue(sent) || d.continuesByItself(a) {
			d.waitForAllowance(l.id, key)
		}
		return wire.EndedReasonAllowanceSpent, true, time.Time{}
	case limitCreditGone:
		s := d.markOut(key, wire.AllowanceStateOutReasonCreditUsedUp, nil, wire.AllowanceStateSourceWords, nil)
		d.raiseAllowanceOut(key, "credit used up", s)
		d.record(l.id, runtimeNote(name+"’s credit is used up."))
		return wire.EndedReasonAllowanceSpent, true, time.Time{}
	case limitOverage:
		s := d.markOut(key, wire.AllowanceStateOutReasonOverage, lim.resetsAt, wire.AllowanceStateSourceOverageReport, nil)
		d.raiseAllowanceOut(key, "paid extra usage began", s)
		d.record(l.id, runtimeNote(name+" started using paid extra usage, so it is treated as out."))
		// The turn itself may have worked; then it stays worked.
		return wire.EndedReasonAllowanceSpent, !worked, time.Time{}
	case limitRateLimited:
		l.mu.Lock()
		attempt := l.rateLimitAttempts
		streak := []time.Time{}
		for _, t := range l.rateLimitStreak {
			if at.Sub(t) < rateLimitPolicy.window {
				streak = append(streak, t)
			}
		}
		streak = append(streak, at)
		persists := len(streak) >= rateLimitPolicy.persistsAfter
		sent := l.lastSent
		if persists {
			l.rateLimitStreak, l.rateLimitAttempts = nil, 0
		} else {
			l.rateLimitStreak = streak
			if sent != nil {
				l.rateLimitAttempts++
			}
		}
		l.mu.Unlock()
		if persists {
			s := d.markOut(key, wire.AllowanceStateOutReasonRateLimitPersisted, nil, wire.AllowanceStateSourceTypedFailure, nil)
			d.raiseAllowanceOut(key, "still rate limited", s)
			d.record(l.id, runtimeNote(name+" is still rate limited after retrying, so it is treated as out for an hour."))
			return wire.EndedReasonRateLimited, true, time.Time{}
		}
		retryAt = at.Add(rateLimitPolicy.delays[min(attempt, len(rateLimitPolicy.delays)-1)])
		d.rateLimited(key, wire.DateOf(retryAt))
		if sent == nil {
			d.record(l.id, runtimeNote(name+" is rate limited."))
			return wire.EndedReasonRateLimited, true, time.Time{}
		}
		d.record(l.id, runtimeNote(name+" is rate limited. Trying again at "+poolTime(retryAt, at)+"."))
		return wire.EndedReasonRateLimited, true, retryAt
	}
	return "", false, time.Time{}
}

// rateLimited is AllowanceState.rateLimited: shown, and over by itself at retryAt.
func (d *Daemon) rateLimited(key string, retryAt wire.Date) {
	d.allowMu.Lock()
	states := d.allowancesLocked()
	s, ok := states[key]
	if !ok {
		s = availableState(key)
	}
	t := now()
	s.Status = wire.AllowanceStateStatus{RateLimited: &wire.AllowanceStateStatusRateLimited{Until: retryAt}}
	s.Since, s.ChangedAt = t, t
	states[key] = s
	d.saveAllowancesLocked()
	d.allowMu.Unlock()
	d.tellAllowances()
}

// allowanceWorked is a turn that worked: whatever held its credential (key) is over, and
// its rate limits are forgotten.
func (d *Daemon) allowanceWorked(l *live, key string) {
	l.mu.Lock()
	l.rateLimitStreak, l.rateLimitAttempts = nil, 0
	window := l.rateLimit
	l.mu.Unlock()
	d.allowMu.Lock()
	states := d.allowancesLocked()
	s, ok := states[key]
	if !ok || (s.Status.Available != nil && len(s.RateLimitStreak) == 0 && window == nil) {
		d.allowMu.Unlock()
		return
	}
	wasOut := s.Status.Out != nil
	t := now()
	if s.Status.Available == nil || len(s.RateLimitStreak) > 0 {
		s.Status = wire.AllowanceStateStatus{Available: &struct{}{}}
		s.Since, s.ChangedAt, s.RateLimitStreak = t, t, []wire.Date{}
	}
	if window != nil {
		s.LastRateLimit = window
	}
	states[key] = s
	d.saveAllowancesLocked()
	d.allowMu.Unlock()
	if wasOut {
		d.raiseAllowanceBack(key, "worked")
		d.allowanceBack(key)
	}
	d.tellAllowances()
}

// readingKeptFor is how long the same plan window stands before it is written again:
// Claude repeats it on every usage_update.
const readingKeptFor = 5 * time.Minute

// notePlanWindow is a plan window the runtime reported (R2): kept for the turn's end, and
// on the credential for the Pool page. One saying when a spent allowance is back, read
// within a minute of the refusal it explains, puts that time on it.
func (d *Daemon) notePlanWindow(l *live, key string, w *wire.RateLimitInfo) {
	l.mu.Lock()
	l.rateLimit = w
	l.mu.Unlock()
	at := time.Now()
	t := wire.DateOf(at)
	changed := false
	d.allowMu.Lock()
	states := d.allowancesLocked()
	s, ok := states[key]
	if !ok {
		s = availableState(key)
	}
	if w.RateLimitType != nil || w.ResetsAt != nil || w.Utilization != nil {
		r := wire.AllowanceReading{Window: w.RateLimitType, Used: w.Utilization, ResetsAt: w.ResetsAt, Spent: rateLimitRejected(w),
			NearlySpent: w.Status != nil && *w.Status == "allowed_warning", At: t}
		if r.Used != nil && *r.Used > 1 {
			u := *r.Used / 100
			r.Used = &u
		}
		if b := s.Reading; b == nil || !sameReading(*b, r) || at.Sub(b.At.Time()) >= readingKeptFor {
			s.Reading, changed = &r, true
		}
	}
	if o := s.Status.Out; rateLimitRejected(w) && w.ResetsAt != nil && w.ResetsAt.Time().After(at) && o != nil &&
		o.Until == nil && o.Why == wire.AllowanceStateOutReasonAllowanceSpent && at.Sub(s.ChangedAt.Time()) < time.Minute {
		o.Until, changed = w.ResetsAt, true
	}
	if changed {
		states[key] = s
		d.saveAllowancesLocked()
	}
	d.allowMu.Unlock()
	if changed {
		d.tellAllowances()
	}
}

func sameReading(a, b wire.AllowanceReading) bool {
	eq := func(x, y *float64) bool { return (x == nil) == (y == nil) && (x == nil || *x == *y) }
	es := func(x, y *string) bool { return (x == nil) == (y == nil) && (x == nil || *x == *y) }
	ed := func(x, y *wire.Date) bool { return (x == nil) == (y == nil) && (x == nil || *x == *y) }
	return es(a.Window, b.Window) && eq(a.Used, b.Used) && ed(a.ResetsAt, b.ResetsAt) && a.Spent == b.Spent && a.NearlySpent == b.NearlySpent
}

// retryLater sends the same prompt again once a rate limit's wait is over, unless the
// agent has moved on: stopped, archived, given another prompt, or already working.
func (l *live) retryLater(at time.Time) {
	l.mu.Lock()
	stops, sent := l.stops, l.lastSent
	l.mu.Unlock()
	if sent == nil {
		return
	}
	safe.Go("rate limit retry", func() {
		select {
		case <-time.After(time.Until(at)):
		case <-l.d.ctx.Done():
			return
		}
		l.mu.Lock()
		moved := l.stops != stops || l.running
		l.mu.Unlock()
		a := l.d.Store.Agent(l.id)
		if moved || a == nil || a.State != wire.AgentStateStopped || a.EndedReason == nil || *a.EndedReason != wire.EndedReasonRateLimited ||
			a.ArchivedAt != nil || len(a.QueuedPrompts) > 0 {
			return
		}
		q := *sent
		q.ID, q.QueuedAt = store.NewUUID(), now()
		l.mu.Lock()
		l.resend = q.ID
		l.mu.Unlock()
		l.d.enqueue(l.id, q, true)
	})
}
