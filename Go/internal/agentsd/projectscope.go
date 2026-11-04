package agentsd

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The agent tools scoped to the project (#3277, specs/3273-project-unit "Agent tools:
// scoped to the project"). list_sessions, read_session, message_session, cancel_message
// and wait_for_agents reach every session of the agent's project: those in this machine's
// folders of it, and, through the control plane, those on the person's other machines
// (machines/projectSessions). start_session with machine alone starts in the project's
// folder there (machines/projectFolders). A folder in no project, or a machine on no
// control plane, works as before: the project is the folders on this machine. Who may stop
// or archive a session does not change.

const (
	projectSessionsMethod = "machines/projectSessions"
	projectFoldersMethod  = "machines/projectFolders"
	// projectSessionsAsk bounds the control plane's answer: it asks each machine for at most
	// 5 seconds of its own.
	projectSessionsAsk = 8 * time.Second
)

// projectSessionsHere is the sessions of folder's project on this machine, most recent
// first: the folder's own, and those of every other folder here that names the same
// project. A folder in no project has only its own.
func (d *Daemon) projectSessionsHere(folder string) []wire.Agent {
	project := projectOfFolder(folder)
	if project == "" {
		return d.folderSessions(folder)
	}
	projects := projectsOfFolders{folder: project}
	var out []wire.Agent
	for _, a := range d.Store.Agents() {
		if f := folderPath(&a); f == folder || projects.of(&a) == project {
			out = append(out, a)
		}
	}
	return latestFirst(out)
}

// sameProject says a is in folder, or in another folder here of folder's project.
func sameProject(folder string, a *wire.Agent) bool {
	if f := folderPath(a); f == folder {
		return true
	} else if p := projectOfFolder(folder); p != "" {
		return projectOfFolder(f) == p
	}
	return false
}

// scopeWords is "this project" for a folder in one, else "this folder".
func scopeWords(folder string) string {
	if projectOfFolder(folder) != "" {
		return "this project"
	}
	return "this folder"
}

// projectElsewhere is the sessions of caller's project on the person's other machines, and
// the machines that did not answer. ok is false with no project or no control plane; err is
// why the control plane gave none.
func (d *Daemon) projectElsewhere(caller *wire.Agent, includeArchived bool) (sessions []wire.ProjectSession, unreached []wire.ProjectMachine, ok bool, err error) {
	project := projectOfFolder(folderPath(caller))
	if project == "" || d.askControl.Load() == nil {
		return nil, nil, false, nil
	}
	sessions, unreached, err = d.projectSessionsElsewhere(caller.ID, project, includeArchived)
	if err != nil {
		return nil, nil, true, err
	}
	return sessions, unreached, true, nil
}

// elsewhereNamed is the session of caller's project on another machine that value names,
// by id or exact title, as a record callThere can call; nil when none is, with the words
// for a title that more than one has.
func (d *Daemon) elsewhereNamed(caller *wire.Agent, value string) (*startedThere, string) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, ""
	}
	sessions, _, ok, err := d.projectElsewhere(caller, true)
	if !ok || err != nil {
		return nil, ""
	}
	var titled []wire.ProjectSession
	for _, s := range sessions {
		if strings.EqualFold(string(s.Session.ID), value) {
			return projectRecord(caller.ID, s), ""
		}
		if s.Session.Title != nil && *s.Session.Title == value {
			titled = append(titled, s)
		}
	}
	switch len(titled) {
	case 0:
		return nil, ""
	case 1:
		return projectRecord(caller.ID, titled[0]), ""
	}
	var matches []string
	for _, s := range titled {
		matches = append(matches, string(s.Session.ID)+" on "+s.MachineName+", "+sessionStatus(&s.Session)+", "+isoWhen(s.Session.LastActivityAt))
	}
	return nil, "More than one session is named “" + value + "”: " + strings.Join(matches, "; ") + ". Read one by id."
}

// projectRecord is a session of the project on another machine as a record of elsewhere.go.
func projectRecord(caller wire.UUID, s wire.ProjectSession) *startedThere {
	title := "Untitled"
	if s.Session.Title != nil {
		title = *s.Session.Title
	}
	return &startedThere{Machine: s.MachineName, Session: s.Session.ID, Starter: caller,
		There: store.FolderPath(s.Session.Cwd), Title: title, At: now()}
}

