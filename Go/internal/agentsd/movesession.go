package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// move_session (#3717): a session goes on on another of the person's machines, with its
// unpushed work. The branch it works on goes to the folder there first, with its uncommitted
// changes, as start_session with send does (sendthere.go): receive makes the folder there
// when it is not there yet, and refuses one with work of its own. Then its record and its
// transcript go there as an export (export.go), and that machine's agents/moveIn restores
// them with the same id, in its own root and in that folder, not archived. The runtime's own
// conversation stays here, so the runtime there reads the app's record ahead of its next
// prompt (movedFrom, branchPreface). This machine then lets the session go: two machines
// never list one id.
//
// An agent that moves itself moves when its turn ends, as move_worktree does (053): a runtime
// cannot leave while it works. A session it started is stopped first when it is working, and
// carries on there when it was.

// machineMove is a move to another machine: where it goes, and who asked.
type machineMove struct {
	machine, folder string
	asker           wire.UUID
}

// moveSessionTool is move_session.
func (d *Daemon) moveSessionTool(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	me := d.Store.Agent(caller)
	if me == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was moved."}
	}
	machine := onMachine(args)
	if machine == "" {
		return "", Invalid("Nothing was moved: say which machine, by its name as list_machines gives it.")
	}
	// Checked before the card: the person is never asked about what can't be done (#855).
	if d.askControl.Load() == nil {
		return "", &Error{Code: wire.FailureNotSupported, Message: "Nothing was moved: this machine isn’t on a control plane, so it has no other machines."}
	}
	target, self := me, true
	if s := strings.TrimSpace(argString(args, "session")); s != "" && !strings.EqualFold(s, string(caller)) {
		t, err := d.helperTarget(caller, wire.UUID(strings.ToUpper(s)), "move")
		if err != nil {
			return "", movedWords(err)
		}
		target, self = t, false
	}
	if self {
		if _, waiting := d.machineMoves.Load(caller); waiting {
			return "You already move when this turn ends; nothing changed.", nil
		}
		if me.PendingMove != nil {
			return "", Invalid("Nothing was moved: you already move into another folder when this turn ends. Call move_worktree with no arguments to take that back first.")
		}
		if w := me.EventWait; w != nil && w.Ending == nil {
			return "", Invalid("Nothing was moved: you are waiting for %s, and a move starts you again on the other machine rather than waiting. Call cancel_wait first.", waitLabel(w))
		}
		if me.AfterTurn != nil && *me.AfterTurn == wire.AfterTurnArchive {
			return "", Invalid("Nothing was moved: you asked to be archived once this turn ends. Call archive_session with no id to take that back, or do not move.")
		}
	} else if target.PendingMove != nil {
		return "", Invalid("Nothing was moved: %s moves into another folder when its turn ends.", quotedTitle(target.Title))
	}
	folder := strings.TrimSpace(argString(args, "folder"))
	if folder == "" {
		there, err := d.projectFolderOn(me, machine)
		if err != nil {
			return "", movedWords(err)
		}
		folder = there
	}
	if !strings.HasPrefix(folder, "/") {
		return "", Invalid("Nothing was moved: the folder on %s is an absolute path, such as /home/me/project, not %s.", machine, folder)
	}
	folder = filepath.Clean(folder)
	b, err := d.branchToSend(target)
	if err != nil {
		_, msg := errMessage(err)
		return "", Invalid("Nothing was moved: %s", msg)
	}
	if _, err := d.readyThere(me, machine, folder); err != nil {
		code, msg := errMessage(err)
		if code == wire.FailureHostOffline {
			msg += " Start it with start_machine, then try again."
		}
		return "", &Error{Code: code, Message: "Nothing was moved to " + machine + ": " + msg}
	}
	if !d.agentsMayStartOnMachines(folderPath(me)) {
		ask := fmt.Sprintf("Move %s to %s, with %s and its uncommitted changes, into %s there? It goes on there with this conversation.",
			sessionWords(target, self), machine, b.branch, folder)
		yes, err := d.personSaysYes(caller, d.agentWho(caller)+" wants to move a session to "+machine, ask, "Move it")
		if err != nil {
			return "", err
		}
		if !yes {
			return "Nothing was moved: the person said no, or didn’t answer.", nil
		}
	}
	order := machineMove{machine: machine, folder: folder, asker: caller}
	if self {
		d.machineMoves.Store(caller, order)
		d.record(caller, runtimeNote("Moves to "+machine+", into "+folder+", when this turn ends."))
		return fmt.Sprintf("You move to %s when this turn ends: %s, with its uncommitted changes, goes to %s there, and you carry on there with this conversation. "+
			"End your turn now, without waiting.", machine, b.branch, folder), nil
	}
	l := d.live(target.ID)
	l.mu.Lock()
	working := inFlight(target.State) || l.running || l.inTurn
	l.mu.Unlock()
	if working {
		d.stopHelper(target)
	}
	if err := d.moveToMachine(target.ID, order, working); err != nil {
		code, msg := errMessage(err)
		return "", &Error{Code: code, Message: quotedTitle(target.Title) + " was not moved to " + machine + ": " + msg + " It stays here."}
	}
	carries := "It waits there for its next prompt."
	if working {
		carries = "It was working, so it carries on there."
	}
	return fmt.Sprintf("Moved %s to %s, in %s, with %s and its uncommitted changes (id %s). %s list_sessions, read_session, message_session, wait_for_event on agent.ended, "+
		"stop_session and archive_session reach it there by its id; the person sees it under %s.",
		quotedTitle(target.Title), machine, folder, b.branch, target.ID, carries, machine), nil
}

