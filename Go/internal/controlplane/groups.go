package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// Groups (#1761, spec 736 FR-027, FR-028): an admin makes groups of everyone or named
// users, and gives each workspace provider to one. Only a provider's group's users see it
// and start machines from it; a provider with no group is the admins' alone.

// inGroup says a user is in a group: everyone, or named.
func (s *Service) inGroup(user, group string) bool {
	g := s.records.Group(group)
	if g == nil {
		return false
	}
	p := s.records.Person(user)
	if p != nil && p.IsRemoved() {
		return false
	}
	// A bot is in its own group (#1761).
	if p != nil && p.IsBot() {
		return p.Group == group
	}
	return g.Has(user)
}

// groupName is what a group is called, or "".
func (s *Service) groupName(group string) string {
	if g := s.records.Group(group); g != nil {
		return g.Name
	}
	return ""
}

func groupOnWire(g records.Group) wire.Group {
	members := g.Members
	if members == nil || g.Everyone {
		members = []string{}
	}
	return wire.Group{ID: g.ID, Name: g.Name, Everyone: g.Everyone, Members: members, Caps: capsOnWire(g.Caps)}
}

// groupsMethod answers groups/list, groups/set, groups/remove and providers/setGroup.
func (m *Methods) groupsMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	user := m.callerPerson(from)
	admin := m.s.isAdmin(user)
	if method == "groups/list" {
		out := wire.GroupList{Groups: []wire.Group{}}
		for _, g := range m.records.Groups() {
			if admin || g.Has(user) {
				out.Groups = append(out.Groups, groupOnWire(g))
			}
		}
		return out, nil
	}
	if !admin {
		return nil, fail(notPermitted, "Only an admin can change groups.")
	}
	switch method {
	case "groups/set":
		request, err := require[wire.GroupSet](params, "GroupSet")
		if err != nil {
			return nil, err
		}
		return m.setGroup(ctx, request)
	case "groups/remove":
		request, err := require[wire.GroupRequest](params, "GroupRequest")
		if err != nil {
			return nil, err
		}
		return wire.Empty{}, m.removeGroup(ctx, request.ID)
	case "providers/setGroup":
		request, err := require[wire.ProviderGroup](params, "ProviderGroup")
		if err != nil {
			return nil, err
		}
		if m.s.providers == nil {
			return nil, fail(providersNeedOneCopy, "Workspace providers need a control plane with one copy, for now.")
		}
		if g := deref(request.Group); g != "" && m.records.Group(g) == nil {
			return nil, fail(invalidParams, "There is no such group.")
		}
		return wire.Empty{}, m.s.providers.SetGroup(string(request.Provider), request.Group)
	}
	return nil, notFound(method)
}

func (m *Methods) setGroup(ctx context.Context, request wire.GroupSet) (wire.Group, error) {
	name := strings.TrimSpace(request.Name)
	if name == "" || utf8.RuneCountInString(name) > 60 {
		return wire.Group{}, fail(invalidParams, "Give the group a name of 1 to 60 characters.")
	}
	id := deref(request.ID)
	for _, g := range m.records.Groups() {
		if g.ID != id && strings.EqualFold(g.Name, name) {
			return wire.Group{}, fail(invalidParams, "There is already a group called %s.", g.Name)
		}
	}
	everyone := deref(request.Everyone)
	members := []string{}
	if !everyone {
		seen := map[string]bool{}
		for _, user := range request.Members {
			p := m.records.Person(user)
			if (p == nil && user != m.s.localOwner()) || (p != nil && p.IsRemoved()) {
				return wire.Group{}, fail(invalidParams, "There is no such person as %s.", user)
			}
			if !seen[user] {
				seen[user] = true
				members = append(members, user)
			}
		}
	}
	making := id == ""
	if making {
		id = records.NewPersonID()
	}
	kept, err := m.records.ChangeGroup(ctx, id, func(g *records.Group) (*records.Group, error) {
		if g == nil && !making {
			return nil, fail(invalidParams, "There is no such group.")
		}
		next := records.Group{ID: id, Name: name, Everyone: everyone, Members: members, Caps: capsOf(request.Caps)}
		if g != nil {
			next.Extra = g.Extra
			if request.Caps == nil {
				next.Caps = g.Caps
			}
		}
		return &next, nil
	})
	if err != nil {
		return wire.Group{}, err
	}
	m.s.groupsChanged(id, false)
	return groupOnWire(*kept), nil
}

func (m *Methods) removeGroup(ctx context.Context, id string) error {
	if m.records.Group(id) == nil {
		return fail(invalidParams, "There is no such group.")
	}
	for _, p := range m.records.People() {
		if p.IsBot() && p.Group == id {
			return fail(notPermitted, "The bot %s is in this group. Give it another group first.", p.Name)
		}
	}
	if m.s.providers != nil {
		if provider := m.s.providers.HasGroup(id); provider != "" {
			return fail(notPermitted, "%s belongs to this group. Give it to another group first.", provider)
		}
	}
	_, err := m.records.ChangeGroup(ctx, id, func(g *records.Group) (*records.Group, error) {
		if g == nil {
			return nil, nil
		}
		yes, now := true, records.Now()
		next := *g
		next.Removed, next.RemovedAt = &yes, &now
		return &next, nil
	})
	if err != nil {
		return err
	}
	m.s.groupsChanged(id, true)
	return nil
}

// groupsChanged tells this copy's clients, and every other copy, that a group changed.
func (s *Service) groupsChanged(id string, removed bool) {
	s.tellGroupsChanged(id, removed)
	s.announce("groupsChanged", id, "")
}

// tellGroupsChanged tells this copy's clients: groups, and so the providers each person
// is shown, changed.
func (s *Service) tellGroupsChanged(id string, removed bool) {
	change := wire.GroupsChanged{}
	if id != "" {
		change.ID = &id
	}
	if removed {
		change.Removed = &removed
	}
	s.router.BroadcastControl("control/groupsChanged", change)
	if s.providers != nil {
		s.providers.Republish()
	}
}
