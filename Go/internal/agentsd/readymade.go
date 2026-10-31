package agentsd

import (
	"embed"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// Ready-made workflows (#1342, #1633) are copied to the person's workflow folder once.
// After that, the files belong to the person.

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

// removedReadyMadePath keeps the IDs of built-in workflows that the person deleted.
func removedReadyMadePath(home string) string {
	return filepath.Join(home, ".agents", "settings", "removed-workflows.json")
}

func markReadyMadeRemoved(home, id string) error {
	known := false
	for _, builtIn := range readyMadeIDs() {
		known = known || builtIn == id
	}
	if !known {
		return nil
	}
	path := removedReadyMadePath(home)
	var ids []string
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &ids)
	}
	for _, existing := range ids {
		if existing == id {
			return nil
		}
	}
	ids = append(ids, id)
	sort.Strings(ids)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(ids)
	if err != nil {
		return err
	}
	return store.WriteAtomically(path, data, 0o600)
}

// ensureReadyMadeUserWorkflowsLocked installs built-ins in the user's folder once. Existing
// files belong to the user. A removed ID stays removed after a restart or an update.
func (d *Daemon) ensureReadyMadeUserWorkflowsLocked() {
	home := d.personalHome()
	if home == "" || !ownFolders(home, workflowsRel) {
		return
	}
	var removed []string
	if data, err := os.ReadFile(removedReadyMadePath(home)); err == nil {
		_ = json.Unmarshal(data, &removed)
	}
	wasRemoved := map[string]bool{}
	for _, id := range removed {
		wasRemoved[id] = true
	}
	for _, id := range readyMadeIDs() {
		if wasRemoved[id] {
			continue
		}
		skillPath := filepath.Join(home, ".agents", "skills", id, "SKILL.md")
		if ownFolders(home, filepath.Join(".agents", "skills", id)) {
			if _, err := os.Lstat(skillPath); os.IsNotExist(err) {
				if os.MkdirAll(filepath.Dir(skillPath), 0o755) == nil {
					_, skill := readyMadeText(id)
					_ = store.WriteAtomically(skillPath, []byte(skill), 0o644)
				}
			}
		}
		path, ok := workflowPath(home, id)
		if !ok {
			continue
		}
		if _, err := os.Lstat(path); err == nil {
			continue
		} else if !os.IsNotExist(err) {
			continue
		}
		workflow, _ := readyMadeText(id)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			continue
		}
		if err := store.WriteAtomically(path, []byte(workflow), 0o644); err != nil {
			continue
		}
	}
}
