package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Catalogue governance (#2019, M5): a person asks for an MCP server or a skill, an admin
// approves it for a group (once: each member who asks again is approved at once) or for
// the person, or refuses it; and each machine says which servers and skills it has from a
// catalogue, at which version, so an admin sees who uses each.
//
// The store, each part with a bound:
//   - v1/governance/machines/<host>.json, a machine's last report: at most 500 items, gone
//     when its host has no record;
//   - v1/governance/requests/<id>.json: at most 10 waiting per person and 1000 in all; a
//     decided one goes after 30 days;
//   - v1/governance/approvals/<hash>.json: at most 1000.
//
// Policy's marketplace allowlist (#998) still says what a machine may install: an approval
// is the admin's answer and its record, not a change to the allowlist.

const (
	governancePrefix         = "v1/governance/"
	governanceMachinesPrefix = governancePrefix + "machines/"
	governanceRequestsPrefix = governancePrefix + "requests/"
	governanceApprovalPrefix = governancePrefix + "approvals/"
	governanceItemsMost      = 500
	governanceWaitingMost    = 10
	governanceRequestsMost   = 1000
	governanceApprovalsMost  = 1000
	governanceDecidedKept    = 30 * 24 * time.Hour
	governancePeopleMost     = 50
	governanceNameMost       = 200
	governanceSourceMost     = 300
	governanceVersionMost    = 100
	governanceWhyMost        = 500
)

// governanceMachine is a machine's last report.
type governanceMachine struct {
	Host  string             `json:"host"`
	At    wire.Date          `json:"at"`
	Items []wire.CatalogItem `json:"items"`
}

func governanceHostKey(host string) string  { return governanceMachinesPrefix + host + ".json" }
func governanceRequestKey(id string) string { return governanceRequestsPrefix + id + ".json" }

// governanceApprovalKey names one approval: of an item, for a group or a person.
func governanceApprovalKey(kind wire.CatalogKind, name, group, user string) string {
	sum := sha256.Sum256([]byte(string(kind) + "\x00" + strings.ToLower(name) + "\x00" + group + "\x00" + user))
	return governanceApprovalPrefix + hex.EncodeToString(sum[:16]) + ".json"
}

func cut(s string, most int) string {
	s = strings.TrimSpace(s)
	if len(s) > most {
		return s[:most]
	}
	return s
}

func cutOptional(s *string, most int) *string { return optional(cut(deref(s), most)) }

func governedKind(kind wire.CatalogKind) bool {
	return kind == wire.CatalogKindMCP || kind == wire.CatalogKindSkills
}

// MARK: What each machine has

// keepGovernanceReport is governance/report: a machine's servers and skills, over its
// last report. More than the bound are cut, and said in the log.
func (s *Service) keepGovernanceReport(ctx context.Context, host string, report wire.MachineCatalog, now time.Time) error {
	items := make([]wire.CatalogItem, 0, min(len(report.Items), governanceItemsMost))
	seen := map[string]bool{}
	for _, item := range report.Items {
		item.Name = cut(item.Name, governanceNameMost)
		item.Source, item.Version = cutOptional(item.Source, governanceSourceMost), cutOptional(item.Version, governanceVersionMost)
		key := string(item.Kind) + "\x00" + item.Name + "\x00" + deref(item.Version)
		if !governedKind(item.Kind) || item.Name == "" || seen[key] {
			continue
		}
		if len(items) == governanceItemsMost {
			s.log("governance: " + host + " reported more than " + strconv.Itoa(governanceItemsMost) + " servers and skills; the rest are not kept")
			break
		}
		seen[key] = true
		items = append(items, item)
	}
	data, _ := json.Marshal(governanceMachine{Host: host, At: dateOf(now), Items: items})
	if _, err := s.cfg.Store.Put(ctx, governanceHostKey(host), data, store.Always); err != nil {
		return fail(storeUnavailable, "The report could not be kept: %v", err)
	}
	return nil
}

// governanceUsage is governance/usage: each item at each version, on how many machines and
// whose. A report of a machine that has no record any more is deleted.
func (s *Service) governanceUsage(ctx context.Context) (wire.CatalogUsage, error) {
	out := wire.CatalogUsage{Rows: []wire.CatalogUseRow{}}
	keys, err := s.cfg.Store.List(ctx, governanceMachinesPrefix)
	if err != nil {
		return out, fail(storeUnavailable, "The machines' reports could not be read: %v", err)
	}
	type row struct {
		wire.CatalogUseRow
		people map[string]bool
	}
	rows := map[string]*row{}
	for _, k := range keys {
		host, ok := strings.CutSuffix(strings.TrimPrefix(k.Key, governanceMachinesPrefix), ".json")
		if !ok {
			continue
		}
		if s.records.Host(host) == nil {
			_ = s.cfg.Store.Delete(ctx, k.Key)
			continue
		}
		object, err := s.cfg.Store.Get(ctx, k.Key)
		if err != nil {
			return out, fail(storeUnavailable, "A machine's report could not be read: %v", err)
		}
		var m governanceMachine
		if object == nil || json.Unmarshal(object.Data, &m) != nil {
			continue
		}
		out.Machines++
		owner := s.ownerOf(host)
		for _, item := range m.Items {
			key := string(item.Kind) + "\x00" + item.Name + "\x00" + deref(item.Version)
			r := rows[key]
			if r == nil {
				r = &row{CatalogUseRow: wire.CatalogUseRow{Kind: item.Kind, Name: item.Name, Source: item.Source,
					Version: deref(item.Version), People: []wire.CatalogPerson{}}, people: map[string]bool{}}
				rows[key] = r
			}
			r.Machines++
			if owner != "" && !r.people[owner] && len(r.People) < governancePeopleMost {
				r.people[owner] = true
				r.People = append(r.People, wire.CatalogPerson{ID: owner, Name: s.shownPerson(owner)})
			}
		}
	}
	for _, r := range rows {
		sort.Slice(r.People, func(i, j int) bool { return r.People[i].Name < r.People[j].Name })
		out.Rows = append(out.Rows, r.CatalogUseRow)
	}
	sort.Slice(out.Rows, func(i, j int) bool {
		a, b := out.Rows[i], out.Rows[j]
		if a.Kind != b.Kind {
			return a.Kind < b.Kind
		}
		if !strings.EqualFold(a.Name, b.Name) {
			return strings.ToLower(a.Name) < strings.ToLower(b.Name)
		}
		return a.Version < b.Version
	})
	return out, nil
}

// shownPerson is a person's name, or their id when they have none.
func (s *Service) shownPerson(user string) string {
	if name := s.personName(user); name != "" {
		return name
	}
	if user == s.localOwner() {
		return audit.LocalOwnerName
	}
	return user
}

// MARK: Requests and approvals

func (s *Service) governanceRequests(ctx context.Context, now time.Time) ([]wire.CatalogRequest, error) {
	keys, err := s.cfg.Store.List(ctx, governanceRequestsPrefix)
	if err != nil {
		return nil, fail(storeUnavailable, "The requests could not be read: %v", err)
	}
	out := []wire.CatalogRequest{}
	for _, k := range keys {
		object, err := s.cfg.Store.Get(ctx, k.Key)
		if err != nil {
			return nil, fail(storeUnavailable, "A request could not be read: %v", err)
		}
		var r wire.CatalogRequest
		if object == nil || json.Unmarshal(object.Data, &r) != nil {
			continue
		}
		// A decided request is kept for the person to see, then goes; a removed person's
		// goes at once.
		gone := s.records.Person(r.User) != nil && s.records.Person(r.User).IsRemoved()
		if gone || r.State != wire.CatalogRequestStateWaiting && r.DecidedAt != nil && now.Sub(r.DecidedAt.Time()) > governanceDecidedKept {
			_ = s.cfg.Store.Delete(ctx, k.Key)
			continue
		}
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At < out[j].At })
	return out, nil
}

