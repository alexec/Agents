package agentsd

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controlplane/usersettings"
	"github.com/alexec/agents/Go/wire"
)

// list_secrets (#4167): the person's secrets and the calling session's own, each with its name,
// description, kind, Ask before use and whether this machine has a copy. Never a value, and
// never the last 4 (#4155): those are for a person. It reads files and the last sync only, so
// it never waits on a person.
//
// A description is not secret. One the control plane sent is in the sync state
// (usersettings.go); one typed on the ask_secret card for a secret of this machine only is in
// ~/.agents-secrets/descriptions.json, beside secrets.env; a session's own is in its file.

// secretListLine is one line of list_secrets.
type secretListLine struct {
	Name          string `json:"name"`
	Description   string `json:"description"`
	Kind          string `json:"kind,omitempty"`
	NeedsApproval bool   `json:"needsApproval,omitempty"`
	HereToo       bool   `json:"onThisMachine"`
	SessionOnly   bool   `json:"sessionOnly,omitempty"`
}

func secretDescriptionsPath(home string) string {
	return filepath.Join(home, ".agents-secrets", "descriptions.json")
}

// readSecretDescriptions is descriptions.json; missing or unreadable reads as none.
func readSecretDescriptions(home string) map[string]string {
	out := map[string]string{}
	if b, err := os.ReadFile(secretDescriptionsPath(home)); err == nil {
		json.Unmarshal(b, &out)
	}
	return out
}

// setSecretDescription keeps the description of a secret of this machine; empty takes it out.
func setSecretDescription(home, name, description string) error {
	all := readSecretDescriptions(home)
	if all[name] == description {
		return nil
	}
	if description == "" {
		delete(all, name)
	} else {
		all[name] = description
	}
	p := secretDescriptionsPath(home)
	if len(all) == 0 {
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(all)
	if err != nil {
		return err
	}
	return store.WriteAtomically(p, b, 0o600)
}

// secretDescription is a description as a person or an agent gave it: trimmed, and refused
// when it is too long or looks like a value, as the control plane refuses it.
func secretDescription(text string) (string, error) {
	d, err := usersettings.CheckSecretDescription(&text)
	if err != nil {
		_, words, _ := strings.Cut(err.Error(), ": ")
		return "", Invalid("%s", words)
	}
	return d, nil
}

// listSecrets is list_secrets.
func (d *Daemon) listSecrets(agent wire.UUID, _ map[string]json.RawMessage) (string, error) {
	return secretListNote(d.secretList(agent)), nil
}

// secretList is every secret the calling session can name: its own first, then this
// machine's, then the person's that are not here yet.
func (d *Daemon) secretList(agent wire.UUID) []secretListLine {
	var out []secretListLine
	seen := map[string]bool{}
	add := func(l secretListLine) {
		if seen[l.Name] {
			return
		}
		seen[l.Name] = true
		out = append(out, l)
	}
	var session []secretListLine
	for n, v := range d.readSessionSecrets(agent).Secrets {
		session = append(session, secretListLine{Name: n, Description: v.Description, NeedsApproval: v.Sealed != nil, HereToo: true, SessionOnly: true})
	}
	sort.Slice(session, func(i, j int) bool { return session[i].Name < session[j].Name })
	for _, l := range session {
		add(l)
	}
	home := d.personalHome()
	if home == "" {
		return out
	}
	d.userScopeMu.Lock()
	mark := d.userMarkLocked()
	d.userScopeMu.Unlock()
	sent := map[string]wire.UserSecretAbout{}
	for _, a := range mark.About {
		sent[string(a.Name)] = a
	}
	local := readSecretDescriptions(home)
	names := skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)).Names()
	for n := range readSealedSecrets(home).Secrets {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		l := secretListLine{Name: n, Description: local[n], NeedsApproval: isSealedSecret(home, n), HereToo: true}
		if a, ok := sent[n]; ok {
			l.Description, l.Kind = aboutText(a.Description), aboutKind(a.Kind)
		}
		add(l)
	}
	waiting := append([]wire.UserSecretAbout(nil), mark.Waiting...)
	sort.Slice(waiting, func(i, j int) bool { return waiting[i].Name < waiting[j].Name })
	for _, a := range waiting {
		add(secretListLine{Name: string(a.Name), Description: aboutText(a.Description), Kind: aboutKind(a.Kind),
			NeedsApproval: a.NeedsApproval != nil && *a.NeedsApproval})
	}
	return out
}

func aboutText(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func aboutKind(k *wire.UserSecretKind) string {
	if k == nil {
		return ""
	}
	return string(*k)
}

// secretListNote is the words list_secrets gives: a JSON line a secret.
func secretListNote(all []secretListLine) string {
	if len(all) == 0 {
		return "There are no secrets. Ask for one with ask_secret."
	}
	var b strings.Builder
	b.WriteString("Each secret's name, never its value. Use one by its name. onThisMachine false: it is the person's, " +
		"but not on this machine yet; it comes when one of their apps seals it here. sessionOnly: this session's own.\n")
	for _, l := range all {
		if strings.TrimSpace(l.Description) == "" {
			l.Description = noDescription
		}
		line, _ := json.Marshal(l)
		b.Write(line)
		b.WriteByte('\n')
	}
	return strings.TrimSuffix(b.String(), "\n")
}
