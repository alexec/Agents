package agentsd

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Moving an agent into a worktree, or back to its folder, during its life (053),
// as DaemonCore+Moves did (#617, #1821). move_worktree asks for it; the move waits on the
// record, as pendingMove, for the turn to end, since a runtime cannot change folder while
// it works. Then the runtime is let go, the agent's folder is written, and the next turn
// starts a runtime in the new folder that picks the conversation back up there.

// movesFolders is RuntimeCatalog.canMoveFolders: the runtimes that carry a conversation
// into another folder (053 research R3).
var movesFolders = map[string]bool{"claude": true, "copilot": true, "cursor": true, "codex": true}

// runtimeCanMove is whether a runtime carries its conversation into another folder.
func runtimeCanMove(id string) bool { return movesFolders[id] }

// whyCannotMove is RuntimeCatalog.whyCannotMoveFolders.
func whyCannotMove(id string) string {
	name := id
	if rt := runtimeByID(id); rt != nil {
		name = rt.Name
	}
	return name + " can't carry its conversation into another folder, so this agent stays where it is. Start a new one in a worktree instead."
}

// carryOn ends what the app says to an agent it has just moved, as the prompt that starts it
// again, after the move's preface (#2407).
const carryOn = "Carry on with what you were doing."

// moveWorktree is move_worktree: a move asked for now, made when this turn ends. Neither
// argument takes back the move asked for earlier in the turn.
func (d *Daemon) moveWorktree(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	a := d.Store.Agent(caller)
	if a == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was moved."}
	}
	move, err := moveCall(args)
	if err != nil {
		return "", err
	}
	if move == nil {
		if a.PendingMove == nil || a.PendingMove.AskedBy != wire.MoveAskerAgent {
			return "No move of yours was waiting; you stay where you are.", nil
		}
		d.change(caller, func(a *wire.Agent) { a.PendingMove = nil })
		d.record(caller, runtimeNote("Move cancelled."))
		return "Move cancelled; you stay where you are.", nil
	}
	// A move starts the agent again somewhere else, so it goes with no wait (#481).
	if w := a.EventWait; w != nil && w.Ending == nil {
		return "", Invalid("Nothing was moved: you are waiting for %s, and a move starts you again in the new folder rather than waiting. Call cancel_wait first.", waitLabel(w))
	}
	if a.AfterTurn != nil && *a.AfterTurn == wire.AfterTurnArchive {
		return "", Invalid("Nothing was moved: you asked to be archived once this turn ends, and a run that moves is not archived. Call archive_session with no id instead, or do not move.")
	}
	move.AskedBy, move.AskedAt = wire.MoveAskerAgent, now()
	return d.askMove(caller, *move)
}

// moveCall is AppService.moveCall: the move a move_worktree call asks for, nil for none.
func moveCall(args map[string]json.RawMessage) (*wire.PendingMove, error) {
	worktree := strings.TrimSpace(argString(args, "worktree"))
	leaving := strings.TrimSpace(argString(args, "leave_worktree"))
	var discard bool
	json.Unmarshal(args["discard_changes"], &discard)
	onlyRemove := Invalid("Nothing was recorded: discard_changes only goes with leave_worktree remove.")
	switch {
	case worktree != "" && leaving != "":
		return nil, Invalid("Nothing was recorded: give worktree to move into one, or leave_worktree to go back to the folder, not both.")
	case worktree != "":
		if discard {
			return nil, onlyRemove
		}
		if strings.HasPrefix(worktree, "/") {
			return &wire.PendingMove{Target: wire.MoveTarget{Existing: &wire.MoveTargetExisting{Value: store.FolderURL(worktree)}}}, nil
		}
		return &wire.PendingMove{Target: wire.MoveTarget{NewWorktree: &wire.MoveTargetNewWorktree{Name: &worktree}}}, nil
	}
	switch leaving {
	case "":
		if discard {
			return nil, onlyRemove
		}
		return nil, nil
	case "keep":
		if discard {
			return nil, onlyRemove
		}
		return &wire.PendingMove{Target: wire.MoveTarget{FolderPath: &struct{}{}}}, nil
	case "remove":
		return &wire.PendingMove{Target: wire.MoveTarget{FolderPath: &struct{}{}}, RemoveLeft: true, DiscardChanges: discard}, nil
	}
	return nil, Invalid("Nothing was recorded: leave_worktree has to be keep or remove.")
}