func (s *Service) governanceApprovals(ctx context.Context) ([]wire.CatalogApproval, error) {
	keys, err := s.cfg.Store.List(ctx, governanceApprovalPrefix)
	if err != nil {
		return nil, fail(storeUnavailable, "The approvals could not be read: %v", err)
	}
	out := []wire.CatalogApproval{}
	for _, k := range keys {
		object, err := s.cfg.Store.Get(ctx, k.Key)
		if err != nil {
			return nil, fail(storeUnavailable, "An approval could not be read: %v", err)
		}
		var a wire.CatalogApproval
		if object != nil && json.Unmarshal(object.Data, &a) == nil {
			// The names as they are now: a group or a person may have been renamed.
			if a.Group != nil {
				a.GroupName = optional(s.groupName(*a.Group))
			}
			if a.User != nil {
				a.UserName = optional(s.shownPerson(*a.User))
			}
			out = append(out, a)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		if !strings.EqualFold(out[i].Name, out[j].Name) {
			return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
		}
		return deref(out[i].GroupName)+deref(out[i].UserName) < deref(out[j].GroupName)+deref(out[j].UserName)
	})
	return out, nil
}

// approvedFor is the approval that already covers a person's ask: theirs, or one of a
// group they are in.
func (s *Service) approvedFor(approvals []wire.CatalogApproval, user string, kind wire.CatalogKind, name string) *wire.CatalogApproval {
	for i, a := range approvals {
		if a.Kind != kind || !strings.EqualFold(a.Name, name) {
			continue
		}
		if (a.User != nil && *a.User == user) || (a.Group != nil && s.inGroup(user, *a.Group)) {
			return &approvals[i]
		}
	}
	return nil
}

