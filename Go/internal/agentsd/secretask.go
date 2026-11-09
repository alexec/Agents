package agentsd

import (
	"encoding/json"
	"errors"
	"log"
	"regexp"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// ask_secret (#2885): an agent asks for one named secret, the person types it into a masked
// field on any client, and the host saves it to their secrets.env, the file Settings ▸
// Secrets and the connectors' ${NAME} read. The value is never in the record, the logs,
// the Brief or what the agent is told: they say the name was saved, and where.

// secretField is the one field of a secret's form.
const secretField = "value"

// sessionOnlyField is the answer's choice to keep it for this session only (#3548): not a
// field of the form, so a client that does not offer it sends none, and it goes to secrets.env.
const sessionOnlyField = "sessionOnly"

// needsApprovalField is the answer's Ask before use (#4014): left out is on.
const needsApprovalField = "needsApproval"

// descriptionField is the answer's description (#4167), as the person left it on the card:
// left out, the secret keeps the one it has.
const descriptionField = "description"

var secretAskName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,63}$`)

// askSecret is ask_secret: the person asked for a secret, as a form held like ask_question's.
func (d *Daemon) askSecret(id wire.UUID, args map[string]json.RawMessage) (string, error) {
	name, reason := strings.TrimSpace(argString(args, "name")), strings.TrimSpace(argString(args, "reason"))
	if !secretAskName.MatchString(name) {
		return "", Invalid("Nothing was asked: `name` is the secret's name, letters, digits and underscores, e.g. OPENAI_API_KEY.")
	}
	if reason == "" {
		return "", Invalid("Nothing was asked: say in `reason` what you need %s for.", name)
	}
	description, err := secretDescription(argString(args, "secret_description"))
	if err != nil {
		return "", Invalid("Nothing was asked: %s", err.Error())
	}
	home := d.personalHome()
	if home == "" {
		return "", Invalid("Nothing was asked: this machine has no personal home to keep a secret in.")
	}
	l, err := d.asker(id, "A secret can only be asked for while this agent is working.")
	if err != nil {
		return "", err
	}
	sessionOnly, ask := true, d.keepsFlagged()
	secret := wire.ElicitationSecret{Name: name, IsSet: secretIsSet(home, name),
		CanBeSessionOnly: &sessionOnly, CanAskBeforeUse: &ask}
	if description != "" {
		secret.Description = &description
	}
	if u := strings.TrimSpace(argString(args, "url")); strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") {
		secret.URL = &u
	}
	// Titled so a notification and an older client say what it is: "Asks: OPENAI_API_KEY (a secret)".
	title := name + " (a secret)"
	schema := wire.ElicitationSchema{Title: &title, Properties: []wire.ElicitationSchemaProperty{{Name: secretField, Title: &reason,
		IsRequired: true, Kind: wire.ElicitationSchemaPropertyKind{String: &wire.ElicitationSchemaPropertyKindString{}}}}}
	req := wire.ElicitationRequest{ID: store.NewUUID(), AgentID: id, Message: &name, Secret: &secret,
		Mode: wire.ElicitationRequestMode{Form: &wire.ElicitationRequestModeForm{Value: schema}}, Scope: wire.ElicitationRequestScopeSession,
		AskedAt: now()}
	r, answered := l.holdAskedForm(req)
	if !answered {
		return formStillOpen, nil
	}
	return d.secretNote(id, name, r.action), nil
}

// secretNote is the words an agent reads for the answer to its ask_secret: the name and
// where it is, never the value.
func (d *Daemon) secretNote(agent wire.UUID, name string, action wire.AnswerElicitationRequestAction) string {
	path := skillcatalog.SecretsPath(d.personalHome())
	switch action {
	case wire.AnswerElicitationRequestActionAccept:
		if d.secretIsSealed(agent, name) {
			return name + " is saved with Ask before use: it is sealed on this machine, and it is not in your environment " +
				"or in a file you can read. Use it with fill_secret or set_ci_secret, which put it where it goes for you, " +
				"or as ${" + name + "} in the url or a header of an http server in .agents/mcp.json, which agentsd fills on each request from your next start; " +
				"a stdio server never gets it. " +
				"A person approves each use: the call waits for them, or tells you which request to wait on with wait_for_event."
		}
		if _, ok, _ := d.sessionSecret(agent, name); ok {
			return name + " is kept for this session only, and deleted when the session is archived (#3548). " +
				"It is in your environment as $" + name + " from your next start, and fills ${" + name + "} in your MCP servers. " +
				"To type it into a page, call fill_secret with secret " + name + ". " +
				"Read it now, without printing it, from " + d.sessionSecretsPath(agent) + " (JSON; .secrets." + name + ".value). " +
				"Never echo, cat or log it, and never write it into a file in the folder."
		}
		return name + " is saved in the person's secrets file, " + path + " (NAME=value lines, readable only by this user). " +
			"Use it without printing it, for example `" + name + "=\"$(sed -n 's/^" + name + "=//p' " + path + ")\" your-command`, " +
			"or as ${" + name + "} in a connector in .agents/mcp.json. Never echo, cat or log it, and never write it into a file in the folder."
	case wire.AnswerElicitationRequestActionDecline:
		return "They chose not to give " + name + ". Carry on without it, or say what you cannot do without it."
	}
	return "They cancelled, and gave no " + name + "."
}