// registerMoves serves agents/move: a person moving an agent (053). The agent's own
// move_worktree tool is separate, and a person taking the move back does not cancel that.
func (d *Daemon) registerMoves() {
	On(d, wire.CallAgentsMove, func(_ context.Context, _ *Client, r wire.MoveRequest) (wire.MoveAnswer, error) {
		return d.moveAgent(r)
	})
}

// moveAgent is agents/move. No target takes back a move the person asked for.
func (d *Daemon) moveAgent(r wire.MoveRequest) (wire.MoveAnswer, error) {
	if r.Target == nil {
		a := d.Store.Agent(r.AgentID)
		if a == nil {
			return wire.MoveAnswer{}, &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was moved."}
		}
		if a.PendingMove == nil || a.PendingMove.AskedBy != wire.MoveAskerPerson {
			return wire.MoveAnswer{When: wire.MoveWhenNothing, Message: "No move was waiting."}, nil
		}
		d.change(r.AgentID, func(a *wire.Agent) { a.PendingMove = nil })
		d.record(r.AgentID, runtimeNote("Move cancelled."))
		return wire.MoveAnswer{When: wire.MoveWhenNothing, Message: "Move cancelled."}, nil
	}
	msg, err := d.askMove(r.AgentID, wire.PendingMove{Target: *r.Target, RemoveLeft: r.RemoveLeft,
		DiscardChanges: r.DiscardChanges, AskedBy: wire.MoveAskerPerson, AskedAt: now()})
	if err != nil {
		return wire.MoveAnswer{}, err
	}
	when := wire.MoveWhenNow
	switch {
	case strings.HasPrefix(msg, "You are not in a worktree"), strings.HasPrefix(msg, "Already working"):
		when = wire.MoveWhenNothing
	case strings.HasPrefix(msg, "Moving to "):
		when = wire.MoveWhenAfterTurn
	}
	answer := wire.MoveAnswer{When: when, Message: msg}
	if when == wire.MoveWhenNow {
		answer.Agent = d.Store.Agent(r.AgentID)
	}
	return answer, nil
}

