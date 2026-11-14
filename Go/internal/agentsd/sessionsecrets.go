package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Secrets for this session only (#3548): a secret set from the ask_secret card or Settings ▸
// Secrets for one session. Only that session's agent can use it (fill_secret, its runtime's
// environment, ${NAME} in its MCP servers), and it is deleted when the session is archived or
// deleted. Then the agent is told it expired, never a value.
//
// It is kept on the machine that runs the session, and only there: never in secrets.env,
// never sent to the control plane or the person's other machines. One file per session,
// ~/.agents-secrets/sessions/<agent>.json, mode 0600, in the folder secrets.env is in. After
// the session is archived the file keeps the names only, so the agent can be told which
// expired. It goes with the record.
//
// A stopped or finished session is not ended: the person can carry it on, and its secret
// with it (Decided in #3548).

type sessionSecretsState struct {
	sessionSecretsMu sync.Mutex
}

// sessionSecretFile is one session's file. Values only while the session is not archived.
type sessionSecretFile struct {
	Secrets map[string]sessionSecretValue `json:"secrets,omitempty"`
	// Expired is the names it had when it was archived.
	Expired []string `json:"expired,omitempty"`
}

type sessionSecretValue struct {
	Value string `json:"value,omitempty"`
	// Sealed is a flagged one's value (#4014), in place of Value: sealedsecrets.go.
	Sealed *sealedValue `json:"sealed,omitempty"`
	SetAt  wire.Date    `json:"setAt"`
	// Description is what it is for (#4167): not secret, so it is there in clear.
	Description string `json:"description,omitempty"`
	// Created is when the name was first set; a new value keeps it. Hint is the value's last
	// 4, from secretHint (#4158).
	Created *wire.Date `json:"created,omitempty"`
	Hint    string     `json:"hint,omitempty"`
}

func (d *Daemon) sessionSecretsDir() string {
	home := d.personalHome()
	if home == "" {
		return ""
	}
	return filepath.Join(home, ".agents-secrets", "sessions")
}

func (d *Daemon) sessionSecretsPath(agent wire.UUID) string {
	dir := d.sessionSecretsDir()
	if dir == "" || !isAgentFileID(string(agent)) {
		return ""
	}
	return filepath.Join(dir, string(agent)+".json")
}

// isAgentFileID is a UUID of hex digits and dashes only, so a file name is never a path.
func isAgentFileID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, r := range s {
		switch {
		case i == 8 || i == 13 || i == 18 || i == 23:
			if r != '-' {
				return false
			}
		case r >= '0' && r <= '9', r >= 'a' && r <= 'f', r >= 'A' && r <= 'F':
		default:
			return false
		}
	}
	return true
}

// readSessionSecrets is one session's file; missing or unreadable reads as nothing.
func (d *Daemon) readSessionSecrets(agent wire.UUID) sessionSecretFile {
	var f sessionSecretFile
	if p := d.sessionSecretsPath(agent); p != "" {
		if b, err := os.ReadFile(p); err == nil {
			json.Unmarshal(b, &f)
		}
	}
	return f
}

