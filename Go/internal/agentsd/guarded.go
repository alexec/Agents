package agentsd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The app's own files in a folder (#502, #531), as DaemonCore+GuardedFiles keeps them:
// .agents/folder.json and .agents/pins.json. A change made outside the app while an
// agent works there, or by a pull, waits for the person to keep or undo it, and the app
// goes on using the copy last approved, kept in <root>/guarded-files.json.

var guardedFiles = map[string]string{".agents/folder.json": "the helper limits, disk space lines and cost on pull requests",
	".agents/pins.json": "the pins", folderPolicyFile: "the folder's own policy layer"}

// folderPolicyFile is .agents/policy.json (#2957, FR-014, policyfolder.go): a folder's own
// layer, committed with the folder's code. Its guard is checkFolderPolicyGuarded
// (policyfolder.go), not checkGuarded's own switch below: a tighter-only change applies at
// once (research R10), which does not depend on whether an agent is working there.
const folderPolicyFile = ".agents/policy.json"

type guardedPending struct {
	Digest       *string     `json:"digest,omitempty"`
	Since        wire.Date   `json:"since"`
	ChangedByIDs []wire.UUID `json:"changedByIDs"`
	ChangedBy    []string    `json:"changedBy"`
	ByGit        bool        `json:"byGit"`
}

type guardedState struct {
	Folder          wire.URL        `json:"folder"`
	Path            string          `json:"path"`
	ApprovedDigest  *string         `json:"approvedDigest,omitempty"`
	ApprovedContent []byte          `json:"approvedContent,omitempty"`
	Pending         *guardedPending `json:"pending,omitempty"`
}

type guardedRecords struct {
	ApprovalsBegan *wire.Date     `json:"approvalsBegan,omitempty"`
	States         []guardedState `json:"states"`
}

type guardedStateHolder struct {
	guardedMu sync.Mutex
	guarded   *guardedRecords
}

func (d *Daemon) guardedFile() string { return filepath.Join(d.Store.Loc.Root, "guarded-files.json") }

// records is guarded-files.json, read once. Called with guardedMu held.
func (d *Daemon) guardedRecs() *guardedRecords {
	if d.guarded == nil {
		d.guarded = &guardedRecords{}
		if b, err := os.ReadFile(d.guardedFile()); err == nil {
			diskjson.Unmarshal(b, d.guarded)
		}
		// A file the app no longer keeps (.agents/project.json before #2617) cannot be
		// kept or undone, so its record goes (#2680).
		kept := d.guarded.States[:0]
		for _, s := range d.guarded.States {
			if _, ok := guardedFiles[s.Path]; ok {
				kept = append(kept, s)
			}
		}
		d.guarded.States = kept
	}
	return d.guarded
}

func (d *Daemon) saveGuarded() {
	r := d.guardedRecs()
	if r.ApprovalsBegan == nil {
		t := now()
		r.ApprovalsBegan = &t
	}
	var kept []guardedState
	for _, s := range r.States {
		if s.Pending != nil || isDir(store.FolderPath(s.Folder)) {
			kept = append(kept, s)
		}
	}
	r.States = kept
	if r.States == nil {
		r.States = []guardedState{}
	}
	if b, err := diskjson.Marshal(r); err == nil {
		store.WriteAtomically(d.guardedFile(), b, 0o644)
	}
}

func (d *Daemon) stateOf(folder, path string) (*guardedState, bool) {
	r := d.guardedRecs()
	for i := range r.States {
		if store.FolderPath(r.States[i].Folder) == folder && r.States[i].Path == path {
			return &r.States[i], true
		}
	}
	r.States = append(r.States, guardedState{Folder: store.FolderURL(folder), Path: path})
	return &r.States[len(r.States)-1], false
}

// diskRead is the file's digest and bytes, a nil digest for no file.
func diskRead(folder, path string) (*string, []byte) {
	if !ownFolders(folder, filepath.Dir(path)) {
		return nil, nil
	}
	b, err := os.ReadFile(filepath.Join(folder, path))
	if err != nil {
		return nil, nil
	}
	sum := sha256.Sum256(b)
	h := hex.EncodeToString(sum[:])
	return &h, b
}

func same(a, b *string) bool { return (a == nil && b == nil) || (a != nil && b != nil && *a == *b) }