// askMove checks a move now, in words, and keeps it for when the turn ends, or makes it now
// when no turn is running. Anything refused here is refused before it is kept, so the agent
// hears why while it can still do something about it.
func (d *Daemon) askMove(id wire.UUID, move wire.PendingMove) (string, error) {
	a := d.Store.Agent(id)
	if a == nil || a.State == wire.AgentStateArchived {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That agent is archived, so it cannot be moved."}
	}
	if !runtimeCanMove(a.RuntimeID) {
		return "", worktreeFailed(whyCannotMove(a.RuntimeID))
	}
	folder := folderPath(a)
	repo, ok := repositoryOf(folder)
	if !ok {
		return "", worktreeFailed("Moving needs a git repository, and " + filepath.Base(folder) + " is not in one.")
	}
	cwd := store.FolderPath(a.Cwd)
	if e := move.Target.Existing; e != nil && canonical(store.FolderPath(e.Value)) == canonical(repo.toplevel) {
		move.Target = wire.MoveTarget{FolderPath: &struct{}{}}
	}
	// A local branch's name moves to the worktree it is checked out in, or to a new
	// worktree on it, so an agent never runs git worktree add by hand (#3174).
	if n := move.Target.NewWorktree; n != nil && n.Name != nil && isLocalBranch(folder, *n.Name) {
		list, _ := worktreeList(folder)
		for _, e := range list {
			if e.branch != *n.Name {
				continue
			}
			if canonical(e.root) == canonical(repo.toplevel) {
				return "", Invalid("Nothing was moved: %s is checked out in the folder itself. Name another branch, or a new worktree.", *n.Name)
			}
			move.Target = wire.MoveTarget{Existing: &wire.MoveTargetExisting{Value: store.FolderURL(e.root)}}
		}
	}
	switch t := move.Target; {
	case t.FolderPath != nil:
		if a.Worktree == nil {
			return "You are not in a worktree; nothing to do.", nil
		}
	case t.Existing != nil:
		root := canonical(store.FolderPath(t.Existing.Value))
		if a.Worktree != nil && canonical(store.FolderPath(a.Worktree.Root)) == root {
			return "Already working in " + filepath.Base(root) + "; nothing to do.", nil
		}
		found := false
		list, _ := worktreeList(folder)
		for _, e := range list {
			if canonical(e.root) != root {
				continue
			}
			found = true
			if e.prunable || !isDir(root) {
				return "", &Error{Code: wire.FailureWorktreeMissing, Message: "The worktree " + filepath.Base(root) + " is not there any more."}
			}
		}
		if !found {
			return "", &Error{Code: wire.FailureNotAWorktree, Message: root + " is not a worktree of " + filepath.Base(folder) + "'s repository."}
		}
	case t.NewWorktree != nil:
		if _, err := git(cwd, "rev-parse", "--verify", "-q", "HEAD"); err != nil {
			return "", worktreeFailed("There is no commit here yet to base a worktree on. Commit something first.")
		}
		// The name is settled now, from the title the agent has now, so the answer names
		// the worktree made.
		given := ""
		if t.NewWorktree.Name != nil {
			given = *t.NewWorktree.Name
		}
		if isLocalBranch(folder, given) {
			break
		}
		name := moveName(given, a)
		move.Target.NewWorktree = &wire.MoveTargetNewWorktree{Name: &name}
	}
	removing := ""
	if move.RemoveLeft {
		if a.Worktree == nil || move.Target.FolderPath == nil {
			return "", Invalid("Only a move back to the folder can remove the worktree left.")
		}
		if err := d.whyNotRemoveLeft(*a.Worktree, id, move.DiscardChanges); err != nil {
			return "", err
		}
		removing = ", and remove " + a.Worktree.Name + " after"
	}
	d.change(id, func(a *wire.Agent) { a.PendingMove = &move })
	if !d.turnIsRunning(id) {
		d.applyPendingMove(id)
		return movedMessage(d.Store.Agent(id)), nil
	}
	whereTo := destinationWords(move.Target)
	d.record(id, runtimeNote("Will move to "+whereTo+removing+" when this turn ends."))
	staying := "Nothing uncommitted comes with you."
	if n := porcelainCount(cwd); n > 0 {
		files := "files here are"
		if n == 1 {
			files = "file here is"
		}
		staying = "Nothing uncommitted comes with you (" + strconv.FormatInt(n, 10) + " " + files + " uncommitted)."
	}
	carry := "you will be started again there to carry on."
	if a := d.Store.Agent(id); a != nil && a.AfterTurn != nil && *a.AfterTurn == wire.AfterTurnRequestArchive {
		carry = "you stay there, waiting for the person to approve archiving you, rather than being started again."
	}
	return "Moving to " + whereTo + removing + " when this turn ends. " + staying + " End your turn to move; " + carry, nil
}

// turnIsRunning is whether a turn is in flight: a move waits for it to be over.
func (d *Daemon) turnIsRunning(id wire.UUID) bool {
	d.mu.Lock()
	l := d.lives[id]
	d.mu.Unlock()
	if l != nil {
		l.mu.Lock()
		in := l.inTurn
		l.mu.Unlock()
		if in {
			return true
		}
	}
	a := d.Store.Agent(id)
	return a != nil && inFlight(a.State)
}

// moveName is what a new worktree made by a move is called: the name the agent gave,
// cleaned as a prompt is, or else its title, or else agent- and the time.
func moveName(given string, a *wire.Agent) string {
	if strings.TrimSpace(given) != "" {
		return worktreeName(given, true, time.Now())
	}
	title := ""
	if a.Title != nil {
		title = *a.Title
	}
	return worktreeName(title, false, time.Now())
}

func destinationWords(t wire.MoveTarget) string {
	switch {
	case t.Existing != nil:
		return "the worktree " + filepath.Base(store.FolderPath(t.Existing.Value))
	case t.NewWorktree != nil && t.NewWorktree.Name != nil:
		return "a new worktree like " + *t.NewWorktree.Name
	}
	return "the folder"
}

func movedMessage(a *wire.Agent) string {
	if a == nil {
		return "Moved."
	}
	if wt := a.Worktree; wt != nil {
		on := ""
		if wt.Branch != nil {
			on = " on " + *wt.Branch
		}
		return "Moved. Now working in the worktree " + wt.Name + on + ", at " + store.FolderPath(a.Cwd) + "."
	}
	return "Moved. Now working in the folder, " + store.FolderPath(a.Cwd) + "."
}