// sessionWords is the session a move_session card names.
func sessionWords(a *wire.Agent, self bool) string {
	if self {
		return "this session (" + quotedTitle(a.Title) + ")"
	}
	return "the session " + quotedTitle(a.Title)
}

// movedWords is a refusal from a step start_session shares, in move_session's words.
func movedWords(err error) error {
	e, ok := err.(*Error)
	if !ok {
		return err
	}
	msg := strings.Replace(e.Message, "Nothing was started", "Nothing was moved", 1)
	msg = strings.Replace(msg, "Nothing changed", "Nothing was moved", 1)
	msg = strings.Replace(msg, "You can only stop or archive sessions", "You can only move yourself, or stop, archive or move sessions", 1)
	return &Error{Code: e.Code, Message: msg}
}

// afterTurnMachineMove makes the move an agent asked for in the turn that has just ended:
// when it finished. Any other ending, such as the person stopping it, takes the move back.
func (d *Daemon) afterTurnMachineMove(id wire.UUID, s wire.AgentState) {
	v, ok := d.machineMoves.LoadAndDelete(id)
	if !ok {
		return
	}
	order := v.(machineMove)
	if s != wire.AgentStateFinished {
		d.record(id, runtimeNote("Did not move to "+order.machine+": the turn did not finish. It stays here."))
		return
	}
	d.goAfterTurn("move "+string(id)+" to "+order.machine, func() {
		if err := d.moveToMachine(id, order, true); err != nil {
			_, msg := errMessage(err)
			d.record(id, runtimeNote("Did not move to "+order.machine+": "+msg+" It stays here."))
		}
	})
}

// moveToMachine moves the session id to order's machine; carry starts it again there. The
// session stays here until that machine has it.
func (d *Daemon) moveToMachine(id wire.UUID, order machineMove, carry bool) error {
	a := d.Store.Agent(id)
	if a == nil {
		return noSuchAgent()
	}
	asker := d.Store.Agent(order.asker)
	if asker == nil {
		asker = a
	}
	b, err := d.branchToSend(a)
	if err != nil {
		return err
	}
	if b.heads, err = d.readyThere(asker, order.machine, order.folder); err != nil {
		return err
	}
	if err := d.sendThere(asker, order.machine, order.folder, b); err != nil {
		return err
	}
	// Its runtime goes now, so nothing more is said here; the record is what it says then.
	d.releaseRuntime(id)
	d.dropLeases(id, "holderStopped")
	d.endWait(id, "stopped", true)
	a = d.Store.Agent(id)
	if a == nil {
		return noSuchAgent()
	}
	up, err := d.exportForMove(asker, order.machine, *a)
	if err != nil {
		return err
	}
	from := wire.StartedFrom{Machine: d.ownName(), Who: d.agentWho(asker.ID)}
	if asker.ID != id {
		from.Agent = asker.ID
	}
	in := wire.SessionMoveIn{Upload: up, Folder: order.folder, From: from, CarryOn: &carry}
	if err := d.askSend(asker, wire.MachineFolderSend{Host: order.machine, MoveIn: &in}, nil); err != nil {
		return err
	}
	if asker.ID != id {
		title := ""
		if a.Title != nil {
			title = *a.Title
		}
		d.noteStartedThere(startedThere{Machine: order.machine, Session: id, Starter: asker.ID, Folder: folderPath(asker), There: order.folder, Title: title, At: now()})
	}
	d.letGo(a)
	return nil
}

