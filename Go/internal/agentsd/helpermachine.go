package agentsd

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// start_session on another machine (#2887): the session goes to another of the person's
// machines, by its name, through the control plane (machines/startSession), which sends
// that machine's own agents/start. The person says yes first, unless the folder's switch
// says agents may start them without asking (#2928). The session is not in this folder,
// but this folder's limits count it, and the tools for an agent's own sessions reach it
// through the control plane (elsewhere.go, #2927). With send, the branch the agent is on
// goes to that folder first (sendthere.go, #2929).

// sessionOnMachine is the control plane's method for it, through host/machines.
const sessionOnMachine = "machines/startSession"

// onMachine is the machine start_session names, or "" for this folder.
func onMachine(args map[string]json.RawMessage) string {
	return strings.TrimSpace(argString(args, "machine"))
}

// startOnMachine is start_session with machine: r as a helper here would be, in the folder
// it names on that machine.
func (d *Daemon) startOnMachine(me *wire.Agent, args map[string]json.RawMessage, r wire.StartRequest) (string, error) {
	machine := onMachine(args)
	folder := strings.TrimSpace(argString(args, "folder"))
	if folder == "" {
		return "", Invalid("Nothing was started: say which folder on %s, as an absolute path.", machine)
	}
	if !strings.HasPrefix(folder, "/") {
		return "", Invalid("Nothing was started: the folder on %s is an absolute path, such as /home/me/project, not %s.", machine, folder)
	}
	folder = filepath.Clean(folder)
	switch w := strings.TrimSpace(argString(args, "worktree")); {
	case w == "":
	case strings.EqualFold(w, "new"):
		r.Worktree = &wire.WorktreeChoice{New: &struct{}{}}
	default:
		r.Worktree = &wire.WorktreeChoice{Branch: &wire.WorktreeChoiceBranch{Value: w}}
	}
	// Checked before the card: the person is never asked about what can't be done (#855).
	if d.askControl.Load() == nil {
		return "", &Error{Code: wire.FailureNotSupported, Message: "Nothing was started: this machine isn’t on a control plane, so it has no other machines."}
	}
	// This folder's limits count it (#2927); with no queue there, a full one refuses.
	here := folderPath(me)
	if why := d.helperLimitRefusal(here); why != "" {
		return "", Invalid("Nothing was started on %s: %s", machine, why)
	}
	// With send (#2929), the branch this agent is on goes there first.
	var sending *sendingBranch
	if argBool(args, "send") {
		b, err := d.branchToSend(me)
		if err != nil {
			_, msg := errMessage(err)
			return "", Invalid("Nothing was sent or started: %s", msg)
		}
		sending = &b
		if sending.heads, err = d.readyThere(me, machine, folder); err != nil {
			code, msg := errMessage(err)
			if code == wire.FailureHostOffline {
				msg += " Start it with start_machine, then try again."
			}
			return "", &Error{Code: code, Message: "Nothing was sent or started on " + machine + ": " + msg}
		}
	}
	// That machine's path: no link on this one is followed.
	r.Cwd = store.PathURL(folder)
	r.StartedFrom = &wire.StartedFrom{Agent: me.ID}
	title := titleFrom(r.Prompt)
	if !d.agentsMayStartOnMachines(here) {
		ask := fmt.Sprintf("Start a session on %s, in %s, to %s?", machine, folder, quotedTitle(&title))
		if sending != nil {
			ask = fmt.Sprintf("Send %s, with its uncommitted changes, to %s on %s, then start a session there to %s?",
				sending.branch, folder, machine, quotedTitle(&title))
		}
		yes, err := d.personSaysYes(me.ID, d.agentWho(me.ID)+" wants to start a session on "+machine, ask, "Start it")
		if err != nil {
			return "", err
		}
		if !yes {
			return "Nothing was started: the person said no, or didn’t answer.", nil
		}
	}
	sent := ""
	if sending != nil {
		if err := d.sendThere(me, machine, folder, *sending); err != nil {
			code, msg := errMessage(err)
			return "", &Error{Code: code, Message: "Nothing was started: " + sending.branch + " was not sent to " + machine + ": " + msg}
		}
		sent = fmt.Sprintf("Sent %s, with its uncommitted changes, to %s on %s. ", sending.branch, folder, machine)
	}
	out, err := d.askWorkspaces(me.ID, sessionOnMachine, wire.MachineSessionStart{Host: machine, Start: r})
	if e, ok := err.(*Error); ok && e.Code == wire.FailureKept {
		return sent + fmt.Sprintf("%s is starting: the session starts in %s when it connects. Its id comes only then, so the tools for your sessions don’t reach it; the person sees it under %s.",
			machine, folder, machine), nil
	}
	if e, ok := err.(*Error); ok && !strings.HasPrefix(e.Message, "Nothing") {
		return "", &Error{Code: e.Code, Message: "Nothing was started: " + e.Message}
	}
	if err != nil {
		return "", err
	}
	var id wire.UUID
	if json.Unmarshal(out, &id) != nil {
		return "", &Error{Code: wire.FailureNotSupported, Message: "Nothing was started: the control plane's answer could not be read."}
	}
	d.noteStartedThere(startedThere{Machine: machine, Session: id, Starter: me.ID, Folder: here, There: folder, Title: title, At: now()})
	return sent + fmt.Sprintf("Started %s on %s, in %s (id %s). list_sessions, read_session, message_session, wait_for_agents, stop_session and archive_session "+
		"reach it by its id, and it counts in this folder's limits until it is archived; the person sees it under %s. This folder now has %s.",
		quotedTitle(&title), machine, folder, id, machine, d.helperPlaces(here)), nil
}

// agentsMayStartOnMachines is HelperLimits.agentsMayStartOnMachines (#2928): off unless the
// person turned it on in Folder Settings.
func (d *Daemon) agentsMayStartOnMachines(folder string) bool {
	s, ok := d.summaryFor(folder)
	return ok && s.Folder.HelperLimits != nil && s.Folder.HelperLimits.AgentsMayStartOnMachines != nil && *s.Folder.HelperLimits.AgentsMayStartOnMachines
}

// startedFromNote is what the chat of a session started from another machine says first.
func startedFromNote(from *wire.StartedFrom) string {
	who := from.Who
	if who == "" {
		who = "An agent"
	}
	if from.Machine == "" {
		return who + " on another machine started this session with start_session."
	}
	return who + " on " + from.Machine + " started this session with start_session."
}
