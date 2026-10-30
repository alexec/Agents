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
	home := d.personalHome()
	if home == "" {
		return "", Invalid("Nothing was asked: this machine has no personal home to keep a secret in.")
	}
	l, err := d.asker(id, "A secret can only be asked for while this agent is working.")
	if err != nil {
		return "", err
	}
	path := skillcatalog.SecretsPath(home)
	secret := wire.ElicitationSecret{Name: name, IsSet: skillcatalog.LoadSecrets(path).IsSet(name)}
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
	return secretNote(name, path, r.action), nil
}

// secretNote is the words an agent reads for the answer to its ask_secret: the name and
// where it is, never the value.
func secretNote(name, path string, action wire.AnswerElicitationRequestAction) string {
	switch action {
	case wire.AnswerElicitationRequestActionAccept:
		return name + " is saved in the person's secrets file, " + path + " (NAME=value lines, readable only by this user). " +
			"Use it without printing it, for example `" + name + "=\"$(sed -n 's/^" + name + "=//p' " + path + ")\" your-command`, " +
			"or as ${" + name + "} in a connector in .agents/mcp.json. Never echo, cat or log it, and never write it into a file in the folder."
	case wire.AnswerElicitationRequestActionDecline:
		return "They chose not to give " + name + ". Carry on without it, or say what you cannot do without it."
	}
	return "They cancelled, and gave no " + name + "."
}

// secretAnswered is what the record keeps of an answered ask_secret: that it was saved.
func secretAnswered(s wire.ElicitationSecret, action wire.AnswerElicitationRequestAction) []wire.ElicitationAnswer {
	if action != wire.AnswerElicitationRequestActionAccept {
		return nil
	}
	return []wire.ElicitationAnswer{{Question: s.Name, Answer: "Saved to your secrets"}}
}

// saveAskedSecret saves the value typed into a secret's form. An error is the person's to
// read on the card, and never holds the value.
func (d *Daemon) saveAskedSecret(s wire.ElicitationSecret, content map[string]wire.JSONValue) error {
	v, _ := text(value(content[secretField]))
	v = strings.TrimSpace(v)
	if v == "" {
		return Invalid("Type %s, or choose No thanks.", s.Name)
	}
	if strings.ContainsAny(v, "\n\r\x00") {
		return Invalid("%s has to be one line.", s.Name)
	}
	if err := d.saveSecret(s.Name, v); err != nil {
		return Invalid("%s was not saved: %s", s.Name, err.Error())
	}
	log.Printf("ask_secret: saved %s", s.Name)
	return nil
}

// saveSecret sets one secret in the person's secrets.env, and tells the connectors.
func (d *Daemon) saveSecret(name, value string) error {
	home := d.personalHome()
	if home == "" {
		return errors.New("this machine has no personal home")
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
	d.mcpChanged()
	return nil
}