// exportForMove writes a's record and transcript as an export and sends it to machine; it is
// the upload's id there.
func (d *Daemon) exportForMove(asker *wire.Agent, machine string, a wire.Agent) (wire.UUID, error) {
	sweepTransfers(d.outgoingFolder())
	if err := os.MkdirAll(d.outgoingFolder(), 0o700); err != nil {
		return "", err
	}
	file := store.NewUUID()
	path, _ := d.outgoingFile(file)
	defer os.Remove(path)
	m := backupManifest{Format: backupFormat, RootID: d.Store.RootID, Machine: macName(), MadeAt: wire.DateOf(nowFunc().UTC())}
	if err := d.writeBackupArchive(path, &m, []wire.Agent{a}, false); err != nil {
		return "", err
	}
	return d.uploadThere(asker, machine, file)
}

// letGo forgets a session that another machine now has: as a delete does, with nothing
// erased, since what the runtime keeps here is not the session's any more, and its worktree
// left as it is.
func (d *Daemon) letGo(a *wire.Agent) {
	d.forgetLive(a.ID)
	if err := d.Store.Delete(a.ID); err != nil {
		log.Printf("move_session: %s is on another machine now, but its files here stay: %v", a.ID, err)
	}
	Broadcast(d, wire.NotifyAgentRemoved, wire.AgentRemovedNotification{AgentID: a.ID})
	d.takeActor(a.ID)
	d.folderChanged(folderPath(a))
}

func (d *Daemon) registerMoveIn() {
	On(d, wire.CallAgentsMoveIn, func(_ context.Context, _ *Client, r wire.SessionMoveIn) (wire.Empty, error) {
		return wire.Empty{}, d.moveIn(r)
	})
	On(d, wire.CallAgentsMoveToMachine, func(_ context.Context, _ *Client, r wire.MoveToMachineRequest) (wire.MoveToMachineAnswer, error) {
		return d.personMovesToMachine(r)
	})
}

// personMovesToMachine is agents/moveToMachine (#3790): Move to Machine… in a client. The
// person asked, so no card asks them again; the session itself asks the control plane, as
// it does for its own move. A running turn stops first, and carries on there.
func (d *Daemon) personMovesToMachine(r wire.MoveToMachineRequest) (wire.MoveToMachineAnswer, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return wire.MoveToMachineAnswer{}, &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was moved."}
	}
	machine := strings.TrimSpace(r.Machine)
	if machine == "" {
		return wire.MoveToMachineAnswer{}, Invalid("Nothing was moved: say which machine.")
	}
	if d.askControl.Load() == nil {
		return wire.MoveToMachineAnswer{}, &Error{Code: wire.FailureNotSupported, Message: "Nothing was moved: this machine isn’t on a control plane, so it has no other machines."}
	}
	name := machine
	if r.MachineName != nil && strings.TrimSpace(*r.MachineName) != "" {
		name = strings.TrimSpace(*r.MachineName)
	}
	if strings.EqualFold(machine, d.ownName()) || strings.EqualFold(machine, d.ownHostID()) {
		return wire.MoveToMachineAnswer{}, Invalid("Nothing was moved: the session is on %s already.", d.ownName())
	}
	switch {
	case a.State == wire.AgentStateArchived:
		return wire.MoveToMachineAnswer{}, Invalid("Nothing was moved: %s is archived. Unarchive it first.", quotedTitle(a.Title))
	case a.PendingMove != nil:
		return wire.MoveToMachineAnswer{}, Invalid("Nothing was moved: %s moves into another folder when its turn ends.", quotedTitle(a.Title))
	}
	if _, waiting := d.machineMoves.Load(a.ID); waiting {
		return wire.MoveToMachineAnswer{}, Invalid("Nothing was moved: %s already moves to another machine when its turn ends.", quotedTitle(a.Title))
	}
	folder := ""
	if r.Folder != nil {
		folder = strings.TrimSpace(*r.Folder)
	}
	if folder == "" {
		// The project's one folder there; else the person gives it, in the sheet.
		there, err := d.projectFolderOn(a, machine)
		if err != nil {
			return wire.MoveToMachineAnswer{}, Invalid("Nothing was moved: this project has no one folder on %s. Give the folder there, as an absolute path.", name)
		}
		folder = there
	}
	if !strings.HasPrefix(folder, "/") {
		return wire.MoveToMachineAnswer{}, Invalid("Nothing was moved: the folder on %s is an absolute path, such as /home/me/project, not %s.", name, folder)
	}
	folder = filepath.Clean(folder)
	if _, err := d.branchToSend(a); err != nil {
		_, msg := errMessage(err)
		return wire.MoveToMachineAnswer{}, Invalid("Nothing was moved: %s", msg)
	}
	// Asked before the turn stops, so a move that can't be made stops nothing (#855).
	if _, err := d.readyThere(a, machine, folder); err != nil {
		code, msg := errMessage(err)
		return wire.MoveToMachineAnswer{}, &Error{Code: code, Message: "Nothing was moved to " + name + ": " + msg}
	}
	l := d.live(a.ID)
	l.mu.Lock()
	working := inFlight(a.State) || l.running || l.inTurn
	l.mu.Unlock()
	if working {
		d.stopHelper(a)
	}
	if err := d.moveToMachine(a.ID, machineMove{machine: machine, folder: folder, asker: a.ID}, working); err != nil {
		code, msg := errMessage(err)
		return wire.MoveToMachineAnswer{}, &Error{Code: code, Message: quotedTitle(a.Title) + " was not moved to " + name + ": " + msg + " It stays here."}
	}
	return wire.MoveToMachineAnswer{Folder: folder, CarriesOn: working}, nil
}