func placeName(wt *wire.AgentWorktree) string {
	if wt == nil {
		return "the folder"
	}
	return "worktree " + wt.Name
}

// applyPendingMove makes the move that is waiting, if one is, and is whether the agent
// moved. A move that cannot be made leaves the agent where it was, and says why in its
// chat.
func (d *Daemon) applyPendingMove(id wire.UUID) bool {
	a := d.Store.Agent(id)
	if a == nil || a.PendingMove == nil {
		return false
	}
	move := *a.PendingMove
	d.change(id, func(a *wire.Agent) { a.PendingMove = nil })
	if a.State == wire.AgentStateArchived {
		return false
	}
	// A runtime left open would carry on in the old folder: the next turn starts one in
	// the new folder, which picks the conversation back up there.
	d.releaseRuntime(id)

	old := store.FolderPath(a.Cwd)
	leaving := a.Worktree
	leftBehind := porcelainCount(old)
	folder := folderPath(a)
	var wt *wire.AgentWorktree
	cwd := folder
	var err error
	switch t := move.Target; {
	case t.NewWorktree != nil && isLocalBranch(folder, deref(t.NewWorktree.Name)):
		wt, cwd, err = d.prepareWorktree(folder, wire.WorktreeChoice{Branch: &wire.WorktreeChoiceBranch{Value: *t.NewWorktree.Name}}, "")
	case t.NewWorktree != nil:
		name := moveName(deref(t.NewWorktree.Name), a)
		wt, cwd, err = d.prepareWorktreeFrom(folder, old, wire.WorktreeChoice{Named: &wire.WorktreeChoiceNamed{Value: name}}, "")
	case t.Existing != nil:
		wt, cwd, err = d.prepareWorktree(folder, wire.WorktreeChoice{Existing: &wire.WorktreeChoiceExisting{Value: t.Existing.Value}}, "")
	}
	if err != nil {
		msg := err.Error()
		if e, ok := err.(*Error); ok {
			msg = e.Message
		}
		d.record(id, runtimeNote("Could not move: "+msg+" Still in "+placeName(leaving)+"."))
		return false
	}
	start := movedStartingPoint(a.StartingPoint, cwd)
	d.change(id, func(a *wire.Agent) {
		a.Cwd, a.Worktree, a.StartingPoint = store.FolderURL(cwd), wt, start
		a.MissingFolder = nil
	})

	note := "Moved from " + placeName(leaving) + " to "
	if wt != nil {
		note += "worktree " + wt.Name
		if wt.Branch != nil {
			note += " on " + *wt.Branch
		} else {
			note += ", detached"
		}
		if wt.MadeByApp && wt.Base != nil && (leaving == nil || deref(leaving.Branch) != deref(wt.Branch)) {
			note += ", from " + *wt.Base
		}
		note += "."
	} else {
		note += "the folder."
	}
	if leftBehind > 0 {
		changes := " uncommitted changes stayed in "
		if leftBehind == 1 {
			changes = " uncommitted change stayed in "
		}
		note += " " + strconv.FormatInt(leftBehind, 10) + changes + placeName(leaving) + "."
	}
	if move.RemoveLeft && leaving != nil {
		if said, err := d.removeLeftWorktree(*leaving, id, move.DiscardChanges); err != nil {
			msg := err.Error()
			if e, ok := err.(*Error); ok {
				msg = e.Message
			}
			note += " Kept the worktree " + leaving.Name + ": " + msg
		} else {
			note += " " + said
		}
	}
	d.record(id, runtimeNote(note))
	d.folderChanged(folder)
	return true
}

// releaseRuntime lets the agent's runtime go between turns, its tokens with it.
func (d *Daemon) releaseRuntime(id wire.UUID) {
	l := d.live(id)
	l.mu.Lock()
	s := l.session
	l.session = nil
	if s != nil {
		d.dropStandIn(id)
	}
	l.mu.Unlock()
	if s != nil {
		s.Stop()
		d.dropAppTokens(id)
	}
}

// movedStartingPoint is DaemonCore.startingPoint(after:in:): the same commit in the new
// checkout when its history has it, so everything the agent did still shows; else a fresh
// start from the new checkout's HEAD.
func movedStartingPoint(old *wire.StartingPoint, folder string) *wire.StartingPoint {
	out, err := git(folder, "rev-parse", "--show-toplevel", "HEAD")
	lines := strings.Split(out, "\n")
	if err != nil || len(lines) != 2 {
		return old
	}
	fresh := &wire.StartingPoint{Repository: store.FolderURL(lines[0]), Commit: lines[1]}
	if old == nil {
		return fresh
	}
	if _, err := git(folder, "merge-base", "--is-ancestor", old.Commit, "HEAD"); err != nil {
		return fresh
	}
	return &wire.StartingPoint{Repository: fresh.Repository, Commit: old.Commit}
}

