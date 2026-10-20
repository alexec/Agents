package agentsd

import (
	"embed"
	"os"
	"path/filepath"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ready-made workflows (#1342): Agents' own workflows for the dev loop on GitHub, and on
// GitLab too (#1633): one workflow for both forges, its skill using the server the event
// came from. Each is readymade/<id>/workflow.md, short, and the method in
// readymade/<id>/SKILL.md (#1563). A project that pushes to GitHub or GitLab lists each one
// that it has no file for, off. Nothing is
// written until a person (or an agent) turns one on or changes it: then the workflow goes
// to .agents/workflows/<id>.md and its skill to .agents/skills/<id>/SKILL.md, and from
// then on it is the project's own file.

//go:embed readymade
var readyMadeFS embed.FS

// readyMadeIDs is every ready-made workflow, by id.
func readyMadeIDs() []string {
	entries, _ := readyMadeFS.ReadDir("readymade")
	var ids []string
	for _, e := range entries {
		if e.IsDir() {
			ids = append(ids, e.Name())
		}
	}
	return ids
}

func readyMadeText(id string) (workflow, skill string) {
	w, _ := readyMadeFS.ReadFile("readymade/" + id + "/workflow.md")
	s, _ := readyMadeFS.ReadFile("readymade/" + id + "/SKILL.md")
	return string(w), string(s)
}

// pushesToForge is whether a folder's git config names a GitHub or GitLab remote: github.com,
// or a host with gitlab in its name. It reads the config, never runs git: the scan that asks
// runs often.
func pushesToForge(folder string) bool {
	gitDir := filepath.Join(folder, ".git")
	if fi, err := os.Stat(gitDir); err != nil {
		return false
	} else if !fi.IsDir() {
		// A worktree: .git says where its git folder is, and that says where the shared one is.
		b, err := os.ReadFile(gitDir)
		line, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir: ")
		if err != nil || !ok {
			return false
		}
		if !filepath.IsAbs(line) {
			line = filepath.Join(folder, line)
		}
		gitDir = line
		if c, err := os.ReadFile(filepath.Join(gitDir, "commondir")); err == nil {
			common := strings.TrimSpace(string(c))
			if !filepath.IsAbs(common) {
				common = filepath.Join(gitDir, common)
			}
			gitDir = common
		}
	}
	b, err := os.ReadFile(filepath.Join(gitDir, "config"))
	if err != nil {
		return false
	}
	for _, l := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(l), "="); ok && strings.TrimSpace(k) == "url" &&
			(strings.Contains(strings.TrimSpace(v), "github.com") || strings.Contains(strings.ToLower(v), "gitlab")) {
			return true
		}
	}
	return false
}

// addReadyMadeLocked lists the ready-made workflows that a folder has no file for.
func (d *Daemon) addReadyMadeLocked(folder string, files map[string]map[string]*workflowFile) {
	if !pushesToForge(folder) || folder == d.chatFolder() || !ownFolders(folder, workflowsRel) {
		return
	}
	for _, id := range readyMadeIDs() {
		if files[folder][id] != nil {
			continue
		}
		if files[folder] == nil {
			files[folder] = map[string]*workflowFile{}
		}
		text, _ := readyMadeText(id)
		files[folder][id] = &workflowFile{wf: parseWorkflow(text, id, folder), text: text, readyMade: true}
	}
}

// writeReadyMadeLocked writes a ready-made workflow into its project, before the first
// change to it. A person's change approves it at once: it is Agents' own text, and the
// person chose it. An agent's waits for the person, as any file an agent writes does.
// A skill of the same name that the project has already is kept, and since it is not
// Agents' own text, the workflow with it waits for the person too (S20261019-2).
func (d *Daemon) writeReadyMadeLocked(folder, id string, byPerson bool) error {
	path, ok := workflowPath(folder, id)
	if !ok {
		return notInFolder(id)
	}
	workflow, skill := readyMadeText(id)
	skillPath := filepath.Join(folder, ".agents", "skills", id, "SKILL.md")
	if _, err := os.Lstat(skillPath); os.IsNotExist(err) && ownFolders(folder, filepath.Join(".agents", "skills", id)) {
		os.MkdirAll(filepath.Dir(skillPath), 0o755)
		if err := store.WriteAtomically(skillPath, []byte(skill), 0o644); err != nil {
			return &Error{Code: wire.FailureCouldNotSave, Message: id + "'s skill was not written: " + err.Error() + "."}
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return &Error{Code: wire.FailureCouldNotSave, Message: id + ".md was not written: " + err.Error() + "."}
	}
	if err := store.WriteAtomically(path, []byte(workflow), 0o644); err != nil {
		return &Error{Code: wire.FailureCouldNotSave, Message: id + ".md was not written: " + err.Error() + "."}
	}
	d.scanLocked()
	if f := d.fileLocked(folder, id); byPerson && f != nil && !f.readyMade && f.digest != "" && onlyOwnSkill(f, id, skill) {
		d.keepCopyLocked(d.stateLocked(folder, id, true), f)
		d.saveRecordsLocked(false)
	}
	return nil
}

// onlyOwnSkill is whether the skills a ready-made workflow names are its own, as written.
func onlyOwnSkill(f *workflowFile, id, skill string) bool {
	for _, s := range f.skills {
		if s.name != id || s.text != skill {
			return false
		}
	}
	return true
}