// callMember is callThere for a session of caller's project it may not have started.
func (d *Daemon) callMember(caller *wire.Agent, s *startedThere, call wire.SessionCall) (wire.SessionCallReply, error) {
	project := projectOfFolder(folderPath(caller))
	call.Project = &project
	return d.callThere(caller.ID, s, call, 0)
}

// readElsewhere is read_session on a session of the project on another machine.
func (d *Daemon) readElsewhere(caller *wire.Agent, s *startedThere) (string, error) {
	reply, err := d.callMember(caller, s, wire.SessionCall{Op: "read"})
	if err != nil {
		return "", err
	}
	return reply.Said, nil
}

// messageElsewhere is message_session to a session of the project on another machine.
func (d *Daemon) messageElsewhere(me *wire.Agent, s *startedThere, text string, replace bool) (string, error) {
	if !replace && !d.spendMessage(me.ID) {
		return "", refusedMessage(fmt.Sprintf("this session has sent %d messages in the last hour, the most it may.", messagesPerHour))
	}
	reply, err := d.callMember(me, s, wire.SessionCall{Op: "message", Message: &text, Replace: &replace})
	if err != nil {
		if e, ok := err.(*Error); ok && !strings.HasPrefix(e.Message, "Nothing") {
			return "", refusedMessage(e.Message)
		}
		return "", err
	}
	return reply.Said, nil
}

// waitElsewhere is the session of caller's project on another machine that
// wait_for_agents names, kept so its end comes back (#3277); nil when name is none.
func (d *Daemon) waitElsewhere(name string, caller *wire.Agent) (*wire.Agent, error) {
	s, ambiguous := d.elsewhereNamed(caller, name)
	if ambiguous != "" {
		return nil, blockRefusal(strings.ReplaceAll(ambiguous, "Read one by id.", "Use the id."))
	}
	if s == nil {
		return nil, nil
	}
	watch := true
	reply, err := d.callMember(caller, s, wire.SessionCall{Op: "status", Watch: &watch})
	if err != nil {
		_, msg := errMessage(err)
		return nil, blockRefusal(quotedTitle(&s.Title) + " on " + s.Machine + " could not be asked how it stands: " + strings.TrimSuffix(msg, ".") + ".")
	}
	if reply.Ended != nil {
		e := wire.WaitEnding{How: *reply.Ended}
		return nil, blockRefusal(quotedTitle(&s.Title) + " has already ended (" + endingSummary(&e) + "). Read it with read_session rather than waiting on it.")
	}
	d.noteWatched(*s)
	title := s.Title
	return &wire.Agent{ID: s.Session, Title: &title}, nil
}

// projectFolderOn is the folder of me's project on machine, for start_session with
// machine alone: refused when the project has none there, or more than one.
func (d *Daemon) projectFolderOn(me *wire.Agent, machine string) (string, error) {
	project := projectOfFolder(folderPath(me))
	if project == "" {
		return "", Invalid("Nothing was started: this folder is in no project, so say which folder on %s, as an absolute path.", machine)
	}
	out, err := d.askWorkspaces(me.ID, projectFoldersMethod, wire.ProjectFoldersRequest{Project: project})
	if err != nil {
		_, msg := errMessage(err)
		return "", Invalid("Nothing was started: the project's folders could not be found (%s). Say which folder on %s, as an absolute path.",
			strings.TrimSuffix(msg, "."), machine)
	}
	var listed wire.ProjectFolders
	if json.Unmarshal(out, &listed) != nil {
		return "", &Error{Code: wire.FailureNotSupported, Message: "Nothing was started: the control plane's answer could not be read."}
	}
	var with []string
	for _, m := range listed.Machines {
		with = append(with, m.MachineName)
		if !strings.EqualFold(m.MachineName, machine) && !strings.EqualFold(string(m.Machine), machine) {
			continue
		}
		switch len(m.Folders) {
		case 0:
		case 1:
			return m.Folders[0], nil
		default:
			return "", Invalid("Nothing was started: this project has %d folders on %s (%s). Say which, in folder.",
				len(m.Folders), machine, strings.Join(m.Folders, ", "))
		}
	}
	others := "no other machine has one"
	if len(with) > 0 {
		others = "it has one on " + strings.Join(with, ", ")
	}
	return "", Invalid("Nothing was started: this project has no folder on %s (%s). Say which folder there, as an absolute path, "+
		"or send this branch there with send and folder.", machine, others)
}
