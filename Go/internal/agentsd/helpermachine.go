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
// that machine's own agents/start. The person says yes first, every time. The session is
// not in this folder, so this folder's limits do not count it and the tools for an agent's
// own sessions do not reach it.

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
	// That machine's path: no link on this one is followed.
	r.Cwd = store.PathURL(folder)
	r.StartedFrom = &wire.StartedFrom{Agent: me.ID}
	title := titleFrom(r.Prompt)
	yes, err := d.personSaysYes(me.ID, d.agentWho(me.ID)+" wants to start a session on "+machine,
		fmt.Sprintf("Start a session on %s, in %s, to %s?", machine, folder, quotedTitle(&title)), "Start it")
	if err != nil {
		return "", err
	}
	if !yes {
		return "Nothing was started: the person said no, or didn’t answer.", nil
	}
	out, err := d.askWorkspaces(me.ID, sessionOnMachine, wire.MachineSessionStart{Host: machine, Start: r})
	if e, ok := err.(*Error); ok && e.Code == wire.FailureKept {
		return fmt.Sprintf("%s is starting: the session starts in %s when it connects. It is not in this folder, so the tools for your sessions don’t reach it; the person sees it under %s.",
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
	return fmt.Sprintf("Started %s on %s, in %s (id %s). It is not in this folder, so the tools for your sessions don’t reach it; the person sees it under %s.",
		quotedTitle(&title), machine, folder, id, machine), nil
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
