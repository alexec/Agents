package agentsd

import (
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The spending limits, as the Swift host holds agents to them: a new agent is refused when
// the day's limit is reached or a limit for each agent is nothing; what is sent to an agent
// waits while it or the day is at its limit, said once; an agent whose turn crosses its
// limit stops there, the turn finished first; cost.limit_reached is said once a day for
// each. A day rolling over, or a limit raised, lets what waits go.

func costWords(amount float64, currency string) string {
	if currency == "USD" {
		return fmt.Sprintf("$%.2f", amount)
	}
	return fmt.Sprintf("%.2f %s", amount, currency)
}

func spentWords(spent map[string]float64) string {
	var parts []string
	for c, v := range spent {
		parts = append(parts, costWords(v, c))
	}
	sortStrings(parts)
	return strings.Join(parts, " · ")
}

// unmeasured is whether an agent's spending cannot be told, which is never capped.
func unmeasuredMoney(a *wire.Agent) bool {
	return !inFlight(a.State) && len(a.CostToDate) == 0 && (a.LastTurnUsage == nil || a.LastTurnUsage.Cost == nil) &&
		(a.Usage == nil || a.Usage.Cost == nil) && a.LastActivityAt > a.CreatedAt
}

func unmeasuredTokens(a *wire.Agent) bool {
	return !inFlight(a.State) && (a.TokensToDate == nil || *a.TokensToDate == 0) &&
		(a.LastTurnUsage == nil || limitTokens(*a.LastTurnUsage) == 0) && a.LastActivityAt > a.CreatedAt
}

// agentAtLimit says how an agent has reached its own limit, money or tokens, or "".
func (d *Daemon) agentAtLimit(a *wire.Agent) string {
	d.costMu.Lock()
	limits := d.limitsLocked()
	d.costMu.Unlock()
	ceiling := a.CostCeiling
	if ceiling == nil {
		ceiling = limits.PerAgent
	}
	if ceiling != nil && !unmeasuredMoney(a) && a.CostToDate[ceiling.Currency] >= ceiling.Amount {
		return "money"
	}
	tokens := a.TokenCeiling
	if tokens == nil {
		tokens = limits.PerAgentTokens
	}
	if tokens != nil && !unmeasuredTokens(a) && a.TokensToDate != nil && *a.TokensToDate >= *tokens {
		return "tokens"
	}
	return ""
}

// dayAtLimit says how the day has reached its limit ("money" or "tokens").
func (d *Daemon) dayAtLimit() string {
	d.costMu.Lock()
	defer d.costMu.Unlock()
	limits := d.limitsLocked()
	st := d.costStateLocked()
	if limits.DailyTokens != nil && st.TokensToday >= *limits.DailyTokens {
		return "tokens"
	}
	if limits.Daily != nil && st.Today[limits.Daily.Currency] >= limits.Daily.Amount {
		return "money"
	}
	return ""
}

// startRefusal is why no new agent starts now, or nil.
// yourBudgetRefusalData is the PolicyRefusal that rides beside the day/agent limit errors
// below (#2957, FR-010's rule and layer, on an error code older clients already know).
func yourBudgetRefusalData(rule, words string) wire.PolicyRefusal {
	layer := youLayerRef()
	return wire.PolicyRefusal{Reason: "budget", Rule: &rule, Words: words, Layer: &layer, Value: &words}
}

func (d *Daemon) startRefusal() error {
	switch d.dayAtLimit() {
	case "tokens":
		st := d.costState()
		words := fmt.Sprintf("Today has used %d tokens, which reaches the %d you allowed for a day. "+
			"Nothing new starts until the day rolls over, or until you raise the limit.", st.TokensToday, *st.Limits.DailyTokens)
		return &Error{Code: wire.FailureDayLimitReached, Message: words, Data: yourBudgetRefusalData("budgets.dailyTokens", words)}
	case "money":
		st := d.costState()
		words := "Today has cost " + spentWords(st.Today) + ", which reaches the " +
			costWords(st.Limits.Daily.Amount, st.Limits.Daily.Currency) + " you allowed for a day. Nothing new starts until the day rolls over, or until you raise the limit."
		return &Error{Code: wire.FailureDayLimitReached, Message: words, Data: yourBudgetRefusalData("budgets.daily", words)}
	}
	d.costMu.Lock()
	limits := d.limitsLocked()
	d.costMu.Unlock()
	if limits.PerAgent != nil && limits.PerAgent.Amount <= 0 {
		words := "The limit for each agent is set to nothing, so no agent can start. Raise it to start this one."
		return &Error{Code: wire.FailureAgentLimitReached, Message: words, Data: yourBudgetRefusalData("budgets.perAgent", words)}
	}
	if limits.PerAgentTokens != nil && *limits.PerAgentTokens <= 0 {
		words := "The token limit for each agent is set to none, so no agent can start. Raise it to start this one."
		return &Error{Code: wire.FailureAgentLimitReached, Message: words, Data: yourBudgetRefusalData("budgets.perAgentTokens", words)}
	}
	return nil
}

// holdsForLimit is sendNextQueued's holds: true when what is queued waits, said once.
func (d *Daemon) holdsForLimit(id wire.UUID) bool {
	a := d.Store.Agent(id)
	if a == nil {
		return false
	}
	note := ""
	if d.agentAtLimit(a) != "" {
		d.raiseCostLimit("agent", a)
		note = "What you sent is waiting: this agent has reached its cost limit. Raise the limit, or let this one agent go on, and it will go."
	} else {
		switch day := d.dayAtLimit(); day {
		case "tokens", "money":
			d.raiseCostLimit("day", nil)
			kind := "spending"
			if day == "tokens" {
				kind = "token"
			}
			note = "What you sent is waiting: the day's " + kind + " limit has been reached. It will go when the day rolls over, or when you raise the limit."
		}
	}
	d.costMu.Lock()
	if d.held == nil {
		d.held = map[wire.UUID]bool{}
	}
	was := d.held[id]
	if note == "" {
		delete(d.held, id)
	} else {
		d.held[id] = true
	}
	d.costMu.Unlock()
	if note != "" && !was {
		d.record(id, runtimeNote(note))
	}
	return note != ""
}

// crossedLimit is what the end of a turn says when it took the agent to its limit: it
// stops there, nothing half done.
func (d *Daemon) crossedLimit(a *wire.Agent) string {
	switch d.agentAtLimit(a) {
	case "money":
		ceiling := a.CostCeiling
		if ceiling == nil {
			d.costMu.Lock()
			ceiling = d.limitsLocked().PerAgent
			d.costMu.Unlock()
		}
		return "Stopped: this agent has spent " + spentWords(a.CostToDate) + ", which reaches the " + costWords(ceiling.Amount, ceiling.Currency) +
			" limit you set. The turn it was in finished first, so nothing is half-done. Raise the limit, or let this one agent go on, and it will take a prompt again."
	case "tokens":
		n := a.TokenCeiling
		if n == nil {
			d.costMu.Lock()
			n = d.limitsLocked().PerAgentTokens
			d.costMu.Unlock()
		}
		unit := "token"
		if *n != 1 {
			unit = "tokens"
		}
		used := int64(0)
		if a.TokensToDate != nil {
			used = *a.TokensToDate
		}
		return fmt.Sprintf("Stopped: this agent has used %d tokens, which reaches the %d %s limit you set. The turn it was in finished first, "+
			"so nothing is half-done. Raise the limit, or let this one agent go on, and it will take a prompt again.", used, *n, unit)
	}
	return ""
}

// raiseCostLimit is cost.limit_reached, once a day for each limit and each agent's own.
func (d *Daemon) raiseCostLimit(limit string, a *wire.Agent) {
	day := dayStamp(time.Now())
	key := limit
	if a != nil {
		key = "agent:" + string(a.ID)
	}
	d.eventMu.Lock()
	crossings := d.eventStateNow.CostCrossings[day]
	for _, k := range crossings {
		if k == key {
			d.eventMu.Unlock()
			return
		}
	}
	d.eventStateNow.CostCrossings = map[string][]string{day: append(crossings, key)}
	d.saveEventStateLocked()
	d.eventMu.Unlock()
	if a != nil {
		details := agentDetails(a)
		details["limit"] = limit
		d.raise(wire.EventDraft{Name: "cost.limit_reached", At: now(), Scope: folderScope(folderPath(a)),
			Sentence: agentName(a.Title) + " reached its spending limit.", Details: details})
		return
	}
	d.raise(wire.EventDraft{Name: "cost.limit_reached", At: now(), Scope: macScope(), Sentence: "The day's spending limit was reached.",
		Details: map[string]string{"limit": limit}})
}

// drainHeld is drainEverythingHolding: what waited goes, as the day rolled over or a limit rose.
func (d *Daemon) drainHeld() {
	d.costMu.Lock()
	d.held = nil
	d.costMu.Unlock()
	for _, a := range d.Store.Agents() {
		if a.State != wire.AgentStateArchived && len(a.QueuedPrompts) > 0 && !inFlight(a.State) {
			d.live(a.ID).kick()
		}
	}
}

// noteDay lets what waited go when the host's day rolls over.
func (d *Daemon) noteDay() {
	day := dayStamp(time.Now())
	d.costMu.Lock()
	was := d.lastSeenDay
	d.lastSeenDay = day
	d.costMu.Unlock()
	if was != "" && was != day {
		d.tellCost()
		d.drainHeld()
	}
}
