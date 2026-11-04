package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Ask for More (#3262, spec 998 FR-019): a person at the organisation's budget asks an admin
// to raise it for today (UTC). An admin sees the request on Console ▸ Requests, and raises it
// with policy/raise or refuses it with policy/refuseMore.
//
// The store, with a bound: v1/policy/requests/<id>.json, one a person a UTC day (the id is
// of the day and the person), at most 1000 in all. A request of an earlier day goes when the
// requests are next read, as a raise does.

const (
	policyRequestsPrefix = "v1/policy/requests/"
	policyRequestsMost   = 1000
)

// budgetRequestID is the one request a person may have on a day.
func budgetRequestID(day, user string) string {
	sum := sha256.Sum256([]byte(day + "\x00" + user))
	return hex.EncodeToString(sum[:12])
}

func budgetRequestKey(id string) string { return policyRequestsPrefix + id + ".json" }

// budgetRequests is today's requests, oldest first. Those of an earlier day, and a removed
// person's, are deleted.
func (s *Service) budgetRequests(ctx context.Context, now time.Time) ([]wire.BudgetRequest, error) {
	keys, err := s.cfg.Store.List(ctx, policyRequestsPrefix)
	if err != nil {
		return nil, fail(storeUnavailable, "The requests could not be read: %v", err)
	}
	day := now.UTC().Format(time.DateOnly)
	out := []wire.BudgetRequest{}
	for _, k := range keys {
		object, err := s.cfg.Store.Get(ctx, k.Key)
		if err != nil {
			return nil, fail(storeUnavailable, "A request could not be read: %v", err)
		}
		var r wire.BudgetRequest
		if object == nil || json.Unmarshal(object.Data, &r) != nil {
			continue
		}
		if p := s.records.Person(r.User); r.Day != day || p != nil && p.IsRemoved() {
			_ = s.cfg.Store.Delete(ctx, k.Key)
			continue
		}
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At < out[j].At })
	return out, nil
}

// askForMore is policy/askForMore. Asking again the same day answers the request already
// made, whatever its state, so a refusal is not asked again and again.
func (s *Service) askForMore(ctx context.Context, actor wire.AuditActor, ask wire.PolicyAskForMore, now time.Time) (wire.BudgetRequest, error) {
	kept, err := s.readPolicy(ctx)
	if err != nil {
		return wire.BudgetRequest{}, err
	}
	if b := kept.policy; b == nil || b.Budgets == nil || b.Budgets.Daily == nil && b.Budgets.DailyTokens == nil {
		return wire.BudgetRequest{}, fail(invalidParams, "Your organisation sets no budget a day to raise.")
	}
	all, err := s.budgetRequests(ctx, now)
	if err != nil {
		return wire.BudgetRequest{}, err
	}
	day := now.UTC().Format(time.DateOnly)
	id := budgetRequestID(day, actor.User)
	for _, r := range all {
		if r.ID == id {
			return r, nil
		}
	}
	if len(all) >= policyRequestsMost {
		return wire.BudgetRequest{}, fail(invalidParams, "Too many requests wait for an admin. Try again later.")
	}
	r := wire.BudgetRequest{ID: id, User: actor.User, UserName: s.shownPerson(actor.User), Day: day, At: dateOf(now),
		Why: cutOptional(ask.Why, governanceWhyMost), State: wire.BudgetRequestStateWaiting}
	data, _ := json.Marshal(r)
	if _, err := s.cfg.Store.Put(ctx, budgetRequestKey(id), data, store.Absent); err != nil {
		if store.IsConflict(err) {
			// Asked twice at once: the first one stands.
			return s.budgetRequest(ctx, id)
		}
		return wire.BudgetRequest{}, fail(storeUnavailable, "The request could not be kept: %v", err)
	}
	s.tellAdmins(wire.NotifyControlBudgetRequested.Name, r)
	s.auditAs(actor, "policy/askedForMore", "today's budget for "+r.UserName)
	return r, nil
}

func (s *Service) budgetRequest(ctx context.Context, id string) (wire.BudgetRequest, error) {
	object, err := s.cfg.Store.Get(ctx, budgetRequestKey(id))
	if err != nil {
		return wire.BudgetRequest{}, fail(storeUnavailable, "The request could not be read: %v", err)
	}
	var r wire.BudgetRequest
	if object == nil || json.Unmarshal(object.Data, &r) != nil {
		return wire.BudgetRequest{}, fail(invalidParams, "There is no such request.")
	}
	return r, nil
}