func inRepository(folder string) bool {
	for p := folder; ; p = filepath.Dir(p) {
		if _, err := os.Stat(filepath.Join(p, ".git")); err == nil {
			return true
		}
		if p == "/" || p == "." {
			return false
		}
	}
}

// checkGuarded is DaemonCore.checkGuardedFiles for one file: first seen, it is approved as
// it stands; put back, its change is cleared; changed while an agent works there, or by a
// pull, it waits; changed by the person with nothing running, it is approved. ended is
// the agent whose turn just ended, if any.
func (d *Daemon) checkGuarded(folder, path string, ended *wire.UUID) {
	if path == folderPolicyFile {
		d.checkFolderPolicyGuarded(folder)
		return
	}
	digest, data := diskRead(folder, path)
	d.guardedMu.Lock()
	s, known := d.stateOf(folder, path)
	moved := false
	switch {
	case !known:
		s.ApprovedDigest, s.ApprovedContent, moved = digest, data, true
	case same(s.ApprovedDigest, digest):
		if s.Pending != nil {
			s.Pending, moved = nil, true
		}
	case s.Pending != nil && same(s.Pending.Digest, digest):
	default:
		var working []wire.Agent
		for _, a := range d.agentsOf(folder) {
			if a.State == wire.AgentStateRunning || a.State == wire.AgentStateWaitingOnUser || (ended != nil && a.ID == *ended) {
				working = append(working, a)
			}
		}
		switch {
		case len(working) > 0:
			if s.Pending == nil {
				s.Pending = &guardedPending{Since: now(), ChangedByIDs: []wire.UUID{}, ChangedBy: []string{}}
			}
			for _, a := range working {
				known := false
				for _, id := range s.Pending.ChangedByIDs {
					known = known || id == a.ID
				}
				if !known {
					s.Pending.ChangedByIDs = append(s.Pending.ChangedByIDs, a.ID)
					title := "An agent"
					if a.Title != nil {
						title = *a.Title
					}
					s.Pending.ChangedBy = append(s.Pending.ChangedBy, title)
				}
			}
			s.Pending.Digest = digest
		case !inRepository(folder):
			s.ApprovedDigest, s.ApprovedContent, s.Pending = digest, data, nil // the person's own edit
		default:
			// With nothing running: a pull's, when it is what HEAD has.
			head, err := gitRaw(folder, nil, "show", "HEAD:./"+path)
			if err == nil && bytes.Equal(head, data) {
				s.Pending = &guardedPending{Digest: digest, Since: now(), ByGit: true, ChangedByIDs: []wire.UUID{}, ChangedBy: []string{}}
			} else {
				s.ApprovedDigest, s.ApprovedContent, s.Pending = digest, data, nil
			}
		}
		moved = true
	}
	if moved {
		d.saveGuarded()
	}
	d.guardedMu.Unlock()
	if moved && known {
		d.guardedFilesMoved(folder)
	}
}

func (d *Daemon) guardedFilesMoved(folder string) {
	d.sendFolder(folder)
	d.pinsChanged(folder)
}

// guardedContent is what the app uses of a file: the approved copy while a change waits.
func (d *Daemon) guardedContent(folder, path string) ([]byte, bool) {
	d.checkGuarded(folder, path, nil)
	d.guardedMu.Lock()
	defer d.guardedMu.Unlock()
	s, _ := d.stateOf(folder, path)
	if s.Pending != nil {
		return s.ApprovedContent, s.ApprovedDigest != nil
	}
	_, data := diskRead(folder, path)
	return data, data != nil
}

// settled is whether the app may write the file: nothing waits, and it is as approved.
func (d *Daemon) settled(folder, path string) bool {
	d.checkGuarded(folder, path, nil)
	digest, _ := diskRead(folder, path)
	d.guardedMu.Lock()
	defer d.guardedMu.Unlock()
	s, _ := d.stateOf(folder, path)
	return s.Pending == nil && same(s.ApprovedDigest, digest)
}

func guardedRefusal(path, lead string) error {
	return Invalid("%s%s was changed outside the app and is waiting for the person to keep or undo the change in Folder Settings.", lead, path)
}

// approveWrite records the app's own write as approved.
func (d *Daemon) approveWrite(folder, path string) {
	digest, data := diskRead(folder, path)
	d.guardedMu.Lock()
	s, _ := d.stateOf(folder, path)
	s.ApprovedDigest, s.ApprovedContent, s.Pending = digest, data, nil
	d.saveGuarded()
	d.guardedMu.Unlock()
}

