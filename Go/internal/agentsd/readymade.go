package agentsd

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ready-made workflows (#1342, #1633) are copied to the person's workflow folder once.
// After that, the files belong to the person, except that a copy the person did not edit
// takes a newer ready-made version (#4048).

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

func isReadyMade(id string) bool {
	_, err := readyMadeFS.ReadFile("readymade/" + id + "/workflow.md")
	return err == nil
}

// Ready-made skills with no workflow (#3307) are copied to the person's skills once, as a
// ready-made workflow's skill is: map-a-docs-server, which any agent follows when asked.
//
//go:embed readymadeskills
var readyMadeSkillsFS embed.FS

// readyMadeSkillIDs is every ready-made skill with no workflow, by id.
func readyMadeSkillIDs() []string {
	entries, _ := readyMadeSkillsFS.ReadDir("readymadeskills")
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

// ensureReadyMadeUserWorkflowsLocked installs built-ins in the user's folder once, and
// updates a copy the user did not edit; an edited copy belongs to the user. A removed ID
// stays removed after a restart or an update.
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
	for _, id := range readyMadeSkillIDs() {
		skillPath := filepath.Join(home, ".agents", "skills", id, "SKILL.md")
		if !ownFolders(home, filepath.Join(".agents", "skills", id)) {
			continue
		}
		if _, err := os.Lstat(skillPath); os.IsNotExist(err) && os.MkdirAll(filepath.Dir(skillPath), 0o755) == nil {
			skill, _ := readyMadeSkillsFS.ReadFile("readymadeskills/" + id + "/SKILL.md")
			_ = store.WriteAtomically(skillPath, skill, 0o644)
		}
	}
	made := madeReadyMade(home)
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
		workflow, _ := readyMadeText(id)
		if _, err := os.Lstat(path); err == nil {
			d.updateReadyMadeLocked(home, id, path, workflow, made[id])
			continue
		} else if !os.IsNotExist(err) {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			continue
		}
		if err := store.WriteAtomically(path, []byte(workflow), 0o644); err != nil {
			continue
		}
		if digest, ok := readyMadeDigest(workflow); ok {
			markReadyMadeMade(home, id, digest)
		}
	}
}

// The state keys the app writes into a workflow when the person turns it on or off,
// archives or mutes it: they are not an edit of the ready-made text.
var readyMadeStateKeys = []string{"enabled", "archived", "continue-when-back", "muted"}

// readyMadeDigest is the digest of a workflow's text without its state keys, so a copy the
// person only turned on or off is still unedited.
func readyMadeDigest(text string) (string, bool) {
	for _, key := range readyMadeStateKeys {
		var err error
		if text, err = setFrontMatter(key, nil, text); err != nil {
			return "", false
		}
	}
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:]), true
}

// earlierReadyMade is each ready-made workflow's earlier versions, by readyMadeDigest, and
// whether going from that version to today's widens what the workflow can do. A change to a
// ready-made workflow.md adds the version it replaces here, so that a copy made before the
// daemon kept digests is updated too. #3922's plan → ask keeps the folders read-only.
var earlierReadyMade = map[string]map[string]bool{
	"daily-summary": {"d39b71bc9d4ab7c2f5fa24dca8b72919dc7d0992f79e0ea964ebe93249262d42": false},
	"daily-checks":  {"0dff5345182c13cbf18da06086d57e03371baa9db9565b69f8d51ff3a4a3512e": false},
}

// readyMadeChange is what each ready-made workflow's version today changes, in a sentence: what
// an edited copy's page says the newer version does (#4071). A change to a ready-made
// workflow.md says it here, as it adds the version it replaces to earlierReadyMade.
var readyMadeChange = map[string]string{
	"daily-summary": "It runs in ask mode rather than plan mode, so a run no longer waits for your approval before it saves (#3922).",
	"daily-checks":  "It runs in ask mode rather than plan mode, so a run no longer waits for your approval before it saves (#3922).",
}

// updatedReadyMadePath keeps when the daemon last wrote a newer version over each unedited
// copy, by id, so its row and page can say so (#4071).
func updatedReadyMadePath(home string) string {
	return filepath.Join(home, ".agents", "settings", "ready-made-updated.json")
}

func markReadyMadeUpdated(home, id string, at time.Time) {
	updated := map[string]wire.Date{}
	if data, err := os.ReadFile(updatedReadyMadePath(home)); err == nil {
		_ = json.Unmarshal(data, &updated)
	}
	updated[id] = wire.DateOf(at)
	if data, err := json.Marshal(updated); err == nil {
		_ = store.WriteAtomically(updatedReadyMadePath(home), data, 0o600)
	}
}