// governanceRequest is governance/request.
func (s *Service) governanceRequest(ctx context.Context, actor wire.AuditActor, ask wire.CatalogAsk, now time.Time) (wire.CatalogRequest, error) {
	user := actor.User
	ask.Name = cut(ask.Name, governanceNameMost)
	if !governedKind(ask.Kind) || ask.Name == "" {
		return wire.CatalogRequest{}, fail(invalidParams, "Say which MCP server or skill.")
	}
	all, err := s.governanceRequests(ctx, now)
	if err != nil {
		return wire.CatalogRequest{}, err
	}
	waiting := 0
	for _, r := range all {
		if r.User != user || r.State != wire.CatalogRequestStateWaiting {
			continue
		}
		if r.Kind == ask.Kind && strings.EqualFold(r.Name, ask.Name) {
			return r, nil
		}
		waiting++
	}
	if waiting >= governanceWaitingMost {
		return wire.CatalogRequest{}, fail(invalidParams, "You have %d requests waiting. Wait for an admin to answer them.", waiting)
	}
	if len(all) >= governanceRequestsMost {
		return wire.CatalogRequest{}, fail(invalidParams, "Too many requests wait for an admin. Try again later.")
	}
	r := wire.CatalogRequest{ID: randomToken(12), Kind: ask.Kind, Name: ask.Name, Source: cutOptional(ask.Source, governanceSourceMost),
		Why: cutOptional(ask.Why, governanceWhyMost), User: user, UserName: s.shownPerson(user), At: dateOf(now),
		State: wire.CatalogRequestStateWaiting}
	approvals, err := s.governanceApprovals(ctx)
	if err != nil {
		return wire.CatalogRequest{}, err
	}
	if a := s.approvedFor(approvals, user, ask.Kind, ask.Name); a != nil {
		r.State, r.Group, r.GroupName, r.DecidedBy, r.DecidedAt = wire.CatalogRequestStateApproved, a.Group, a.GroupName, optional(a.By), optional(dateOf(now))
	}
	data, _ := json.Marshal(r)
	if _, err := s.cfg.Store.Put(ctx, governanceRequestKey(r.ID), data, store.Absent); err != nil {
		return wire.CatalogRequest{}, fail(storeUnavailable, "The request could not be kept: %v", err)
	}
	if r.State == wire.CatalogRequestStateWaiting {
		s.tellAdmins(wire.NotifyControlGovernanceRequested.Name, r)
	}
	s.auditAs(actor, "governance/asked", governanceWords(r.Kind, r.Name))
	return r, nil
}