// arrival is a session moving in: what agents/moveIn asked, and the id restored.
type arrival struct {
	in wire.SessionMoveIn
	id wire.UUID
}

// moveIn is agents/moveIn: the session in the uploaded export goes on here, in r.Folder.
func (d *Daemon) moveIn(r wire.SessionMoveIn) error {
	path, err := d.incomingFile(r.Upload)
	if err != nil {
		return err
	}
	defer os.Remove(path)
	folder := filepath.Clean(r.Folder)
	if !filepath.IsAbs(folder) {
		return Invalid("%s is not an absolute path.", r.Folder)
	}
	if fi, err := os.Stat(folder); err != nil || !fi.IsDir() {
		return noSuchFolder(shortPath(folder) + " is not a folder on this machine. Send its branch first.")
	}
	m, err := readExportManifest(path)
	if err != nil {
		return err
	}
	if m.Agents != 1 {
		return Invalid("A move brings one session, not %d.", m.Agents)
	}
	r.Folder = folder
	in := &arrival{in: r}
	res, err := d.restoreArchive(path, m.RootID, false, false, "", in)
	if err != nil {
		return err
	}
	if res.Restored != 1 || in.id == "" {
		return &Error{Code: wire.FailureFolderInTheWay, Message: "This machine has that session already, or once deleted it."}
	}
	id := in.id
	from := r.From.Machine
	if from == "" {
		from = "another machine"
	}
	d.record(id, runtimeNote("Moved here from "+from+", into "+folder+"."))
	if r.From.Agent != "" && r.From.Agent != id {
		d.noteStartedHere(id, r.From)
	}
	d.folderChanged(folder)
	if r.CarryOn == nil || !*r.CarryOn {
		return nil
	}
	preface := "You have moved to this machine, " + d.ownName() + ", from " + from + ": you now work in " + folder
	if branch, err := git(folder, "rev-parse", "--abbrev-ref", "HEAD"); err == nil && branch != "" && branch != "HEAD" {
		preface += ", on the branch " + branch
	}
	preface += ", with the work you had there."
	if a := d.Store.Agent(id); a != nil && len(a.QueuedPrompts) > 0 {
		d.change(id, func(a *wire.Agent) {
			if len(a.QueuedPrompts) == 0 {
				return
			}
			q := &a.QueuedPrompts[0]
			p := preface
			if q.Preface != nil {
				p += "\n\n" + *q.Preface
			}
			q.Preface = &p
		})
		d.live(id).kick()
		return nil
	}
	return d.enqueue(id, wire.QueuedPrompt{ID: store.NewUUID(), Text: preface + " " + carryOn, QueuedAt: now(), From: wire.PromptOriginApp}, false)
}

// arrive is restoreAgent's change to a record moving in: this machine's own, in the folder
// it goes on in, with nothing of the set-up it left.
func (d *Daemon) arrive(a *wire.Agent, in *arrival) {
	folder := in.in.Folder
	a.Cwd, a.Worktree = store.FolderURL(folder), nil
	a.StartingPoint = movedStartingPoint(a.StartingPoint, folder)
	root := d.Store.RootID
	a.MadeInRoot = &root
	a.McpServers, a.RuntimeSessionID, a.AccountID = nil, nil, nil
	from := in.in.From.Machine
	if from == "" {
		from = "another machine"
	}
	a.MovedFrom = &wire.SessionMovedFrom{Machine: from, At: now()}
	if inFlight(a.State) {
		end := wire.EndedReasonEndTurn
		a.State, a.EndedReason = wire.AgentStateFinished, &end
	}
	a.EventWait, a.PendingMove, a.ArchiveRequest, a.AfterTurn = nil, nil, nil, nil
	in.id = a.ID
}