// answerBudgetRequest keeps an admin's answer to a waiting request: refused, or raised to
// what the raise says. A request answered already says so.
func (s *Service) answerBudgetRequest(ctx context.Context, actor wire.AuditActor, id string, raise *wire.BudgetRaise,
	now time.Time) (wire.BudgetRequest, error) {
	object, err := s.cfg.Store.Get(ctx, budgetRequestKey(id))
	if err != nil {
		return wire.BudgetRequest{}, fail(storeUnavailable, "The request could not be read: %v", err)
	}
	var r wire.BudgetRequest
	if object == nil || json.Unmarshal(object.Data, &r) != nil || r.Day != now.UTC().Format(time.DateOnly) {
		return wire.BudgetRequest{}, fail(invalidParams, "There is no such request today.")
	}
	if r.State != wire.BudgetRequestStateWaiting {
		return r, fail(changedElsewhere, "Another admin answered this request.")
	}
	by := deref(actor.UserName)
	if by == "" {
		by = actor.User
	}
	r.State, r.DecidedBy, r.DecidedAt = wire.BudgetRequestStateRefused, optional(by), optional(dateOf(now))
	if raise != nil {
		r.State, r.Daily, r.DailyTokens = wire.BudgetRequestStateRaised, raise.Daily, raise.DailyTokens
	}
	data, _ := json.Marshal(r)
	if _, err := s.cfg.Store.Put(ctx, budgetRequestKey(id), data, store.Matching(object.ETag)); err != nil {
		if store.IsConflict(err) {
			return wire.BudgetRequest{}, fail(changedElsewhere, "Another admin answered this request.")
		}
		return wire.BudgetRequest{}, fail(storeUnavailable, "The answer could not be kept: %v", err)
	}
	s.tellAdmins(wire.NotifyControlBudgetRequested.Name, r)
	s.router.TellPerson(r.User, wire.NotifyControlBudgetRequested.Name, r)
	if raise == nil {
		s.auditAs(actor, "policy/refusedMore", "today's budget for "+r.UserName)
	}
	return r, nil
}

// raisedFor answers a person's waiting request of today with the raise just kept, whether
// the admin raised it from Requests or from elsewhere.
func (s *Service) raisedFor(ctx context.Context, actor wire.AuditActor, raise wire.BudgetRaise, now time.Time) {
	r, err := s.budgetRequest(ctx, budgetRequestID(raise.Day, raise.User))
	if err == nil && r.State == wire.BudgetRequestStateWaiting {
		_, _ = s.answerBudgetRequest(ctx, actor, r.ID, &raise, now)
	}
}

// policyAskMethod answers policy/askForMore and policy/requests, anyone's, and
// policy/refuseMore, an admin's.
func (m *Methods) policyAskMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	actor := m.s.actorFor(from.Client)
	actor.User = m.callerPerson(from)
	admin := m.s.isAdmin(actor.User)
	now := time.Now()
	switch method {
	case "policy/askForMore":
		ask, err := require[wire.PolicyAskForMore](params, "PolicyAskForMore")
		if err != nil {
			return nil, err
		}
		return m.s.askForMore(ctx, actor, ask, now)
	case "policy/requests":
		all, err := m.s.budgetRequests(ctx, now)
		if err != nil {
			return nil, err
		}
		out := wire.BudgetRequestList{Requests: []wire.BudgetRequest{}}
		for _, r := range all {
			if (admin && r.State == wire.BudgetRequestStateWaiting) || r.User == actor.User {
				out.Requests = append(out.Requests, r)
			}
		}
		return out, nil
	case "policy/refuseMore":
		if !admin {
			return nil, fail(notPermitted, "Only an admin can answer a request for more budget.")
		}
		request, err := require[wire.PolicyRefuseMore](params, "PolicyRefuseMore")
		if err != nil {
			return nil, err
		}
		return m.s.answerBudgetRequest(ctx, actor, request.Request, nil, now)
	}
	return nil, notFound(method)
}
