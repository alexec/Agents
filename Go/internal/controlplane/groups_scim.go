package controlplane

import (
	"context"
	"net/http"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/scim"
	"github.com/alexec/agents/Go/wire"
)

// SCIM groups as groups (#1002, spec 1002 slice 2a, D14, FR-019 to FR-021): a group the
// provider pushes is a group with source: scim, whose members only SCIM changes, and only
// to users of the same provider. An admin can give it what any group gets, and mark it
// Gives the admin role: its members are admins while they are in it. No SCIM change leaves
// the control plane with no admin.

func scimGroup(g *records.Group, provider string) bool {
	return g != nil && !g.IsRemoved() && g.Source != nil && g.Source.SCIM == provider
}

func (d scimDirectory) groupOf(g records.Group) scim.Group {
	out := groupValuesOf(g)
	d.nameMembers(&out)
	return out
}

// groupValuesOf is a group with its members' values and not their names.
func groupValuesOf(g records.Group) scim.Group {
	out := scim.Group{ID: g.ID, ExternalID: g.Source.ExternalID, DisplayName: g.Source.DisplayName}
	for _, m := range g.Members {
		out.Members = append(out.Members, scim.Member{Value: m})
	}
	return out
}

func (d scimDirectory) nameMembers(g *scim.Group) {
	for i := range g.Members {
		g.Members[i].Display = d.s.personName(g.Members[i].Value)
	}
}

func (d scimDirectory) Groups(ctx context.Context, provider string, keep func(scim.Group) bool) ([]scim.Group, error) {
	var out []scim.Group
	for _, g := range d.s.records.Groups() {
		if !scimGroup(&g, provider) {
			continue
		}
		// Named only once kept: a sync asks for one group by its name (#2430).
		if sg := groupValuesOf(g); keep(sg) {
			d.nameMembers(&sg)
			out = append(out, sg)
		}
	}
	slices.SortFunc(out, func(a, b scim.Group) int { return strings.Compare(a.ID, b.ID) })
	return out, nil
}

func (d scimDirectory) Group(ctx context.Context, provider, id string) (*scim.Group, error) {
	g := d.s.records.Group(id)
	if !scimGroup(g, provider) {
		return nil, nil
	}
	out := d.groupOf(*g)
	return &out, nil
}

// members checks that each member is a user of the provider (FR-019).
func (d scimDirectory) members(provider string, g scim.Group) ([]string, error) {
	out := make([]string, 0, len(g.Members))
	for _, m := range g.Members {
		if !scimPerson(d.s.records.Person(m.Value), provider) {
			return nil, scim.InvalidValue("%s is not a user of this provider here.", m.Value)
		}
		out = append(out, m.Value)
	}
	return out, nil
}

// sameName refuses a second group of the provider with one displayName.
func (d scimDirectory) sameName(provider, id, name string) error {
	for _, g := range d.s.records.Groups() {
		if g.ID != id && scimGroup(&g, provider) && strings.EqualFold(g.Source.DisplayName, name) {
			return scim.Uniqueness("Another group has the displayName %q.", name)
		}
	}
	return nil
}

func (d scimDirectory) CreateGroup(ctx context.Context, c scim.Caller, g scim.Group) (*scim.Group, error) {
	if err := d.sameName(c.Provider, "", g.DisplayName); err != nil {
		return nil, err
	}
	members, err := d.members(c.Provider, g)
	if err != nil {
		return nil, err
	}
	id := records.NewPersonID()
	full := false
	kept, err := d.s.records.ChangeGroup(ctx, id, func(*records.Group) (*records.Group, error) {
		if len(d.s.records.Groups()) >= mostGroups {
			full = true
			return nil, nil
		}
		return &records.Group{ID: id, Name: groupNameOf(g.DisplayName), Members: members,
			Source: &records.GroupSource{SCIM: c.Provider, ExternalID: g.ExternalID, DisplayName: g.DisplayName}}, nil
	})
	if err != nil {
		return nil, scim.Errorf(http.StatusServiceUnavailable, "", "The group could not be kept. Try again.")
	}
	if full {
		return nil, scim.Errorf(http.StatusForbidden, "", "This control plane keeps at most %d groups. Delete one first.", mostGroups)
	}
	d.s.auditAs(d.s.scimActor(c), "scim/group/create", g.DisplayName+", "+strconv.Itoa(len(members))+" members")
	d.s.groupsChanged(id, false)
	out := d.groupOf(*kept)
	return &out, nil
}

