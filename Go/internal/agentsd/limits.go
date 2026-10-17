package agentsd

import (
	"errors"
	"log"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

// What a turn's ending says about the runtime's allowance (052, LimitRecognition): spent,
// its credit used up, rate limited, or nothing. Spent and credit gone take it out of the
// pool, tried again after four hours, and the agent stops saying so; rate limited stops it
// saying that.
//
// The Swift host also reads the runtime's own failure in _meta, its rate-limit reports and
// paid overage, and retries a rate limit by itself. This host reads the words only, and a
// rate limit waits for the person (#1136).

type limitKind int

const (
	limitNone limitKind = iota
	limitSpent
	limitCreditGone
	limitRateLimited
)

var claudeUsageLimitPrefixes = []string{
	"You've hit your", "You've reached your", "You're out of usage credits",
	"Your org is out of usage · add funds to continue", "Your org is out of usage · contact your admin",
	"Your seat type doesn't include usage credits", "Your seat type doesn't include usage",
	"Your usage allocation has been disabled by your admin", "Your group's usage limit is set to $0",
	"Fable 5 requires usage credits", "You're out of extra usage", "Your seat type doesn't include extra usage",
}

const retryWithoutATime = 4 * time.Hour

// classifyLimit is LimitRecognition.classify's words: a refusal's code and message, and
// the turn's own words where a runtime says a refusal there.
func classifyLimit(runtimeID string, code *int, message, said string) limitKind {
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

// applyLimit marks the runtime out for a spent allowance or credit, says so on the agent,
// and gives the reason its turn ends with; false for nothing recognised.
func (d *Daemon) applyLimit(id wire.UUID, kind limitKind) (wire.EndedReason, bool) {
	a := d.Store.Agent(id)
	if a == nil || kind == limitNone {
		return "", false
	}
	name := runtimeName(a.RuntimeID)
	if kind == limitRateLimited {
		d.record(id, runtimeNote(name+" is rate limited."))
		return wire.EndedReasonRateLimited, true
	}
	why, reason, note := wire.AllowanceStateOutReasonAllowanceSpent, "allowance spent", ""
	source := wire.AllowanceStateSourceTypedFailure
	if kind == limitCreditGone {
		why, reason, note, source = wire.AllowanceStateOutReasonCreditUsedUp, "credit used up", name+"’s credit is used up.", wire.AllowanceStateSourceWords
	}
	at := time.Now()
	retry := wire.DateOf(at.Add(retryWithoutATime))
	key := ownKey(a.RuntimeID)
	d.allowMu.Lock()
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
	s.Status = wire.AllowanceStateStatus{Out: &wire.AllowanceStateStatusOut{RetryAfter: &retry, Why: why}}
	s.ChangedAt, s.LearnedFrom, s.RateLimitStreak = t, source, []wire.Date{}
	states[key] = s
	d.saveAllowancesLocked()
	d.allowMu.Unlock()
	if note == "" {
		note = name + "’s allowance ran out. It is tried again after " + poolTime(retry.Time(), at) + "."
	}
	log.Printf("agent %s: %s's %s", id, a.RuntimeID, reason)
	d.raise(wire.EventDraft{Name: "cost.allowance_out", At: now(), Scope: macScope(), Sentence: name + "’s allowance ran out.",
		Details: map[string]string{"runtime": a.RuntimeID, "reason": reason, "retry_after": retry.Time().UTC().Format(time.RFC3339)}})
	d.tellAllowances()
	d.record(id, runtimeNote(note))
	return wire.EndedReasonAllowanceSpent, true
}