// writeSessionSecretsLocked writes it whole, or removes it when it holds nothing.
func (d *Daemon) writeSessionSecretsLocked(agent wire.UUID, f sessionSecretFile) error {
	p := d.sessionSecretsPath(agent)
	if p == "" {
		return errors.New("this machine has no personal home")
	}
	if len(f.Secrets) == 0 && len(f.Expired) == 0 {
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	dir := filepath.Dir(p)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	os.Chmod(filepath.Dir(dir), 0o700)
	os.Chmod(dir, 0o700)
	b, err := json.Marshal(f)
	if err != nil {
		return err
	}
	return store.WriteAtomically(p, b, 0o600)
}

// sessionSecret is the value a session's agent has for name, and whether it expired: it was
// this session's, and the session was archived.
func (d *Daemon) sessionSecret(agent wire.UUID, name string) (value string, ok, expired bool) {
	f := d.readSessionSecrets(agent)
	if v, has := f.Secrets[name]; has {
		if v.Sealed == nil {
			return v.Value, true, false
		}
		plain, err := d.openSealedSecret(sealedSessionStore(agent), name, *v.Sealed)
		if err != nil {
			log.Printf("session secrets: %s for %s: %v", name, agent, err)
			return "", false, false
		}
		return plain, true, false
	}
	for _, n := range f.Expired {
		if n == name {
			return "", false, true
		}
	}
	return "", false, false
}

// sessionSecretValues is every value a session has, by name: for its runtime's environment
// and its MCP servers. A flagged one is never there (#4014).
func (d *Daemon) sessionSecretValues(agent wire.UUID) map[string]string {
	out := map[string]string{}
	if agent == "" {
		return out
	}
	for n, v := range d.readSessionSecrets(agent).Secrets {
		if v.Sealed == nil {
			out[n] = v.Value
		}
	}
	return out
}

// sessionSecretEnv is a session's secrets as NAME=value, for its runtime's environment.
func (d *Daemon) sessionSecretEnv(agent wire.UUID) []string {
	values := d.sessionSecretValues(agent)
	names := make([]string, 0, len(values))
	for n := range values {
		names = append(names, n)
	}
	sort.Strings(names)
	env := make([]string, 0, len(names))
	for _, n := range names {
		env = append(env, n+"="+values[n])
	}
	return env
}

// setSessionSecret keeps one secret for a session that is not archived; needsApproval keeps
// it sealed (#4014). description is what it is for (#4167), checked by secretDescription.
func (d *Daemon) setSessionSecret(agent wire.UUID, name, value, description string, needsApproval bool) error {
	a := d.Store.Agent(agent)
	if a == nil {
		return &Error{Code: CodeNoSuchAgent, Message: "That session is gone."}
	}
	if a.State == wire.AgentStateArchived {
		return Invalid("%s is archived, so a secret for it would be deleted at once.", agentTitle(a))
	}
	if !secretAskName.MatchString(name) {
		return Invalid("A secret's name is letters, digits and underscores, e.g. GITLAB_PASSWORD.")
	}
	if value == "" {
		return Invalid("Type %s's value.", name)
	}
	if strings.ContainsAny(value, "\n\r\x00") {
		return Invalid("%s has to be one line.", name)
	}
	entry := sessionSecretValue{Value: value, SetAt: now(), Description: description}
	if needsApproval {
		sealed, err := d.sealSecret(sealedSessionStore(agent), name, value, nil)
		if err != nil {
			log.Printf("session secrets: %s for %s: %v", name, agent, err)
			return Invalid("%s was not saved: it could not be sealed on this machine.", name)
		}
		entry = sessionSecretValue{Sealed: &sealed, SetAt: sealed.SetAt, Description: description}
	}
	d.sessionSecretsMu.Lock()
	f := d.readSessionSecrets(agent)
	if f.Secrets == nil {
		f.Secrets = map[string]sessionSecretValue{}
	}
	old, had := f.Secrets[name]
	entry.Hint, entry.Created = secretHint(value, nil), new(entry.SetAt)
	if had && old.Created != nil {
		entry.Created = old.Created
	}
	if had && old.Sealed != nil && entry.Sealed != nil {
		// A new value is not a new place: the grants stay (#4015).
		if sealed, err := d.sealSecret(sealedSessionStore(agent), name, value, old.Sealed.Grants); err == nil {
			entry.Sealed = &sealed
		}
	}
	f.Secrets[name] = entry
	f.Expired = slices.DeleteFunc(f.Expired, func(n string) bool { return n == name })
	err := d.writeSessionSecretsLocked(agent, f)
	d.sessionSecretsMu.Unlock()
	if err != nil {
		log.Printf("session secrets: %s for %s: %v", name, agent, err)
		return Invalid("%s was not saved: the session's secrets file could not be written.", name)
	}
	log.Printf("session secrets: saved %s for %s", name, agent)
	d.secretChanged(agent, name, map[bool]wire.SecretOperationWhat{false: wire.SecretOperationWhatAdded, true: wire.SecretOperationWhatReplaced}[had], true)
	d.mcpChanged()
	return nil
}

// removeSessionSecret takes one out now. The agent is told it expired, as after an archive.
func (d *Daemon) removeSessionSecret(agent wire.UUID, name string) error {
	d.sessionSecretsMu.Lock()
	f := d.readSessionSecrets(agent)
	if _, ok := f.Secrets[name]; !ok {
		d.sessionSecretsMu.Unlock()
		return nil
	}
	delete(f.Secrets, name)
	if !slices.Contains(f.Expired, name) {
		f.Expired = append(f.Expired, name)
	}
	err := d.writeSessionSecretsLocked(agent, f)
	d.sessionSecretsMu.Unlock()
	if err != nil {
		return &Error{Code: CodeInternal, Message: name + " was not removed: " + err.Error()}
	}
	log.Printf("session secrets: removed %s for %s", name, agent)
	d.secretChanged(agent, name, wire.SecretOperationWhatRemoved, true)
	d.mcpChanged()
	return nil
}

// expireSessionSecrets is a session's archive: its values go, its names stay to say they
// expired.
func (d *Daemon) expireSessionSecrets(agent wire.UUID) {
	d.forgetSessionSecretUses(agent)
	d.sessionSecretsMu.Lock()
	defer d.sessionSecretsMu.Unlock()
	f := d.readSessionSecrets(agent)
	if len(f.Secrets) == 0 {
		return
	}
	for n := range f.Secrets {
		if !slices.Contains(f.Expired, n) {
			f.Expired = append(f.Expired, n)
		}
	}
	sort.Strings(f.Expired)
	f.Secrets = nil
	if err := d.writeSessionSecretsLocked(agent, f); err != nil {
		// Never leave a value behind: the file goes whole.
		log.Printf("session secrets: %s: %v; removing the file", agent, err)
		os.Remove(d.sessionSecretsPath(agent))
		return
	}
	log.Printf("session secrets: %s archived, its secrets deleted", agent)
}

// dropSessionSecrets is a session's deletion: the file goes, names and all.
func (d *Daemon) dropSessionSecrets(agent wire.UUID) {
	d.forgetSessionSecretUses(agent)
	d.sessionSecretsMu.Lock()
	defer d.sessionSecretsMu.Unlock()
	if p := d.sessionSecretsPath(agent); p != "" {
		os.Remove(p)
	}
}

// sweepSessionSecrets is the start's check: a session archived or deleted while the host
// was not running loses its secrets now.
func (d *Daemon) sweepSessionSecrets() {
	dir := d.sessionSecretsDir()
	if dir == "" {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		id, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok || !isAgentFileID(id) {
			continue
		}
		a := d.Store.Agent(wire.UUID(id))
		switch {
		case a == nil:
			d.dropSessionSecrets(wire.UUID(id))
		case a.State == wire.AgentStateArchived:
			d.expireSessionSecrets(wire.UUID(id))
		}
	}
}

// sessionSecretList is secrets/sessionList: every session's names, by title then name.
func (d *Daemon) sessionSecretList() wire.SessionSecrets {
	out := wire.SessionSecrets{Secrets: []wire.SessionSecret{}}
	dir := d.sessionSecretsDir()
	if dir == "" {
		return out
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		id, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok || !isAgentFileID(id) {
			continue
		}
		a := d.Store.Agent(wire.UUID(id))
		if a == nil || a.State == wire.AgentStateArchived {
			continue
		}
		for n, v := range d.readSessionSecrets(wire.UUID(id)).Secrets {
			// On this machine only, so never backed up (#4158).
			row := wire.SessionSecret{AgentID: a.ID, Title: agentTitle(a), Name: n, SetAt: v.SetAt, Created: v.Created, BackedUp: new(false)}
			if row.Created == nil {
				row.Created = new(v.SetAt)
			}
			if v.Hint != "" {
				row.Hint = new(v.Hint)
			}
			if op, ok := d.secretLastOp(n); ok {
				row.LastOp = &wire.SecretLastOp{What: op.What, At: op.At, Agent: op.Agent}
			}
			if v.Description != "" {
				row.Description = new(v.Description)
			}
			if v.Sealed != nil {
				row.NeedsApproval = new(true)
			}
			out.Secrets = append(out.Secrets, row)
		}
	}
	sort.Slice(out.Secrets, func(i, j int) bool {
		a, b := out.Secrets[i], out.Secrets[j]
		if a.Title != b.Title {
			return a.Title < b.Title
		}
		if a.AgentID != b.AgentID {
			return a.AgentID < b.AgentID
		}
		return a.Name < b.Name
	})
	return out
}

// Only the person's own clients reach these (Role.Allows): an agent's connection has none.
func (d *Daemon) registerSessionSecrets() {
	On(d, wire.CallSecretsSessionList, func(_ context.Context, _ *Client, _ wire.Empty) (wire.SessionSecrets, error) {
		return d.sessionSecretList(), nil
	})
	On(d, wire.CallSecretsSessionSet, func(_ context.Context, _ *Client, in wire.SessionSecretSetRequest) (wire.SessionSecrets, error) {
		ask := in.NeedsApproval != nil && *in.NeedsApproval
		description, err := secretDescription(aboutText(in.Description))
		if err != nil {
			return wire.SessionSecrets{}, err
		}
		if err := d.setSessionSecret(in.AgentID, strings.TrimSpace(in.Name), strings.TrimSpace(in.Value), description, ask); err != nil {
			return wire.SessionSecrets{}, err
		}
		return d.sessionSecretList(), nil
	})
	On(d, wire.CallSecretsSessionRemove, func(_ context.Context, _ *Client, in wire.SessionSecretRemoveRequest) (wire.SessionSecrets, error) {
		if err := d.removeSessionSecret(in.AgentID, strings.TrimSpace(in.Name)); err != nil {
			return wire.SessionSecrets{}, err
		}
		return d.sessionSecretList(), nil
	})
}

// setSessionNeedsApproval turns a session secret's flag on or off (#4014): its value is
// sealed in place, or opened back to plain.
func (d *Daemon) setSessionNeedsApproval(agent wire.UUID, name string, on bool) error {
	d.sessionSecretsMu.Lock()
	defer d.sessionSecretsMu.Unlock()
	f := d.readSessionSecrets(agent)
	v, ok := f.Secrets[name]
	if !ok {
		return Invalid("That session has no %s.", name)
	}
	switch {
	case on && v.Sealed == nil:
		sealed, err := d.sealSecret(sealedSessionStore(agent), name, v.Value, nil)
		if err != nil {
			return Invalid("%s was not changed: it could not be sealed on this machine.", name)
		}
		f.Secrets[name] = sessionSecretValue{Sealed: &sealed, SetAt: v.SetAt, Description: v.Description, Created: v.Created, Hint: v.Hint}
	case !on && v.Sealed != nil:
		plain, err := d.openSealedSecret(sealedSessionStore(agent), name, *v.Sealed)
		if err != nil {
			return Invalid("%s does not open on this machine, so it was left as it is.", name)
		}
		f.Secrets[name] = sessionSecretValue{Value: plain, SetAt: v.SetAt, Description: v.Description, Created: v.Created, Hint: v.Hint}
	default:
		return nil
	}
	if err := d.writeSessionSecretsLocked(agent, f); err != nil {
		return Invalid("%s was not changed: the session's secrets file could not be written.", name)
	}
	log.Printf("session secrets: %s for %s: Ask before use %v", name, agent, on)
	d.mcpChanged()
	return nil
}