// guardedTurnEnded checks a folder's files as a turn there ends.
func (d *Daemon) guardedTurnEnded(id wire.UUID) {
	a := d.Store.Agent(id)
	if a == nil {
		return
	}
	folder := folderPath(a)
	for path := range guardedFiles {
		d.checkGuarded(folder, path, &id)
	}
}

// guardedChanges is a summary's: the changes waiting in a folder, by path, then the
// workflows waiting for an OK (#569, #1322).
func (d *Daemon) guardedChanges(folder string) []wire.GuardedChange {
	return append(d.guardedFileChanges(folder), d.waitingWorkflowChanges(folder)...)
}

// guardedFileChanges is the guarded files' changes waiting in a folder, by path.
func (d *Daemon) guardedFileChanges(folder string) []wire.GuardedChange {
	d.guardedMu.Lock()
	defer d.guardedMu.Unlock()
	var out []wire.GuardedChange
	for _, s := range d.guardedRecs().States {
		if s.Pending == nil || store.FolderPath(s.Folder) != folder {
			continue
		}
		c := wire.GuardedChange{Path: s.Path, Digest: s.Pending.Digest, ChangedBy: s.Pending.ChangedBy,
			ChangedByIDs: s.Pending.ChangedByIDs, ByGit: s.Pending.ByGit, Since: s.Pending.Since}
		for _, id := range s.Pending.ChangedByIDs {
			if a := d.Store.Agent(id); a != nil && a.State != wire.AgentStateArchived {
				asked := id
				c.AskedIn = &asked
				break
			}
		}
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

func guardedNames(names []string) string {
	switch len(names) {
	case 0:
		return ""
	case 1:
		return names[0]
	case 2:
		return names[0] + " and " + names[1]
	}
	return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
}

func guardedHeadline(c wire.GuardedChange) string {
	what := "changed " + c.Path
	if c.Digest == nil {
		what = "removed " + c.Path
	}
	switch {
	case len(c.ChangedBy) > 0:
		return guardedNames(c.ChangedBy) + " " + what
	case c.ByGit:
		return "A merge or pull " + what
	}
	return "Something outside the app " + what
}

// fileApproval is the approval a waiting change is (DaemonCore+Approvals).
func fileApproval(c wire.GuardedChange) wire.Approval {
	since := c.Since
	a := wire.Approval{Kind: wire.ApprovalKindFile, Key: c.Path, Title: c.Path, Digest: c.Digest, Since: &since,
		Actions: []wire.ApprovalAction{wire.ApprovalActionApprove, wire.ApprovalActionDeny}, AgentID: c.AskedIn}
	if c.AskedIn != nil {
		a.Actions = append(a.Actions, wire.ApprovalActionRequestChanges)
	}
	who := ""
	if len(c.ChangedBy) > 0 {
		who = guardedNames(c.ChangedBy)
	}
	switch {
	case c.Digest == nil && who != "":
		a.Line = "Removed by " + who
	case c.Digest == nil && c.ByGit:
		a.Line = "Removed by the last pull"
	case c.Digest == nil:
		a.Line = "Removed outside the app"
	case who != "":
		a.Line = "Changed by " + who
	case c.ByGit:
		a.Line = "Changed with the last pull"
	default:
		a.Line = "Changed since you approved it"
	}
	return a
}

// diffLines is GuardedDiffLine.lines: a line diff, 400 lines at most.
func diffLines(old, new string) []wire.GuardedDiffLine {
	split := func(t string) []string {
		l := strings.Split(t, "\n")
		if l[len(l)-1] == "" {
			l = l[:len(l)-1]
		}
		return l
	}
	a, b := split(old), split(new)
	// The longest common subsequence, then removed and added around it.
	lcs := make([][]int, len(a)+1)
	for i := range lcs {
		lcs[i] = make([]int, len(b)+1)
	}
	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else {
				lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
			}
		}
	}
	out := []wire.GuardedDiffLine{}
	i, j := 0, 0
	for (i < len(a) || j < len(b)) && len(out) < 400 {
		switch {
		case i < len(a) && j < len(b) && a[i] == b[j]:
			out = append(out, wire.GuardedDiffLine{Kind: wire.GuardedDiffLineKindSame, Text: a[i]})
			i, j = i+1, j+1
		case i < len(a) && (j >= len(b) || lcs[i+1][j] >= lcs[i][j+1]):
			out = append(out, wire.GuardedDiffLine{Kind: wire.GuardedDiffLineKindRemoved, Text: a[i]})
			i++
		default:
			out = append(out, wire.GuardedDiffLine{Kind: wire.GuardedDiffLineKindAdded, Text: b[j]})
			j++
		}
	}
	return out
}