// groupNameOf is a SCIM group's name in People and Groups: its displayName, cut to 60.
func groupNameOf(displayName string) string {
	if r := []rune(displayName); len(r) > 60 {
		return string(r[:60])
	}
	return displayName
}

func (d scimDirectory) ReplaceGroup(ctx context.Context, c scim.Caller, g scim.Group) (*scim.Group, error) {
	if err := d.sameName(c.Provider, g.ID, g.DisplayName); err != nil {
		return nil, err
	}
	members, err := d.members(c.Provider, g)
	if err != nil {
		return nil, err
	}
	var before records.Group
	unchanged := false
	kept, err := d.s.records.ChangeGroup(ctx, g.ID, func(current *records.Group) (*records.Group, error) {
		if !scimGroup(current, c.Provider) {
			return nil, scim.Errorf(http.StatusNotFound, "", "No group %s here.", g.ID)
		}
		before = *current
		next := *current
		next.Name, next.Members = groupNameOf(g.DisplayName), members
		next.Source = &records.GroupSource{SCIM: c.Provider, ExternalID: g.ExternalID, DisplayName: g.DisplayName}
		if sameGroup(before, next) {
			unchanged = true
			return nil, nil
		}
		return &next, nil
	})
	if err != nil {
		if _, ok := err.(*scim.Error); ok {
			return nil, err
		}
		return nil, scim.Errorf(http.StatusServiceUnavailable, "", "The group could not be kept. Try again.")
	}
	if unchanged {
		// A sync sends every group again, mostly as it was: nothing is kept or told (#2424).
		out := d.groupOf(*kept)
		return &out, nil
	}
	added, removed := memberChanges(before.Members, members)
	what := g.DisplayName
	if added > 0 || removed > 0 {
		what += ": " + strconv.Itoa(added) + " added, " + strconv.Itoa(removed) + " taken out"
	}
	d.s.auditAs(d.s.scimActor(c), "scim/group/change", what)
	if kept.Role == records.RoleAdmin && (added > 0 || removed > 0) {
		d.s.rolesFromGroups(ctx, c.Provider)
	}
	d.s.groupsChanged(g.ID, false)
	out := d.groupOf(*kept)
	return &out, nil
}

// sameGroup says a SCIM write leaves a group as it was: its name, its members and its source.
func sameGroup(before, after records.Group) bool {
	added, removed := memberChanges(before.Members, after.Members)
	return added == 0 && removed == 0 && len(before.Members) == len(after.Members) && before.Name == after.Name &&
		before.Source != nil && after.Source != nil && *before.Source == *after.Source
}

func memberChanges(before, after []string) (added, removed int) {
	// Sets: a group has up to 10,000 members (#2430).
	was, is := make(map[string]bool, len(before)), make(map[string]bool, len(after))
	for _, m := range before {
		was[m] = true
	}
	for _, m := range after {
		is[m] = true
		if !was[m] {
			added++
		}
	}
	for _, m := range before {
		if !is[m] {
			removed++
		}
	}
	return added, removed
}

// DeleteGroup takes a group away: kept as a tombstone for a week, then swept (#3126).
// Admins are asked to give what it owned (a machine provider, a bot) to another group
// (US5 AS5).
func (d scimDirectory) DeleteGroup(ctx context.Context, c scim.Caller, id string) error {
	g := d.s.records.Group(id)
	if !scimGroup(g, c.Provider) {
		return scim.Errorf(http.StatusNotFound, "", "No group %s here.", id)
	}
	shares := d.s.groupShares(id)
	_, err := d.s.records.ChangeGroup(ctx, id, func(current *records.Group) (*records.Group, error) {
		if !scimGroup(current, c.Provider) {
			return nil, nil
		}
		yes, now := true, records.Now()
		next := *current
		next.Removed, next.RemovedAt, next.Members = &yes, &now, []string{}
		return &next, nil
	})
	if err != nil {
		return scim.Errorf(http.StatusServiceUnavailable, "", "The group could not be kept. Try again.")
	}
	actor := d.s.scimActor(c)
	d.s.auditAs(actor, "scim/group/delete", g.Source.DisplayName)
	if len(shares) > 0 {
		providerName := c.Provider
		if actor.UserName != nil {
			providerName = *actor.UserName
		}
		d.s.noticeAdmins(wire.ControlNotice{Kind: "groupSharesOrphaned", Group: &id,
			Words: providerName + " deleted the group " + g.Source.DisplayName + ", which had " + strings.Join(shares, ", ") +
				". Give them to another group in Console ▸ People and Groups."})
	}
	if g.Role == records.RoleAdmin {
		d.s.rolesFromGroups(ctx, c.Provider)
	}
	d.s.groupsChanged(id, true)
	return nil
}

