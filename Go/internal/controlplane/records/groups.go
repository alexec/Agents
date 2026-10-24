package records

import (
	"context"
	"sort"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Groups (#1761, spec 736 data-model.md "Group"): everyone, or named users. A group owns
// machine providers, and a bot's cost (FR-027, FR-028, FR-033).

const GroupsPrefix = "v1/groups/"

// GroupKey is where a group is kept.
func GroupKey(id string) string { return GroupsPrefix + id + ".json" }

// Group is groups/<id>.json. The data model's members, "everyone" or a list, is written
// as everyone and members, so each language reads it without a union.
type Group struct {
	ID       string
	Name     string
	Everyone bool
	Members  []string
	// Spend caps for the group's bots together (#1761, FR-033).
	Caps *Caps
	// A SCIM group's provider (#1002, FR-019): only SCIM changes its members.
	Source *GroupSource
	// "admin": the group gives its members the admin role (FR-020).
	Role      string
	Rev       int
	Removed   *bool
	RemovedAt *Stamp
	Extra     Extra
}

// GroupSource is where a SCIM group comes from.
type GroupSource struct {
	SCIM        string `json:"scim"`
	ExternalID  string `json:"externalId,omitempty"`
	DisplayName string `json:"displayName"`
}

type groupJSON struct {
	ID        string       `json:"id"`
	Name      string       `json:"name"`
	Everyone  bool         `json:"everyone,omitempty"`
	Members   []string     `json:"members"`
	Caps      *Caps        `json:"caps,omitempty"`
	Source    *GroupSource `json:"source,omitempty"`
	Role      string       `json:"role,omitempty"`
	Rev       int          `json:"rev,omitempty"`
	Removed   *bool        `json:"removed,omitempty"`
	RemovedAt *Stamp       `json:"removedAt,omitempty"`
}

func (g Group) MarshalJSON() ([]byte, error) {
	members := g.Members
	if members == nil {
		members = []string{}
	}
	return encodeKeeping(groupJSON{g.ID, g.Name, g.Everyone, members, g.Caps, g.Source, g.Role, g.Rev, g.Removed, g.RemovedAt}, g.Extra)
}

func (g *Group) UnmarshalJSON(data []byte) error {
	var j groupJSON
	extra, err := decodeKeeping(data, &j, "id", "name")
	if err != nil {
		return err
	}
	*g = Group{j.ID, j.Name, j.Everyone, j.Members, j.Caps, j.Source, j.Role, j.Rev, j.Removed, j.RemovedAt, extra}
	return nil
}

// IsRemoved says the group was removed: kept, so another copy reads it as gone.
func (g *Group) IsRemoved() bool { return g.Removed != nil && *g.Removed }

// Has says a user is a member: everyone, or named.
func (g *Group) Has(user string) bool {
	if g.Everyone {
		return true
	}
	for _, m := range g.Members {
		if m == user {
			return true
		}
	}
	return false
}

func (r *Records) loadGroups(ctx context.Context) error {
	listed, err := r.Store.List(ctx, GroupsPrefix)
	if err != nil {
		return err
	}
	r.mu.Lock()
	heldGroups := map[string]held[Group]{}
	for _, h := range r.groups {
		heldGroups[GroupKey(h.record.ID)] = h
	}
	r.mu.Unlock()
	groups := map[string]held[Group]{}
	for _, entry := range listed {
		if h, ok := heldGroups[entry.Key]; ok && h.etag == entry.ETag {
			groups[h.record.ID] = h
			continue
		}
		object, ok := r.read(ctx, entry)
		if !ok || object == nil {
			if h, there := heldGroups[entry.Key]; there {
				groups[h.record.ID] = h
			}
			continue
		}
		var g Group
		if err := g.UnmarshalJSON(object.Data); err != nil || GroupKey(g.ID) != entry.Key {
			r.noteUnreadable(entry.Key, object.ETag, "")
			continue
		}
		groups[g.ID] = held[Group]{g, object.ETag}
	}
	r.mu.Lock()
	r.groups = groups
	r.mu.Unlock()
	return nil
}

// Groups is every group not removed, by name.
func (r *Records) Groups() []Group {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := []Group{}
	for _, h := range r.groups {
		if !h.record.IsRemoved() {
			out = append(out, h.record)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Name != out[j].Name {
			return out[i].Name < out[j].Name
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// Group is the group of that id, or nil when there is none or it was removed.
func (r *Records) Group(id string) *Group {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h, ok := r.groups[id]; ok && !h.record.IsRemoved() {
		g := h.record
		return &g
	}
	return nil
}

// ChangeGroup changes one group under the write lock, after reading groups again, and
// writes it against the version read; a new one is written only if absent. change gets
// the group (nil for none) and returns what to write, or nil to write nothing.
func (r *Records) ChangeGroup(ctx context.Context, id string, change func(*Group) (*Group, error)) (*Group, error) {
	r.writing.Lock()
	defer r.writing.Unlock()
	if err := r.loadGroups(ctx); err != nil {
		return nil, err
	}
	r.mu.Lock()
	h, there := r.groups[id]
	r.mu.Unlock()
	var current *Group
	if there && !h.record.IsRemoved() {
		g := h.record
		current = &g
	}
	next, err := change(current)
	if err != nil || next == nil {
		return current, err
	}
	condition := store.Absent
	next.Rev = 1
	if there {
		next.Rev = h.record.Rev + 1
		condition = store.Matching(h.etag)
	}
	kept, etag, err := write(ctx, r.Store, *next, GroupKey(next.ID), condition)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	r.groups[kept.ID] = held[Group]{kept, etag}
	r.mu.Unlock()
	return &kept, nil
}
