package agentsd

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/agentsd/yamlnode"
	"github.com/alexec/agents/Go/wire"
)

// The editor has a small, scoped file API. In particular, it never accepts an
// arbitrary host path from a client, as files/saveText does for Settings.
func (d *Daemon) registerAgentConfigEditor() {
	On(d, wire.CallAgentConfigEditorFiles, func(_ context.Context, _ *Client, r wire.AgentConfigEditorRequest) (wire.AgentConfigEditorFiles, error) {
		return d.agentConfigEditorFiles(r)
	})
	On(d, wire.CallAgentConfigEditorSave, func(_ context.Context, _ *Client, r wire.AgentConfigEditorSaveRequest) (wire.Empty, error) {
		return wire.Empty{}, d.saveAgentConfigEditorFile(r)
	})
}

func (d *Daemon) agentConfigEditorRoot(folder *wire.URL, kind string) (string, string, error) {
	if kind != "skills" && kind != "personas" && kind != "workflows" {
		return "", "", Invalid("Choose skills, personas or workflows.")
	}
	base := d.personalHome()
	if folder != nil {
		base = store.FolderPath(*folder)
		if !d.isFolderPath(base) {
			return "", "", Invalid("That project folder is not available on this host.")
		}
	} else if base == "" {
		return "", "", Invalid("Your agent configuration is not available on this host.")
	}
	base, err := store.Resolve(base)
	if err != nil {
		return "", "", Invalid("That folder is not available.")
	}
	root := filepath.Join(base, ".agents", kind)
	if !inside(base, resolved(root)) {
		return "", "", Invalid("The configuration folder must stay inside its project.")
	}
	return base, root, nil
}

func agentConfigEditorPath(root, name string) (string, error) {
	if name == "" || strings.HasPrefix(name, ".") || strings.Contains(name, "\\") || filepath.IsAbs(name) || filepath.Clean(name) != name || !strings.HasSuffix(name, ".md") {
		return "", Invalid("Choose a Markdown file inside this section.")
	}
	for _, part := range strings.Split(name, string(filepath.Separator)) {
		if part == "" || part == "." || part == ".." || strings.HasPrefix(part, ".") {
			return "", Invalid("Choose a Markdown file inside this section.")
		}
	}
	path := filepath.Join(root, name)
	if !inside(resolved(root), resolved(path)) {
		return "", Invalid("The file must stay inside this section.")
	}
	return path, nil
}

func (d *Daemon) agentConfigEditorFiles(r wire.AgentConfigEditorRequest) (wire.AgentConfigEditorFiles, error) {
	_, root, err := d.agentConfigEditorRoot(r.Folder, r.Kind)
	if err != nil {
		return nil, err
	}
	out := wire.AgentConfigEditorFiles{}
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if os.IsNotExist(walkErr) {
			return nil
		}
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if path != root && (strings.HasPrefix(entry.Name(), ".") || r.Kind != "skills") {
				return filepath.SkipDir
			}
			return nil
		}
		if !entry.Type().IsRegular() || !strings.HasSuffix(entry.Name(), ".md") {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if _, err = agentConfigEditorPath(root, rel); err != nil {
			return nil
		}
		info, err := entry.Info()
		if err != nil || info.Size() > 1<<20 {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		out = append(out, wire.AgentConfigEditorFile{Path: rel, Content: string(data)})
		return nil
	})
	if err != nil {
		return nil, fileError(CodeFileNotReadable, "Configuration files could not be opened.")
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, nil
}