// groupShares names what a group owns: machine providers and bots.
func (s *Service) groupShares(id string) []string {
	var out []string
	if s.providers != nil {
		if provider := s.providers.HasGroup(id); provider != "" {
			out = append(out, provider)
		}
	}
	for _, p := range s.records.People() {
		if p.IsBot() && p.Group == id {
			out = append(out, "the bot "+p.Name)
		}
	}
	return out
}

// rolesFromGroups sets each person's role from the groups that give the admin role
// (FR-020): admin while in one, and back to the role set by hand, or member, when in none.
// A change that would leave no admin is not made, and admins are told (FR-021).
func (s *Service) rolesFromGroups(ctx context.Context, provider string) {
	var kept []string
	err := s.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		kept = nil
		givers := map[string][]string{}
		for _, g := range s.records.Groups() {
			if g.Role == records.RoleAdmin && g.Source != nil {
				for _, m := range g.Members {
					givers[m] = append(givers[m], g.ID)
				}
			}
		}
		next := map[string]records.Person{}
		for id, p := range all {
			if p.IsRemoved() || p.IsBot() {
				continue
			}
			from := givers[id]
			slices.Sort(from)
			switch {
			case len(from) > 0:
				if len(p.RoleFrom) == 0 {
					p.RoleByHand = p.RoleOrAdmin()
				}
				if p.Role == records.RoleAdmin && slices.Equal(p.RoleFrom, from) {
					continue
				}
				p.Role, p.RoleFrom = records.RoleAdmin, from
			case len(p.RoleFrom) > 0:
				p.Role, p.RoleFrom = p.RoleByHand, nil
				if p.Role == "" {
					p.Role = records.RoleMember
				}
				p.RoleByHand = ""
			default:
				continue
			}
			next[id] = p
		}
		after := map[string]records.Person{}
		for id, p := range all {
			after[id] = p
		}
		for id, p := range next {
			after[id] = p
		}
		if admins(after) == 0 {
			// The last admins stay admins, still set by the groups they left.
			for id, p := range next {
				was := all[id]
				if was.IsAdmin() && !p.IsAdmin() {
					delete(next, id)
					kept = append(kept, was.Name)
				}
			}
		}
		out := make([]records.Person, 0, len(next))
		for _, p := range next {
			out = append(out, p)
		}
		return out, nil
	})
	if err != nil {
		s.log("roles from groups could not be set: " + err.Error())
		return
	}
	if len(kept) > 0 {
		name := provider
		if p, err := s.signIns.scimProvider(ctx, provider); err == nil {
			name = p.Name
		}
		s.noticeAdmins(wire.ControlNotice{Kind: "lastAdminKept",
			Words: name + " took the last admin out of the groups that give the admin role. " + strings.Join(kept, ", ") +
				" stays an admin until another admin is set."})
	}
	s.peopleChanged("", false)
}

// setGroupRole is groups/setRole (FR-020): a SCIM group gives the admin role, or not.
func (m *Methods) setGroupRole(ctx context.Context, r wire.GroupRoleSet, from Caller) (wire.Group, error) {
	role := ""
	if r.Role != nil {
		if *r.Role != records.RoleAdmin {
			return wire.Group{}, fail(invalidParams, "A group gives the admin role, or none.")
		}
		role = records.RoleAdmin
	}
	var provider string
	kept, err := m.records.ChangeGroup(ctx, r.Group, func(g *records.Group) (*records.Group, error) {
		if g == nil {
			return nil, fail(invalidParams, "There is no such group.")
		}
		if g.Source == nil {
			return nil, fail(invalidParams, "Only a group from an org provider gives a role. Set a person's role in People.")
		}
		provider = g.Source.SCIM
		if g.Role == role {
			return nil, nil
		}
		next := *g
		next.Role = role
		return &next, nil
	})
	if err != nil {
		return wire.Group{}, err
	}
	what := "gives no role"
	if role != "" {
		what = "gives the admin role"
	}
	m.s.auditAs(m.s.actorFor(from.Client), "groups/setRole", kept.Name+": "+what)
	m.s.rolesFromGroups(ctx, provider)
	m.s.groupsChanged(kept.ID, false)
	return groupOnWire(*kept), nil
}
