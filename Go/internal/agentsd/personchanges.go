package agentsd

import (
	"encoding/json"
	"log"
	"path/filepath"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// A change that is the person's to make, asked by an agent (#4538). An agent may not turn on
// a workflow of its folder that the person must turn on (its file says enabled: false, an
// agent wrote it, or the person turned it off), nor approve a server waiting in its folder's
// .agents/mcp.json: the agent role reaches neither workflows/enable nor mcp/approve (roles.go).
// manage_workflows enable and manage_connectors approve ask the person instead, as a secret's
// use does (secretuse.go): a Needs you request of kind approve, use workflow or connector,
// that names the workflow or the server, the folder and the session. The answers are once
// (Approve) and deny. On Approve agentsd makes the change itself, as the person's own client
// would (enableWorkflow by "person", mcpApprove), so no role gets wider and the person's
// answer is the only way the change happens. A connector's request keeps the entry's digest:
// Approve approves only the entry the agent asked for, not one changed since.

// personChange is whether use is one of these.
func personChange(use wire.SecretUse) bool {
	return use == wire.SecretUseWorkflow || use == wire.SecretUseConnector
}

// changePlace is the folder as the request names it: its name, not its whole path.
func changePlace(folder string) string { return filepath.Base(filepath.Clean(folder)) }

// personChangeWaitWords is a call held on its request past the hold.
func personChangeWaitWords(r wire.RequestSecretUse, id wire.UUID) string {
	what, call := "turning on the workflow "+r.Name, "manage_workflows enable"
	if r.Use == wire.SecretUseConnector {
		what, call = "approving the connector "+r.Name, "manage_connectors approve"
	}
	return "Nothing was changed yet: " + what + " in " + r.Place + " is the person's choice, and they have not answered yet. " +
		"Wait with wait_for_event, where: {\"request\": \"" + string(id) + "\"}, then call " + call + " again."
}

// errPersonChangeDenied is a change a person denied, or whose request was dropped.
type errPersonChangeDenied struct{ ask wire.RequestSecretUse }

func (e errPersonChangeDenied) Error() string {
	if e.ask.Use == wire.SecretUseConnector {
		return "The person did not approve the connector " + e.ask.Name + " in " + e.ask.Place +
			" (they denied it, or its entry changed after you asked). Do not ask again for the same entry; carry on without it, or say what you cannot do without it."
	}
	return "The person did not turn on the workflow " + e.ask.Name + " in " + e.ask.Place +
		". Do not ask again; carry on without it, or say what you cannot do without it."
}

// askPersonChange is whether the person approved this change now: "" when they did (agentsd
// made it already); the words to give the agent while the request is open; or an
// errPersonChangeDenied. Nobody answers on a machine only agents use, so there it refuses.
func (d *Daemon) askPersonChange(agent wire.UUID, ask wire.RequestSecretUse, refusal error) (string, error) {
	if d.agentsOnly() {
		return "", refusal
	}
	if d.secretUseAllowed(agent, ask.Name, ask.Use, ask.Place) {
		return "", nil
	}
	return d.holdOnUse(agent, ask, formHoldLimit)
}

// answerPersonChange is requests/answer for a workflow or a connector: Approve makes the
// change as the person, then ends the request and wakes the held call.
func (d *Daemon) answerPersonChange(rec wire.Request, a *wire.RequestSecretUseAnswer, by *wire.AuditActor) (wire.RequestUpdate, error) {
	if rec.AskedBy == nil {
		return wire.RequestUpdate{}, Invalid("This request has no session.")
	}
	ask := *rec.Detail.SecretUse
	if a.Action != secretUseOnce && a.Action != secretUseDeny {
		return wire.RequestUpdate{}, Invalid("This request takes once (Approve) or deny.")
	}
	folder := store.FolderPath(wire.URL(rec.Folder))
	summary := "Denied"
	if a.Action == secretUseOnce {
		var err error
		if summary, err = d.makePersonChange(folder, ask); err != nil {
			return wire.RequestUpdate{}, err
		}
	}
	agent := *rec.AskedBy
	if a.Action == secretUseOnce && !strings.HasPrefix(summary, "Not approved") {
		key := secretUseKey(agent, ask.Name, ask.Use, ask.Place)
		d.secretUseMu.Lock()
		if d.secretUseOnceLeft == nil {
			d.secretUseOnceLeft = map[string]int{}
		}
		d.secretUseOnceLeft[key]++
		d.secretUseMu.Unlock()
	}
	if !d.endRequest(rec.ID, wire.RequestStateAnswered, &summary, "", by) {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already."}
	}
	log.Printf("person change: %s %s in %s for %s: %s", ask.Use, ask.Name, ask.Place, agent, a.Action)
	d.secretUseEnded(rec.ID)
	after := d.request(rec.ID)
	if after == nil {
		after = &rec
	}
	return wire.RequestUpdate{Request: *after}, nil
}

// makePersonChange is the change an Approve makes: the request's summary, or an error that
// leaves the request open (the person can Deny it).
func (d *Daemon) makePersonChange(folder string, ask wire.RequestSecretUse) (string, error) {
	if ask.Use == wire.SecretUseWorkflow {
		if _, err := d.enableWorkflow(wire.WorkflowEnableRequest{Folder: store.FolderURL(folder), WorkflowID: ask.Name, Enabled: true}, "person"); err != nil {
			return "", err
		}
		return "Approved: " + ask.Name + " is on", nil
	}
	digest := ""
	if ask.Digest != nil {
		digest = *ask.Digest
	}
	dest := wire.SkillDestination{Kind: wire.SkillDestinationKindFolder, Folder: &folder}
	if row, ok := d.folderServer(dest, ask.Name); !ok || row.EntryDigest != digest {
		// The entry changed after the agent asked: the person saw another one.
		return "Not approved: " + ask.Name + "'s entry changed after the agent asked", nil
	}
	if _, err := d.mcpApprove(wire.MCPApproveRequest{Destination: dest, Name: ask.Name, Digest: digest}); err != nil {
		return "", err
	}
	return "Approved: " + ask.Name + " may start", nil
}

// folderServer is one server of a folder's .agents/mcp.json, as mcp/list gives it.
func (d *Daemon) folderServer(dest wire.SkillDestination, name string) (wire.FolderMCPServer, bool) {
	list, err := d.mcpList(dest)
	if err != nil {
		return wire.FolderMCPServer{}, false
	}
	for _, s := range list.Servers {
		if s.Name == name {
			return s, true
		}
	}
	return wire.FolderMCPServer{}, false
}

// manageConnectors is manage_connectors (#4538): list the folder's servers, or ask the person
// to approve one that waits.
func (d *Daemon) manageConnectors(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	a := d.Store.Agent(caller)
	if a == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was changed."}
	}
	folder := folderPath(a)
	dest := wire.SkillDestination{Kind: wire.SkillDestinationKindFolder, Folder: &folder}
	switch action := argString(args, "action"); action {
	case "", "list":
		list, err := d.mcpList(dest)
		if err != nil {
			return "", err
		}
		if list.Problem != nil {
			return "This folder's .agents/mcp.json could not be read: " + *list.Problem, nil
		}
		if len(list.Servers) == 0 {
			return "This folder has no connectors. They live in .agents/mcp.json.", nil
		}
		lines := []string{}
		for _, s := range list.Servers {
			line := "- " + s.Name + ": " + s.Summary
			if s.Approval.Waiting != nil {
				line += " [waiting for the person's approval]"
			} else {
				line += " [approved]"
			}
			if len(s.MissingSecrets) > 0 {
				line += " [this machine has no secret " + strings.Join(s.MissingSecrets, ", ") + "]"
			}
			lines = append(lines, line)
		}
		return strings.Join(lines, "\n"), nil
	case "approve":
		name := strings.TrimSpace(argString(args, "name"))
		if name == "" {
			return "", Invalid("Nothing was done: approve needs `name`, the server's name as list gives it.")
		}
		row, ok := d.folderServer(dest, name)
		if !ok {
			return "", Invalid("Nothing was done: this folder's .agents/mcp.json has no server %s. Call list to see its servers.", name)
		}
		if row.Approval.Waiting == nil {
			return name + " is approved already.", nil
		}
		digest := row.EntryDigest
		ask := wire.RequestSecretUse{Name: name, Use: wire.SecretUseConnector, Place: changePlace(folder), Digest: &digest}
		refusal := &Error{Code: CodeNotPermitted, Message: "Nothing was changed: " + name + " waits for the person's approval in Project Settings ▸ Agent Configuration ▸ Connectors, and nobody answers on this machine."}
		words, err := d.askPersonChange(caller, ask, refusal)
		if err != nil || words != "" {
			return words, err
		}
		if row, ok := d.folderServer(dest, name); ok && row.Approval.Waiting == nil {
			return "The person approved " + name + ". It starts for sessions in this folder from their next turn.", nil
		}
		return "", errPersonChangeDenied{ask}
	}
	return "", Invalid("Nothing was done: `action` has to be list or approve.")
}

// enableForPerson is manage_workflows enable of a workflow that is the person's to turn on:
// it asks them, and says what happened.
func (d *Daemon) enableForPerson(caller wire.UUID, folder, id string, refusal error) (string, error) {
	ask := wire.RequestSecretUse{Name: id, Use: wire.SecretUseWorkflow, Place: changePlace(folder)}
	words, err := d.askPersonChange(caller, ask, refusal)
	if err != nil || words != "" {
		return words, err
	}
	s, err := d.oneWorkflow(folder, id)
	if err != nil {
		return "", err
	}
	if !s.IsEnabled {
		return "", errPersonChangeDenied{ask}
	}
	note := "The person approved it: " + id + " is on, and its triggers run it."
	if s.AwaitingApproval != nil {
		note += " Its file still waits for their OK on the folder page, so it will not run until they approve it."
	}
	return note, nil
}
