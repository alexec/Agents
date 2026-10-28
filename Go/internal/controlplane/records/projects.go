package records

import (
	"context"
	"sort"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Projects (#2317, specs/2317-projects): what people work on, the record that folders
// join. A folder names its project's id in its own .agents/folder.json.

const ProjectsPrefix = "v1/projects/"

// ProjectKey is where a project is kept.
func ProjectKey(id string) string { return ProjectsPrefix + id + ".json" }

// Project is projects/<id>.json.
type Project struct {
	ID        string
	Name      string
	Owner     string
	MadeAt    Stamp
	Rev       int
	Removed   *bool
	RemovedAt *Stamp
	// Slots is the project's Tasks, Code review and CI (#2669), one per slot; a slot not
	// here is each folder's own.
	Slots []wire.ProjectSlot
	Extra Extra
}

type projectJSON struct {
	ID        string             `json:"id"`
	Name      string             `json:"name"`
	Owner     string             `json:"owner"`
	MadeAt    Stamp              `json:"madeAt"`
	Rev       int                `json:"rev,omitempty"`
	Removed   *bool              `json:"removed,omitempty"`
	RemovedAt *Stamp             `json:"removedAt,omitempty"`
	Slots     []wire.ProjectSlot `json:"slots,omitempty"`
}

func (p Project) MarshalJSON() ([]byte, error) {
	return encodeKeeping(projectJSON{p.ID, p.Name, p.Owner, p.MadeAt, p.Rev, p.Removed, p.RemovedAt, p.Slots}, p.Extra)
}

func (p *Project) UnmarshalJSON(data []byte) error {
	var j projectJSON
	extra, err := decodeKeeping(data, &j, "id", "name")
	if err != nil {
		return err
	}
	*p = Project{j.ID, j.Name, j.Owner, j.MadeAt, j.Rev, j.Removed, j.RemovedAt, j.Slots, extra}
	return nil
}

// IsRemoved says the project was removed: kept, so a folder that names it brings it back.
func (p *Project) IsRemoved() bool { return p.Removed != nil && *p.Removed }

func (r *Records) loadProjects(ctx context.Context) error {
	listed, err := r.Store.List(ctx, ProjectsPrefix)
	if err != nil {
		return err
	}
	r.mu.Lock()
	heldProjects := map[string]held[Project]{}
	for _, h := range r.projects {
		heldProjects[ProjectKey(h.record.ID)] = h
	}
	r.mu.Unlock()
	projects := map[string]held[Project]{}
	for _, entry := range listed {
		if h, ok := heldProjects[entry.Key]; ok && h.etag == entry.ETag {
			projects[h.record.ID] = h
			continue
		}
		object, ok := r.read(ctx, entry)
		if !ok || object == nil {
			if h, there := heldProjects[entry.Key]; there {
				projects[h.record.ID] = h
			}
			continue
		}
		var p Project
		if err := p.UnmarshalJSON(object.Data); err != nil || ProjectKey(p.ID) != entry.Key {
			r.noteUnreadable(entry.Key, object.ETag, "")
			continue
		}
		projects[p.ID] = held[Project]{p, object.ETag}
	}
	r.mu.Lock()
	r.projects = projects
	r.mu.Unlock()
	return nil
}

// Projects is every project not removed, by name.
func (r *Records) Projects() []Project {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := []Project{}
	for _, h := range r.projects {
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

// Project is the project of that id, or nil when there is none or it was removed.
func (r *Records) Project(id string) *Project {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h, ok := r.projects[id]; ok && !h.record.IsRemoved() {
		p := h.record
		return &p
	}
	return nil
}

// ProjectsOwnedBy is how many project records owner has, removed ones too: they are
// kept until the sweep deletes them (#2711).
func (r *Records) ProjectsOwnedBy(owner string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, h := range r.projects {
		if h.record.Owner == owner {
			n++
		}
	}
	return n
}

// ChangeProject changes one project under the write lock, after reading projects again,
// and writes it against the version read; a new one is written only if absent. change
// gets the project, removed ones too (nil for none), and returns what to write, or nil to
// write nothing.
func (r *Records) ChangeProject(ctx context.Context, id string, change func(*Project) (*Project, error)) (*Project, error) {
	r.writing.Lock()
	defer r.writing.Unlock()
	if err := r.loadProjects(ctx); err != nil {
		return nil, err
	}
	return r.changeProject(ctx, id, change)
}

// ChangeProjects is ChangeProject for each of ids, in their order, under one hold of the
// write lock and one read of projects (#2735): a machine's new ids are adopted together.
// It stops at the first error.
func (r *Records) ChangeProjects(ctx context.Context, ids []string, change func(id string, p *Project) (*Project, error)) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	if err := r.loadProjects(ctx); err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := r.changeProject(ctx, id, func(p *Project) (*Project, error) { return change(id, p) }); err != nil {
			return err
		}
	}
	return nil
}

// changeProject is ChangeProject with the write lock held and projects read.
func (r *Records) changeProject(ctx context.Context, id string, change func(*Project) (*Project, error)) (*Project, error) {
	r.mu.Lock()
	h, there := r.projects[id]
	r.mu.Unlock()
	var current *Project
	if there {
		p := h.record
		current = &p
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
	kept, etag, err := write(ctx, r.Store, *next, ProjectKey(next.ID), condition)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	r.projects[kept.ID] = held[Project]{kept, etag}
	r.mu.Unlock()
	return &kept, nil
}