// governanceDecide is governance/decide, an admin's.
func (s *Service) governanceDecide(ctx context.Context, actor wire.AuditActor, d wire.CatalogDecide, now time.Time) (wire.CatalogRequest, error) {
	object, err := s.cfg.Store.Get(ctx, governanceRequestKey(d.Request))
	if err != nil {
		return wire.CatalogRequest{}, fail(storeUnavailable, "The request could not be read: %v", err)
	}
	var r wire.CatalogRequest
	if object == nil || json.Unmarshal(object.Data, &r) != nil {
		return wire.CatalogRequest{}, fail(invalidParams, "There is no such request.")
	}
	if r.State != wire.CatalogRequestStateWaiting {
		return r, fail(changedElsewhere, "Another admin answered this request.")
	}
	group := deref(d.Group)
	if group != "" && s.records.Group(group) == nil {
		return wire.CatalogRequest{}, fail(invalidParams, "There is no such group.")
	}
	by := deref(actor.UserName)
	if by == "" {
		by = actor.User
	}
	r.State, r.DecidedBy, r.DecidedAt = wire.CatalogRequestStateRefused, optional(by), optional(dateOf(now))
	if d.Approve {
		r.State = wire.CatalogRequestStateApproved
		approval := wire.CatalogApproval{Kind: r.Kind, Name: r.Name, Source: r.Source, By: by, At: dateOf(now)}
		if group != "" {
			approval.Group, approval.GroupName = &group, optional(s.groupName(group))
			r.Group, r.GroupName = approval.Group, approval.GroupName
		} else {
			approval.User, approval.UserName = optional(r.User), optional(r.UserName)
		}
		if err := s.keepApproval(ctx, approval); err != nil {
			return wire.CatalogRequest{}, err
		}
	}
	data, _ := json.Marshal(r)
	if _, err := s.cfg.Store.Put(ctx, governanceRequestKey(r.ID), data, store.Matching(object.ETag)); err != nil {
		if store.IsConflict(err) {
			return wire.CatalogRequest{}, fail(changedElsewhere, "Another admin answered this request.")
		}
		return wire.CatalogRequest{}, fail(storeUnavailable, "The answer could not be kept: %v", err)
	}
	s.tellAdmins(wire.NotifyControlGovernanceRequested.Name, r)
	s.router.TellPerson(r.User, wire.NotifyControlGovernanceRequested.Name, r)
	method := "governance/refused"
	if d.Approve {
		method = "governance/approved"
	}
	s.auditAs(actor, method, governanceWords(r.Kind, r.Name)+" for "+r.UserName)
	// The others of the group waiting for the same item are approved with it.
	if d.Approve && group != "" {
		s.approveWaiting(ctx, actor, r, group, now)
	}
	return r, nil
}

// approveWaiting approves the other requests waiting for the item from members of the
// group just approved.
func (s *Service) approveWaiting(ctx context.Context, actor wire.AuditActor, approved wire.CatalogRequest, group string, now time.Time) {
	all, err := s.governanceRequests(ctx, now)
	if err != nil {
		return
	}
	for _, r := range all {
		if r.ID == approved.ID || r.State != wire.CatalogRequestStateWaiting || r.Kind != approved.Kind ||
			!strings.EqualFold(r.Name, approved.Name) || !s.inGroup(r.User, group) {
			continue
		}
		r.State, r.Group, r.GroupName, r.DecidedBy, r.DecidedAt = wire.CatalogRequestStateApproved, approved.Group, approved.GroupName,
			approved.DecidedBy, optional(dateOf(now))
		data, _ := json.Marshal(r)
		if _, err := s.cfg.Store.Put(ctx, governanceRequestKey(r.ID), data, store.Always); err == nil {
			s.tellAdmins(wire.NotifyControlGovernanceRequested.Name, r)
			s.router.TellPerson(r.User, wire.NotifyControlGovernanceRequested.Name, r)
		}
	}
}

