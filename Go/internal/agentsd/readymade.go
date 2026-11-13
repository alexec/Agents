package agentsd

import (
	"crypto/sha256"
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

// Ready-made workflows (#1342, #1633) are copied to the person's workflow folder once, from
// the copy of agentloops-dev/dotagents that dotagents.go fetched (#5091). After that, the files
// belong to the person, except that a copy the person did not edit takes a newer ready-made
// version (#4048), which waits for the person's approval as any changed workflow does.

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
	if !loadReadyMade(home).has(id) {
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
	set := d.readyMadeLocked(home)
	for _, id := range set.skillIDs() {
		skillPath := filepath.Join(home, ".agents", "skills", id, "SKILL.md")
		if !ownFolders(home, filepath.Join(".agents", "skills", id)) {
			continue
		}
		if _, err := os.Lstat(skillPath); os.IsNotExist(err) && os.MkdirAll(filepath.Dir(skillPath), 0o755) == nil {
			_ = store.WriteAtomically(skillPath, []byte(set.Skills[id]), 0o644)
		}
	}
	made := madeReadyMade(home)
	for _, id := range set.ids() {
		if wasRemoved[id] {
			continue
		}
		skillPath := filepath.Join(home, ".agents", "skills", id, "SKILL.md")
		if ownFolders(home, filepath.Join(".agents", "skills", id)) {
			if _, err := os.Lstat(skillPath); os.IsNotExist(err) {
				if os.MkdirAll(filepath.Dir(skillPath), 0o755) == nil {
					_, skill := set.text(id)
					_ = store.WriteAtomically(skillPath, []byte(skill), 0o644)
				}
			}
		}
		path, ok := workflowPath(home, id)
		if !ok {
			continue
		}
		workflow, _ := set.text(id)
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

// earlierReadyMade is each ready-made workflow's earlier versions, by readyMadeDigest: the
// versions made before the daemon kept the digest of the copy it made, so that such a copy is
// known to be unedited and is updated too. It is compiled in, never read from the repository,
// and it says only that a copy is unedited: an update never keeps the copy's approval (#5091).
var earlierReadyMade = map[string]map[string]bool{
	"daily-summary": {"d39b71bc9d4ab7c2f5fa24dca8b72919dc7d0992f79e0ea964ebe93249262d42": true},
	"daily-checks":  {"0dff5345182c13cbf18da06086d57e03371baa9db9565b69f8d51ff3a4a3512e": true},
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
// the newer version changes, until they take it or keep their copy (#4075). Neither for a copy made before the daemon kept digests, whose
// version it does not know.
func readyMadeNotice(home, id, text string, now time.Time) (updatedAt *wire.Date, newer *string) {
	workflow, _ := loadReadyMade(home).text(id)
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
	if made := madeReadyMade(home)[id]; made != "" && made != want && keptReadyMade(home)[id] != want {
		change := "Its ready-made version changed since this copy was made."
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

// withStateKeys is the ready-made workflow with the state keys of the copy it goes over.
func withStateKeys(old, workflow, id, home string) (string, error) {
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
			return "", err
		}
	}
	return text, nil
}

// keptReadyMadePath keeps, by id, the ready-made version whose notice the person hid by
// keeping their edited copy (#4075).
func keptReadyMadePath(home string) string {
	return filepath.Join(home, ".agents", "settings", "ready-made-kept.json")
}

func keptReadyMade(home string) map[string]string {
	kept := map[string]string{}
	if data, err := os.ReadFile(keptReadyMadePath(home)); err == nil {
		_ = json.Unmarshal(data, &kept)
	}
	return kept
}

// readyMadeCopyLocked is the edited copy of a ready-made workflow that workflows/readyMade/take
// and keep act on: a workflow of the person's own whose ready-made version is newer.
func (d *Daemon) readyMadeCopyLocked(r wire.WorkflowRequest) (home, path, text, want string, err error) {
	folder := store.FolderPath(r.Folder)
	d.scanLocked()
	f := d.fileLocked(folder, r.WorkflowID)
	home = d.personalHome()
	if f == nil {
		return "", "", "", "", noSuchWorkflow(r.WorkflowID)
	}
	set := loadReadyMade(home)
	if f.scope != "user" || home == "" || !set.has(r.WorkflowID) {
		return "", "", "", "", &Error{Code: wire.FailureNotChanged, Message: f.wf.Name + " is not a copy of a ready-made workflow."}
	}
	if _, newer := readyMadeNotice(home, r.WorkflowID, f.text, time.Now()); newer == nil {
		return "", "", "", "", &Error{Code: wire.FailureNotChanged, Message: f.wf.Name + " has no newer ready-made version."}
	}
	path, ok := workflowSourcePath(folder, r.WorkflowID, f)
	if !ok {
		return "", "", "", "", notInFolder(r.WorkflowID)
	}
	text, _ = set.text(r.WorkflowID)
	want, _ = readyMadeDigest(text)
	return home, path, text, want, nil
}

// takeReadyMade is workflows/readyMade/take (#4075): the newer ready-made version written over
// an edited copy, with the copy's state keys. Its approval does not go with it: the new version
// waits for the person as any changed workflow does.
func (d *Daemon) takeReadyMade(r wire.WorkflowRequest) (wire.WorkflowSummary, error) {
	d.workflowMu.Lock()
	home, path, workflow, want, err := d.readyMadeCopyLocked(r)
	if err == nil {
		old, _, why := readWorkflowFile(path)
		if why != "" {
			err = &Error{Code: wire.FailureWorkflowUnreadable, Message: why}
		} else if text, kerr := withStateKeys(old, workflow, r.WorkflowID, home); kerr != nil {
			err = &Error{Code: wire.FailureWorkflowUnreadable, Message: kerr.Error()}
		} else if werr := store.WriteAtomically(path, []byte(text), 0o644); werr != nil {
			err = &Error{Code: wire.FailureWorkflowUnreadable, Message: r.WorkflowID + ".md was not changed: " + werr.Error() + "."}
		} else {
			markReadyMadeMade(home, r.WorkflowID, want)
			log.Printf("workflows: took the newer ready-made %s over the edited copy", r.WorkflowID)
			d.scanLocked()
		}
	}
	d.workflowMu.Unlock()
	if err != nil {
		return wire.WorkflowSummary{}, err
	}
	d.tellEveryWorkflow()
	return d.oneWorkflow(store.FolderPath(r.Folder), r.WorkflowID)
}

// keepReadyMade is workflows/readyMade/keep (#4075): the edited copy stays as it is, and its
// page says no more of this ready-made version.
func (d *Daemon) keepReadyMade(r wire.WorkflowRequest) (wire.WorkflowSummary, error) {
	d.workflowMu.Lock()
	home, _, _, want, err := d.readyMadeCopyLocked(r)
	if err == nil {
		kept := keptReadyMade(home)
		kept[r.WorkflowID] = want
		if data, merr := json.Marshal(kept); merr == nil {
			if werr := store.WriteAtomically(keptReadyMadePath(home), data, 0o600); werr != nil {
				err = &Error{Code: wire.FailureWorkflowUnreadable, Message: "Could not save that you kept your copy: " + werr.Error()}
			}
		}
	}
	d.workflowMu.Unlock()
	if err != nil {
		return wire.WorkflowSummary{}, err
	}
	d.tellEveryWorkflow()
	return d.oneWorkflow(store.FolderPath(r.Folder), r.WorkflowID)
}

// updateReadyMadeLocked writes today's ready-made version over a copy the person did not
// edit: one the same as the copy the daemon made, or as an earlier version. The copy keeps
// its state keys, but not its approval: the new version came from the repository, so it waits
// for the person as any changed workflow does (#5091).
func (d *Daemon) updateReadyMadeLocked(home, id, path, workflow, madeDigest string) {
	want, ok := readyMadeDigest(workflow)
	if !ok {
		return
	}
	old, _, why := readWorkflowFile(path)
	if why != "" {
		return
	}
	have, ok := readyMadeDigest(old)
	if !ok || have == want {
		return
	}
	if !earlierReadyMade[id][have] && have != madeDigest {
		return // the person's own edit
	}
	text, err := withStateKeys(old, workflow, id, home)
	if err != nil {
		return
	}
	if err := store.WriteAtomically(path, []byte(text), 0o644); err != nil {
		return
	}
	markReadyMadeMade(home, id, want)
	markReadyMadeUpdated(home, id, time.Now())
	log.Printf("workflows: updated the unedited ready-made %s to the fetched version; it waits for approval", id)
}