// readyMadeNotice is what a ready-made copy's summary says about its newer versions (#4071):
// when the daemon updated an unedited copy, for 7 days, or, for a copy the person edited, what
// the newer version changes. Neither for a copy made before the daemon kept digests, whose
// version it does not know.
func readyMadeNotice(home, id, text string, now time.Time) (updatedAt *wire.Date, newer *string) {
	workflow, _ := readyMadeText(id)
	want, ok := readyMadeDigest(workflow)
	if workflow == "" || !ok {
		return nil, nil
	}
	have, ok := readyMadeDigest(text)
	if !ok {
		return nil, nil
	}
	if have == want {
		updated := map[string]wire.Date{}
		if data, err := os.ReadFile(updatedReadyMadePath(home)); err == nil {
			_ = json.Unmarshal(data, &updated)
		}
		if at, ok := updated[id]; ok && now.Sub(at.Time()) < 7*24*time.Hour {
			return &at, nil
		}
		return nil, nil
	}
	if made := madeReadyMade(home)[id]; made != "" && made != want {
		change := readyMadeChange[id]
		if change == "" {
			change = "Its ready-made version changed since this copy was made."
		}
		return nil, &change
	}
	return nil, nil
}

// madeReadyMadePath keeps the readyMadeDigest of each copy the daemon made, by id.
func madeReadyMadePath(home string) string {
	return filepath.Join(home, ".agents", "settings", "ready-made-workflows.json")
}

func madeReadyMade(home string) map[string]string {
	made := map[string]string{}
	if data, err := os.ReadFile(madeReadyMadePath(home)); err == nil {
		_ = json.Unmarshal(data, &made)
	}
	return made
}

func markReadyMadeMade(home, id, digest string) {
	made := madeReadyMade(home)
	if made[id] == digest {
		return
	}
	made[id] = digest
	data, err := json.Marshal(made)
	if err == nil && os.MkdirAll(filepath.Dir(madeReadyMadePath(home)), 0o755) == nil {
		_ = store.WriteAtomically(madeReadyMadePath(home), data, 0o600)
	}
}

// updateReadyMadeLocked writes today's ready-made version over a copy the person did not
// edit: one the same as the copy the daemon made, or as an earlier version. The copy keeps
// its state keys. Its approval goes with it when the step does not widen what it can do;
// otherwise the new version waits for the person as any changed workflow does.
func (d *Daemon) updateReadyMadeLocked(home, id, path, workflow, madeDigest string) {
	want, ok := readyMadeDigest(workflow)
	if !ok {
		return
	}
	old, oldFileDigest, why := readWorkflowFile(path)
	if why != "" {
		return
	}
	have, ok := readyMadeDigest(old)
	if !ok || have == want {
		return
	}
	widens, earlier := earlierReadyMade[id][have]
	if !earlier && have != madeDigest {
		return // the person's own edit
	}
	if !earlier {
		widens = true // made by the daemon, but no one said what the step does
	}
	oldWF := parseWorkflow(old, id, home)
	text := workflow
	for _, key := range readyMadeStateKeys {
		var v *bool
		switch key {
		case "enabled":
			v = oldWF.Enabled
		case "archived":
			v = oldWF.Archived
		case "continue-when-back":
			v = oldWF.ContinueWhenBack
		case "muted":
			v = oldWF.Muted
		}
		var value *string
		if v != nil {
			value = strPtr(strconv.FormatBool(*v))
		}
		var err error
		if text, err = setFrontMatter(key, value, text); err != nil {
			return
		}
	}
	oldSkills, _ := readWorkflowSkills(home, old)
	oldDigest := workflowDigest(oldFileDigest, old, oldSkills)
	if err := store.WriteAtomically(path, []byte(text), 0o644); err != nil {
		return
	}
	markReadyMadeMade(home, id, want)
	markReadyMadeUpdated(home, id, time.Now())
	log.Printf("workflows: updated the unedited ready-made %s to today's version", id)
	st := d.stateLocked(home, id, false)
	if widens || d.workflowRecsBad || st == nil {
		return
	}
	newText, newFileDigest, why := readWorkflowFile(path)
	skills, skillsWhy := readWorkflowSkills(home, newText)
	if why != "" || skillsWhy != "" {
		return
	}
	f := &workflowFile{text: newText, skills: skills, digest: workflowDigest(newFileDigest, newText, skills)}
	moved := false
	if st.ApprovedDigest != nil && *st.ApprovedDigest == oldDigest {
		d.keepCopyLocked(st, f)
		moved = true
	}
	if st.HeardDigest != nil && *st.HeardDigest == oldDigest {
		st.HeardDigest = &f.digest
		moved = true
	}
	if moved {
		d.saveRecordsLocked(false)
	}
}
