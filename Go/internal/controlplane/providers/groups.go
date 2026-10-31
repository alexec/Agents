package providers

import (
	"context"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Groups own providers (#1761, spec 736 FR-028). Only a provider's group's users start
// machines from it, and only they and the admins see it. A provider with no group is the
// admins' alone, as every provider made before groups is. Admins see every provider, to
// set it up and give it to a group; they start machines only from a group they are in.

// eachPerson is a router that tells each person's sessions their own copy of a notice.
type eachPerson interface {
	BroadcastControlEach(method string, params func(person string) any)
}

// isAdmin says the person is an admin. With no hook (a test), everyone is.
func (p *Providers) isAdmin(person string) bool {
	return p.hooks.IsAdmin == nil || p.hooks.IsAdmin(person)
}

// MayUse says the person may start machines from the provider: they are in its group, or
// it has none and they are an admin.
func (p *Providers) MayUse(person string, r ProviderRecord) bool {
	if r.Group == nil || *r.Group == "" {
		return p.isAdmin(person)
	}
	return p.hooks.InGroup == nil || p.hooks.InGroup(person, *r.Group)
}

// sees says the person is shown the provider at all.
func (p *Providers) sees(person string, r ProviderRecord) bool {
	return p.isAdmin(person) || p.MayUse(person, r)
}

// record is the provider of that id as it is kept, or false.
func (p *Providers) record(id string) (ProviderRecord, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	held, ok := p.providers[id]
	return held.record, ok
}

// SummariesFor is the providers a person is shown: an admin, every one; a member, those
// of their groups, with only the workspaces of their own machines and those on none.
func (p *Providers) SummariesFor(person string) []ProviderSummary {
	admin := p.isAdmin(person)
	out := []ProviderSummary{}
	for _, s := range p.Summaries() {
		r, ok := p.record(string(s.ID))
		if !ok || !p.sees(person, r) {
			continue
		}
		mayUse := p.MayUse(person, r)
		s.MayUse = &mayUse
		if !admin && p.hooks.OwnerOf != nil {
			mine := []MachineInfo{}
			for _, w := range s.Workspaces {
				if w.Host == nil || *w.Host == "" || p.hooks.OwnerOf(string(*w.Host)) == person {
					mine = append(mine, w)
				}
			}
			s.Workspaces = mine
		}
		out = append(out, s)
	}
	return out
}

// adminMethods change a provider itself: only an admin's (#1761).
var adminMethods = map[string]bool{
	MethodProvidersAdd: true, MethodProvidersUpdate: true, MethodProvidersRemove: true,
	MethodProvidersRuntimes: true, MethodDraftStart: true, MethodDraftCancel: true, MethodDraftAnswer: true,
}

// refuse says why the caller may not ask method of a provider, or nil when they may.
func (p *Providers) refuse(method string, params []byte, caller Caller) error {
	if adminMethods[method] {
		if !p.isAdmin(caller.Person) {
			return fail(CodeNotPermitted, "Only an admin can change a machine provider.")
		}
		return nil
	}
	var named struct {
		ID       string `json:"id"`
		Provider string `json:"provider"`
		Host     string `json:"host"`
	}
	decodeJSON(params, &named)
	provider := ""
	switch method {
	case MethodProvidersOptions, MethodProvidersCreate:
		provider = named.ID
	case MethodHostsLink:
		provider = named.Provider
	case MethodHostsStart:
		if h := p.records.Host(named.Host); h != nil {
			if link := LinkOf(h); link != nil {
				provider = link.Provider
			}
		}
	default:
		return nil
	}
	r, ok := p.record(provider)
	if !ok {
		return nil
	}
	if !p.sees(caller.Person, r) {
		return invalid("There is no such provider.")
	}
	if !p.MayUse(caller.Person, r) {
		if r.Group == nil || *r.Group == "" {
			return fail(CodeNotPermitted, "%s is for admins only. An admin can give it to a group.", r.Name)
		}
		group := *r.Group
		if p.hooks.GroupName != nil {
			if name := p.hooks.GroupName(group); name != "" {
				group = name
			}
		}
		return fail(CodeNotPermitted, "Only the %s group can start machines from %s.", group, r.Name)
	}
	return nil
}

// SetGroup is providers/setGroup: the group whose users may use the provider, or none
// for the admins' alone.
func (p *Providers) SetGroup(id string, group *string) error {
	if group != nil && *group == "" {
		group = nil
	}
	p.mu.Lock()
	held, ok := p.providers[id]
	p.mu.Unlock()
	if !ok {
		return invalid("There is no such provider.")
	}
	r := held.record
	if (r.Group == nil && group == nil) || (r.Group != nil && group != nil && *r.Group == *group) {
		return nil
	}
	r.Group = group
	r.Rev++
	data, err := records.Encode(r)
	if err != nil {
		return err
	}
	tag, err := p.store.Put(context.Background(), ProviderKey(id), data, store.Matching(held.etag))
	if err != nil {
		if store.IsConflict(err) {
			p.load()
			return fail(CodeNotPermitted, "%s changed at the same time. Try again.", r.Name)
		}
		return err
	}
	p.mu.Lock()
	p.providers[id] = heldProvider{r, tag}
	p.mu.Unlock()
	to := "the admins"
	if group != nil {
		to = "group " + *group
	}
	p.log("provider: " + id + " given to " + to)
	p.changed()
	return nil
}

// HasGroup says a provider has the group: it may not be removed while one does.
func (p *Providers) HasGroup(group string) string {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, h := range p.providers {
		if h.record.Group != nil && *h.record.Group == group {
			return h.record.Name
		}
	}
	return ""
}

// tellProviders tells each person's sessions the providers they are shown.
func (p *Providers) tellProviders() {
	if each, ok := p.router.(eachPerson); ok {
		each.BroadcastControlEach(NoticeProvidersChanged, func(person string) any {
			return wire.ProviderList{Providers: p.SummariesFor(person)}
		})
		return
	}
	p.router.BroadcastControl(NoticeProvidersChanged, map[string]any{"providers": p.Summaries()})
}

// Republish tells each person the providers they are shown again: after a group or a
// role changed, what each is shown may have.
func (p *Providers) Republish() { p.tellProviders() }

// MayStartFor says the host's workspace may be started now for a user's work (#2011,
// FR-034): it would keep a prompt (Keepable), and the user may use its provider.
func (p *Providers) MayStartFor(person, host string) bool {
	if p.Keepable(host) == "" {
		return false
	}
	link := LinkOf(p.records.Host(host))
	r, ok := p.record(link.Provider)
	return ok && p.MayUse(person, r)
}