func (d *Daemon) saveAgentConfigEditorFile(r wire.AgentConfigEditorSaveRequest) error {
	base, root, err := d.agentConfigEditorRoot(r.Folder, r.Kind)
	if err != nil {
		return err
	}
	path, err := agentConfigEditorPath(root, r.Path)
	if err != nil {
		return err
	}
	if len(r.Content) > 1<<20 {
		return Invalid("That file is more than 1 MB.")
	}
	remove := r.Delete != nil && *r.Delete
	if r.Kind != "skills" && filepath.Base(r.Path) != r.Path {
		return Invalid("Persona and workflow files must be directly in their section.")
	}
	if r.Kind == "workflows" {
		id := strings.TrimSuffix(r.Path, ".md")
		if remove {
			return d.deleteWorkflow(wire.WorkflowRequest{Folder: store.FolderURL(base), WorkflowID: id})
		}
		if r.Folder == nil {
			_, err = d.writeUserWorkflow(wire.WorkflowWriteRequest{WorkflowID: id, Content: r.Content})
		} else {
			_, err = d.writeWorkflow(base, id, r.Content)
		}
		return err
	}
	if remove {
		if r.Kind == "skills" && filepath.Base(path) == "SKILL.md" && filepath.Dir(filepath.Dir(path)) == root {
			name := filepath.Base(filepath.Dir(path))
			dest := wire.SkillDestination{Kind: wire.SkillDestinationKindPersonal}
			if r.Folder != nil {
				dest = wire.SkillDestination{Kind: wire.SkillDestinationKindFolder, Folder: &base}
			}
			place, err := d.skillPlace(dest)
			if err != nil {
				return catalogRefusal(err)
			}
			lock, err := skillcatalog.LoadLock(place.LockKind, place.Lock)
			if err != nil {
				return catalogRefusal(err)
			}
			if _, _, managed := place.ManagedEntry(name, lock); managed {
				_, err = d.skillInstaller().Remove(name, place, nowFunc())
			} else {
				_, err = skillcatalog.Trash(filepath.Dir(path), place.Trash, nowFunc())
			}
			if err != nil {
				return fileError(CodeFileNotReadable, "The skill could not be removed.")
			}
			return nil
		}
		if err := os.Remove(path); err != nil {
			return fileError(CodeFileNotReadable, "The file could not be deleted.")
		}
		return nil
	}
	if strings.TrimSpace(r.Content) == "" {
		return Invalid("Enter the file content before saving.")
	}
	if err := unreadableFrontMatter(r.Kind, r.Path, r.Content); err != nil {
		return err
	}
	// The person's own save of a skill keeps each user workflow that names it approved,
	// when it was approved as it stood.
	if r.Kind == "skills" && r.Folder == nil {
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		d.scanLocked()
		approved := d.approvedUserWorkflowsLocked()
		defer func() {
			d.scanLocked()
			d.reapproveUserWorkflowsLocked(approved)
		}()
	}
	if err := store.WriteAtomically(path, []byte(r.Content), 0o644); err != nil {
		return fileError(CodeFileNotReadable, "The file could not be saved: "+err.Error())
	}
	return nil
}

// unreadableFrontMatter refuses a persona or a skill whose front matter cannot be read, as
// writeWorkflow refuses a workflow (#2762): saved, it would show its problem only later,
// on the new-session form or to the runtime. A skill's other Markdown files are its own.
func unreadableFrontMatter(kind, path, content string) error {
	var problem *string
	switch {
	case kind == "personas":
		problem = parsePersona(content, strings.TrimSuffix(filepath.Base(path), ".md"), "folder").Problem
	case kind == "skills" && filepath.Base(path) == "SKILL.md":
		problem = frontMatterProblem(content)
	}
	if problem == nil {
		return nil
	}
	return Invalid("That front matter could not be read: %s. Nothing was saved.", strings.TrimSuffix(*problem, "."))
}

// frontMatterProblem is why a file's front matter, the block between its first two ---
// lines, is not a YAML mapping; nil when it is one, or when the file has none.
func frontMatterProblem(text string) *string {
	lines := strings.Split(text, "\n")
	if strings.TrimSpace(lines[0]) != "---" {
		return nil
	}
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) != "---" {
			continue
		}
		_, err := yamlnode.MappingFrom(lines[1:i])
		if err == nil {
			return nil
		}
		problem := "The metadata could not be read"
		if f, ok := err.(*yamlnode.Failure); ok {
			problem = f.Message
		}
		return &problem
	}
	problem := "The metadata block is never closed"
	return &problem
}