// movePreface is what the agent is told at the start of its next turn.
func movePreface(a *wire.Agent, old string, leftBehind bool) string {
	var text string
	if wt := a.Worktree; wt != nil {
		text = "You have moved: you now work in " + store.FolderPath(a.Cwd) + ", the worktree " + wt.Name
		if wt.Branch != nil {
			text += " on the branch " + *wt.Branch + "."
		} else {
			text += ", detached."
		}
	} else {
		text = "You have moved back to the folder, " + store.FolderPath(a.Cwd) + "."
	}
	if leftBehind {
		text += " What was uncommitted in " + old + " stayed there."
	}
	return text
}

// afterTurnMove makes a move asked for in the turn that has just ended, and starts the
// agent again in the new folder when it moved itself and the turn finished: with the
// person's queued words when there are some, else the app's carry-on. Not when it asked to
// be archived: it stays there, waiting for approval. It says whether the agent goes on: then
// the turn that ended is not its finish (#1955).
func (d *Daemon) afterTurnMove(id wire.UUID, s wire.AgentState, archiving bool) bool {
	a := d.Store.Agent(id)
	if a == nil || a.PendingMove == nil {
		return false
	}
	askedBy := a.PendingMove.AskedBy
	old := store.FolderPath(a.Cwd)
	leftBehind := porcelainCount(old) > 0
	if !d.applyPendingMove(id) || askedBy != wire.MoveAskerAgent || s != wire.AgentStateFinished {
		return false
	}
	moved := d.Store.Agent(id)
	if moved == nil || archiving || moved.ArchiveRequest != nil || moved.State == wire.AgentStateArchived {
		return false
	}
	preface := movePreface(moved, old, leftBehind)
	if len(moved.QueuedPrompts) > 0 {
		d.change(id, func(a *wire.Agent) {
			if len(a.QueuedPrompts) == 0 {
				return
			}
			q := &a.QueuedPrompts[0]
			if q.Preface != nil {
				preface += "\n\n" + *q.Preface
			}
			q.Preface = &preface
		})
		return true
	}
	if err := d.enqueue(id, wire.QueuedPrompt{ID: store.NewUUID(), Text: preface + " " + carryOn, QueuedAt: now(), From: wire.PromptOriginApp}, false); err != nil {
		d.record(id, runtimeNote("Could not start again after the move: "+err.Error()))
		return false
	}
	return true
}

// whyNotRemoveLeft is why an agent leaving a worktree with remove may not take it away, or
// nil when it may (#194, #1821): what no branch or remote would hold. A detached HEAD, a
// branch that is gone, changes not committed (unless it says to discard them), and commits
// not pushed: removing is for when the work is pushed. id is the agent leaving, so it does
// not count as working there.
func (d *Daemon) whyNotRemoveLeft(wt wire.AgentWorktree, id wire.UUID, discard bool) error {
	f, err := d.removalFacts(wire.WorktreeRemovalRequest{Folder: wt.Folder, Root: wt.Root})
	if err != nil {
		return err
	}
	name := filepath.Base(f.root)
	branch := f.entry.branch
	if branch == "" {
		return worktreeFailed(name + " is on a detached HEAD, so removing it would leave any commits made there on no branch. Put them on a branch, or use keep.")
	}
	if !f.madeByApp {
		return &Error{Code: wire.FailureNotAWorktree, Message: name + " was not made by this app, so it is not this app's to remove. Use keep."}
	}
	var others []wire.UUID
	for _, b := range f.blockedBy {
		if b != id {
			others = append(others, b)
		}
	}
	if len(others) > 0 {
		var names []string
		for _, o := range others {
			if a := d.Store.Agent(o); a != nil && a.Title != nil {
				names = append(names, *a.Title)
			} else {
				names = append(names, "an agent")
			}
		}
		return &Error{Code: wire.FailureWorktreeInUse, Message: name + " is still in use by " + strings.Join(names, ", ") + ", so it cannot be removed. Use keep."}
	}
	folder := store.FolderPath(wt.Folder)
	if _, err := git(folder, "show-ref", "--verify", "-q", "refs/heads/"+branch); err != nil {
		return worktreeFailed(name + "'s branch " + branch + " is not there any more, so removing it would leave its commits on no branch. Make the branch again, or use keep.")
	}
	if f.uncommitted > 0 && !discard {
		lines, _ := git(f.root, "status", "--porcelain")
		return worktreeFailed("Removing " + name + " would lose " + uncommittedWords(strings.Split(lines, "\n"), f.uncommitted) +
			". Commit and push them, use keep, or ask the person before calling again with discard_changes.")
	}
	if n := unpushed(folder, branch); n > 0 && f.unmerged {
		commits := " commits"
		if n == 1 {
			commits = " commit"
		}
		return worktreeFailed(name + " has " + strconv.Itoa(n) + commits + " on " + branch + " that no remote has. Push them (git push -u origin " + branch + "), or use keep.")
	}
	return nil
}