func (d *Daemon) readGuardedChange(r wire.GuardedChangeRequest) (wire.GuardedChangeReading, error) {
	folder := store.FolderPath(r.Folder)
	if _, ok := d.summaryFor(folder); !ok {
		return wire.GuardedChangeReading{}, noSuchFolder(folder + " is not a folder.")
	}
	if id, ok := workflowIDInPath(r.Path); ok {
		return d.readWorkflowChange(folder, id)
	}
	if _, ok := guardedFiles[r.Path]; !ok {
		return wire.GuardedChangeReading{}, Invalid("%s is not a file the app keeps.", r.Path)
	}
	digest, data := diskRead(folder, r.Path)
	d.guardedMu.Lock()
	s, _ := d.stateOf(folder, r.Path)
	approved := s.ApprovedContent
	hasApproved := s.ApprovedDigest != nil
	d.guardedMu.Unlock()
	out := wire.GuardedChangeReading{Path: r.Path, Digest: digest}
	if hasApproved {
		t := string(approved)
		out.Approved = &t
	}
	if digest != nil {
		t := string(data)
		out.Current = &t
	}
	a, c := "", ""
	if out.Approved != nil {
		a = *out.Approved
	}
	if out.Current != nil {
		c = *out.Current
	}
	out.Lines = diffLines(a, c)
	return out, nil
}

// keepOrUndo is folders/keepGuardedChange and folders/undoGuardedChange.
func (d *Daemon) keepOrUndo(r wire.GuardedChangeRequest, keep bool) (wire.FolderSummary, error) {
	folder := store.FolderPath(r.Folder)
	if _, ok := d.summaryFor(folder); !ok {
		return wire.FolderSummary{}, noSuchFolder(folder + " is not a folder.")
	}
	if id, ok := workflowIDInPath(r.Path); ok {
		return d.keepOrUndoWorkflow(folder, id, r.Digest, keep)
	}
	if _, ok := guardedFiles[r.Path]; !ok {
		return wire.FolderSummary{}, Invalid("%s is not a file the app keeps.", r.Path)
	}
	digest, _ := diskRead(folder, r.Path)
	verb := "undone"
	if keep {
		verb = "kept"
	}
	if !same(digest, r.Digest) {
		return wire.FolderSummary{}, &Error{Code: wire.FailureNotChanged, Message: r.Path + " changed again after you looked at it, so it was not " + verb + ". Look again."}
	}
	if !keep {
		d.guardedMu.Lock()
		s, _ := d.stateOf(folder, r.Path)
		content, had := s.ApprovedContent, s.ApprovedDigest != nil
		d.guardedMu.Unlock()
		path := filepath.Join(folder, r.Path)
		var err error
		if !ownFolders(folder, filepath.Dir(r.Path)) {
			err = linkedFolder(filepath.Dir(r.Path), folder)
		} else if had {
			os.MkdirAll(filepath.Dir(path), 0o755)
			err = store.WriteAtomically(path, content, 0o644)
		} else if err = os.Remove(path); errors.Is(err, os.ErrNotExist) {
			err = nil
		}
		if err != nil {
			return wire.FolderSummary{}, &Error{Code: CodeInternal, Message: r.Path + " could not be put back: " + err.Error()}
		}
	}
	d.approveWrite(folder, r.Path)
	d.guardedFilesMoved(folder)
	s, _ := d.summaryFor(folder)
	return s, nil
}