// secretAnswered is what the record keeps of an answered ask_secret: that it was saved,
// and where.
func secretAnswered(s wire.ElicitationSecret, action wire.AnswerElicitationRequestAction, sessionOnly bool) []wire.ElicitationAnswer {
	if action != wire.AnswerElicitationRequestActionAccept {
		return nil
	}
	if sessionOnly {
		return []wire.ElicitationAnswer{{Question: s.Name, Answer: "Saved for this session only"}}
	}
	return []wire.ElicitationAnswer{{Question: s.Name, Answer: "Saved to your secrets"}}
}

// askedSessionOnly is whether the answer keeps the secret for this session only (#3548).
func askedSessionOnly(content map[string]wire.JSONValue) bool {
	b, _ := value(content[sessionOnlyField]).(bool)
	return b
}

// askedNeedsApproval is Ask before use for a typed answer (#4014): on, as for every secret an
// agent adds, unless the person turned it off on the card (#4016), which only a person's
// client answers. A machine that cannot keep one (keepsFlagged) offered no toggle, so the
// value is kept without the flag.
func askedNeedsApproval(content map[string]wire.JSONValue) bool {
	b, set := value(content[needsApprovalField]).(bool)
	return !set || b
}

// saveAskedSecret saves the value typed into a secret's form: for the asking session only,
// or to secrets.env. An error is the person's to read on the card, and never holds the value.
func (d *Daemon) saveAskedSecret(agent wire.UUID, s wire.ElicitationSecret, content map[string]wire.JSONValue) error {
	v, _ := text(value(content[secretField]))
	v = strings.TrimSpace(v)
	if v == "" {
		return Invalid("Type %s, or choose No thanks.", s.Name)
	}
	if strings.ContainsAny(v, "\n\r\x00") {
		return Invalid("%s has to be one line.", s.Name)
	}
	ask := askedNeedsApproval(content) && d.keepsFlagged()
	description, given := text(value(content[descriptionField]))
	if !given && s.Description != nil {
		description = *s.Description
	}
	description, err := secretDescription(description)
	if err != nil {
		return err
	}
	if askedSessionOnly(content) {
		return d.setSessionSecret(agent, s.Name, v, description, ask)
	}
	if err := d.saveSecret(s.Name, v, ask); err != nil {
		return Invalid("%s was not saved: %s", s.Name, err.Error())
	}
	if given || description != "" {
		if err := setSecretDescription(d.personalHome(), s.Name, description); err != nil {
			log.Printf("ask_secret: %s's description: %v", s.Name, err)
		}
	}
	log.Printf("ask_secret: saved %s", s.Name)
	return nil
}

// saveSecret sets one secret, and tells the connectors. needsApproval keeps it sealed
// (sealedsecrets.go), out of secrets.env; off writes the line and takes out any sealed copy.
// An agent's write always passes true (#4014).
func (d *Daemon) saveSecret(name, value string, needsApproval bool) error {
	home := d.personalHome()
	if home == "" {
		return errors.New("this machine has no personal home")
	}
	if needsApproval {
		if err := d.saveSealedSecret(home, name, value, "", true); err != nil {
			return err
		}
		d.mcpChanged()
		return nil
	}
	path := skillcatalog.SecretsPath(home)
	env, err := skillcatalog.LoadSecretsForChange(path)
	if err != nil {
		return err
	}
	env.Set(name, value)
	if err := env.Save(path); err != nil {
		return errors.New("secrets.env could not be written")
	}
	if err := d.removeSealedSecret(home, name); err != nil {
		return errors.New("sealed.json could not be written")
	}
	d.mcpChanged()
	return nil
}