// unpushed is how many commits on branch no remote-tracking branch has.
func unpushed(folder, branch string) int {
	out, err := git(folder, "rev-list", "--count", "refs/heads/"+branch, "--not", "--remotes")
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(out))
	return n
}

// removeLeftWorktree takes away the worktree an agent has just left with remove, on the
// terms of whyNotRemoveLeft, checked again now the turn is over. The branch goes too only
// when it is the app's and merged; otherwise it stays, and holds the commits.
func (d *Daemon) removeLeftWorktree(wt wire.AgentWorktree, id wire.UUID, discard bool) (string, error) {
	if err := d.whyNotRemoveLeft(wt, id, discard); err != nil {
		return "", err
	}
	f, err := d.removalFacts(wire.WorktreeRemovalRequest{Folder: wt.Folder, Root: wt.Root})
	if err != nil {
		return "", err
	}
	folder := store.FolderPath(wt.Folder)
	if isDir(f.root) && !f.entry.prunable {
		args := []string{"worktree", "remove"}
		if f.uncommitted > 0 {
			args = append(args, "--force")
		}
		if _, err := git(folder, append(args, f.root)...); err != nil {
			return "", worktreeFailed("Could not remove " + wt.Name + ": " + err.Error())
		}
	} else if _, err := git(folder, "worktree", "prune"); err != nil {
		return "", worktreeFailed("Could not remove " + wt.Name + ": " + err.Error())
	}
	d.sizeMu.Lock()
	delete(d.sizes, f.root)
	d.sizeMu.Unlock()
	d.noteFolders()
	branch := f.entry.branch
	if strings.HasPrefix(branch, branchPrefix) && !f.unmerged {
		if _, err := git(folder, "branch", "-d", branch); err == nil {
			return "Removed the worktree " + wt.Name + " and its branch.", nil
		}
	}
	return "Removed the worktree " + wt.Name + "; its branch " + branch + " is kept.", nil
}

// uncommittedWords is "2 uncommitted changes: edited a.swift, untracked notes.txt", from
// git status --porcelain lines, naming the first few.
func uncommittedWords(lines []string, count int64) string {
	words := strconv.FormatInt(count, 10) + " uncommitted changes"
	if count == 1 {
		words = "1 uncommitted change"
	}
	const shown = 5
	var named []string
	var all int
	for _, l := range lines {
		if len(l) <= 3 {
			continue
		}
		all++
		if len(named) == shown {
			continue
		}
		code, path := l[:2], l[3:]
		kind := "edited"
		switch {
		case code == "??":
			kind = "untracked"
		case strings.Contains(code, "D"):
			kind = "deleted"
		case strings.Contains(code, "A"):
			kind = "added"
		case strings.Contains(code, "R"):
			kind = "renamed"
		}
		named = append(named, kind+" "+path)
	}
	if len(named) > 0 {
		words += ": " + strings.Join(named, ", ")
		if all > shown {
			words += " and " + strconv.Itoa(all-shown) + " more"
		}
	}
	return words
}

// isLocalBranch says whether name is a branch of folder's repository.
func isLocalBranch(folder, name string) bool {
	if name == "" || strings.HasPrefix(name, "-") {
		return false
	}
	_, err := git(folder, "show-ref", "--verify", "-q", "refs/heads/"+name)
	return err == nil
}