func (d *Daemon) registerGuarded() {
	On(d, wire.CallFoldersReadGuardedChange, func(ctx context.Context, c *Client, r wire.GuardedChangeRequest) (wire.GuardedChangeReading, error) {
		return d.readGuardedChange(r)
	})
	On(d, wire.CallFoldersKeepGuardedChange, func(ctx context.Context, c *Client, r wire.GuardedChangeRequest) (wire.FolderSummary, error) {
		return d.keepOrUndo(r, true)
	})
	On(d, wire.CallFoldersUndoGuardedChange, func(ctx context.Context, c *Client, r wire.GuardedChangeRequest) (wire.FolderSummary, error) {
		return d.keepOrUndo(r, false)
	})
	On(d, wire.CallApprovalsRead, func(ctx context.Context, c *Client, r wire.ApprovalReadRequest) (wire.GuardedChangeReading, error) {
		switch r.Kind {
		case wire.ApprovalKindFile:
			return d.readGuardedChange(wire.GuardedChangeRequest{Folder: r.Folder, Path: r.Key})
		case wire.ApprovalKindWorkflow:
			return d.readGuardedChange(wire.GuardedChangeRequest{Folder: r.Folder, Path: workflowChangePath(r.Key)})
		case wire.ApprovalKindArchive:
			return wire.GuardedChangeReading{}, Invalid("An archive request has nothing to read: open the session.")
		case wire.ApprovalKindWorkflowFailed:
			return wire.GuardedChangeReading{}, Invalid("A failed workflow has nothing to read: open the workflow.")
		}
		return wire.GuardedChangeReading{}, Invalid("There is no such approval here.")
	})
	On(d, wire.CallApprovalsAnswer, func(ctx context.Context, c *Client, r wire.ApprovalAnswer) (wire.FolderSummary, error) {
		return d.answerApproval(r)
	})
}

// answerApproval is approvals/answer for what this host asks: a file's change, a workflow
// waiting for an OK, a session asking to be archived, and a workflow that failed (#989).
func (d *Daemon) answerApproval(r wire.ApprovalAnswer) (wire.FolderSummary, error) {
	folder := store.FolderPath(r.Folder)
	// A failed workflow takes Dismiss and nothing else; nothing else takes Dismiss.
	if failed := r.Kind == wire.ApprovalKindWorkflowFailed; failed != (r.Action == wire.ApprovalActionDismiss) {
		if failed {
			return wire.FolderSummary{}, Invalid("A failed workflow can only be dismissed.")
		}
		return wire.FolderSummary{}, Invalid("Only a failed workflow can be dismissed.")
	}
	switch r.Kind {
	case wire.ApprovalKindWorkflowFailed:
		return d.dismissWorkflowFailure(folder, r.Key, r.Digest)
	case wire.ApprovalKindFile:
		if r.Action == wire.ApprovalActionRequestChanges {
			if r.Note == nil || strings.TrimSpace(*r.Note) == "" {
				return wire.FolderSummary{}, Invalid("Say what to change.")
			}
			var asked *wire.UUID
			for _, ch := range d.guardedChanges(folder) {
				if ch.Path == r.Key {
					asked = ch.AskedIn
				}
			}
			if asked == nil {
				return wire.FolderSummary{}, Invalid("No agent made this change, so there is nobody to ask. Approve or deny it.")
			}
			text := "Before approving your change to " + r.Key + ", I'd like changes:\n\n" + strings.TrimSpace(*r.Note) +
				"\n\nIt stays waiting for approval; your next version of it asks again."
			if err := d.prompt(wire.PromptRequest{AgentID: *asked, Text: text, From: wire.PromptOriginPerson}); err != nil {
				return wire.FolderSummary{}, err
			}
			s, _ := d.summaryFor(folder)
			return s, nil
		}
		return d.keepOrUndo(wire.GuardedChangeRequest{Folder: r.Folder, Path: r.Key, Digest: r.Digest}, r.Action == wire.ApprovalActionApprove)
	case wire.ApprovalKindWorkflow:
		if r.Action == wire.ApprovalActionRequestChanges {
			return wire.FolderSummary{}, Invalid("No agent made this change, so there is nobody to ask. Approve or deny it.")
		}
		if _, ok := d.summaryFor(folder); !ok {
			return wire.FolderSummary{}, noSuchFolder(folder + " is not a folder.")
		}
		return d.answerWorkflow(folder, r.Key, r.Digest, r.Action == wire.ApprovalActionApprove)
	case wire.ApprovalKindArchive:
		id := wire.UUID(strings.ToUpper(r.Key))
		a := d.Store.Agent(id)
		if a == nil || a.ArchiveRequest == nil {
			return wire.FolderSummary{}, Invalid("That session is not asking to be archived any more.")
		}
		if r.Action == wire.ApprovalActionApprove {
			d.archive(id)
		} else {
			d.change(id, func(a *wire.Agent) { a.ArchiveRequest = nil })
		}
		return d.sendFolder(folder)
	}
	return wire.FolderSummary{}, Invalid("There is no such approval here.")
}