func (s *Service) keepApproval(ctx context.Context, a wire.CatalogApproval) error {
	key := governanceApprovalKey(a.Kind, a.Name, deref(a.Group), deref(a.User))
	if there, err := s.cfg.Store.Get(ctx, key); err != nil {
		return fail(storeUnavailable, "The approvals could not be read: %v", err)
	} else if there != nil {
		return nil
	}
	keys, err := s.cfg.Store.List(ctx, governanceApprovalPrefix)
	if err != nil {
		return fail(storeUnavailable, "The approvals could not be read: %v", err)
	}
	if len(keys) >= governanceApprovalsMost {
		return fail(invalidParams, "There are %d approvals already. Take back some first.", len(keys))
	}
	data, _ := json.Marshal(a)
	if _, err := s.cfg.Store.Put(ctx, key, data, store.Always); err != nil {
		return fail(storeUnavailable, "The approval could not be kept: %v", err)
	}
	return nil
}

// tellAdmins sends a notice to every admin, and to the local owner with no record yet.
func (s *Service) tellAdmins(method string, params any) {
	for _, p := range s.records.People() {
		if p.IsAdmin() && !p.IsRemoved() {
			s.router.TellPerson(p.ID, method, params)
		}
	}
	if s.records.Person(s.localOwner()) == nil {
		s.router.TellPerson(s.localOwner(), method, params)
	}
}

func governanceWords(kind wire.CatalogKind, name string) string {
	if kind == wire.CatalogKindSkills {
		return "the skill " + name
	}
	return "the MCP server " + name
}

// governanceMethod answers governance/*: usage, decide, approvals and revoke are an
// admin's; anyone may ask, and see their own requests.
func (m *Methods) governanceMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	actor := m.s.actorFor(from.Client)
	actor.User = m.callerPerson(from)
	admin := m.s.isAdmin(actor.User)
	now := time.Now()
	switch method {
	case "governance/request":
		ask, err := require[wire.CatalogAsk](params, "CatalogAsk")
		if err != nil {
			return nil, err
		}
		return m.s.governanceRequest(ctx, actor, ask, now)
	case "governance/requests":
		all, err := m.s.governanceRequests(ctx, now)
		if err != nil {
			return nil, err
		}
		out := wire.CatalogRequestList{Requests: []wire.CatalogRequest{}}
		for _, r := range all {
			if (admin && r.State == wire.CatalogRequestStateWaiting) || r.User == actor.User {
				out.Requests = append(out.Requests, r)
			}
		}
		return out, nil
	}
	if !admin {
		return nil, fail(notPermitted, "Only an admin can see or answer the catalogue's requests.")
	}
	switch method {
	case "governance/usage":
		return m.s.governanceUsage(ctx)
	case "governance/decide":
		d, err := require[wire.CatalogDecide](params, "CatalogDecide")
		if err != nil {
			return nil, err
		}
		return m.s.governanceDecide(ctx, actor, d, now)
	case "governance/revoke":
		r, err := require[wire.CatalogRevoke](params, "CatalogRevoke")
		if err != nil {
			return nil, err
		}
		if err := m.s.cfg.Store.Delete(ctx, governanceApprovalKey(r.Kind, r.Name, deref(r.Group), deref(r.User))); err != nil {
			return nil, fail(storeUnavailable, "The approval could not be taken back: %v", err)
		}
		m.s.auditAs(actor, "governance/revoked", governanceWords(r.Kind, r.Name))
		fallthrough
	default:
		approvals, err := m.s.governanceApprovals(ctx)
		if err != nil {
			return nil, err
		}
		return wire.CatalogApprovalList{Approvals: approvals}, nil
	}
}
