package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/diskjson"
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/skillcatalog"
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The record of each read and change of a secret (#4156). Each one raises an event on this
// machine's stream (secret.read, secret.denied, secret.changed), so wait_for_event and a
// workflow can use it, and goes to the control plane's audit (machine/secretOps). This machine
// keeps each secret's last operation in secret-ops.json, for the names it holds only, and a
// removed secret's goes with it. None of them has the value or its hint: only the name, the
// use and the place.
//
// The reads are agentsd's own: fill_secret (fill, the field's domain), set_ci_secret (ci,
// owner/repo), an HTTP MCP server's ${NAME} that agentsd fills on each request (mcp, the
// server's name, #4120), and what a session is given at its start (env: its own secrets as
// variables, place session, and each server's ${NAME}, place the server's name). secrets.env
// is a plain file that a runtime can read at any time: agentsd sees only what it gives.
//
// An MCP server's header is read on each request, so the audit has at most one entry per
// secret, session, use, place and minute, with a count: the reads wait up to secretOpsBatch
// and go together. A denial and a change go at once. A person's change in Settings ▸ Secrets
// is the control plane's own entry (user/setSecret, user/removeSecret): the machine raises its
// event only.

// secretOpsBatch is how long reads wait to go to the audit together; a test makes it shorter.
var secretOpsBatch = time.Minute

// secretOpsSaveEvery is how often a last read that only moved on is written down.
const secretOpsSaveEvery = time.Minute

// secretOpsAsk bounds the call that tells the control plane.
const secretOpsAsk = 20 * time.Second

// secretSessionPlace is env's place for a session's own secrets, given as its variables.
const secretSessionPlace = "session"

type secretOpBook struct {
	mu     sync.Mutex
	loaded bool
	// last is each secret's last operation, by its name: secret-ops.json.
	last  map[string]wire.SecretOperation
	saved time.Time
	// batch is the reads waiting for the audit, by secretOpKey; timer sends them.
	batch map[string]*wire.SecretOperation
	order []string
	timer *time.Timer
}

// secretOpKey is what one audit entry counts: a secret, a session, a use and a place.
func secretOpKey(op wire.SecretOperation) string {
	var agent wire.UUID
	var use wire.SecretOperationUse
	if op.Agent != nil {
		agent = *op.Agent
	}
	if op.Use != nil {
		use = *op.Use
	}
	return op.Name + "|" + string(agent) + "|" + string(use) + "|" + deref(op.Place) + "|" + string(op.What)
}

func (d *Daemon) secretOpsPath() string {
	if d.Store == nil {
		return ""
	}
	return filepath.Join(d.Store.Loc.Root, "secret-ops.json")
}

// secretOpsLocked is the record, read from disk the first time.
func (d *Daemon) secretOpsLocked() map[string]wire.SecretOperation {
	b := &d.secretOps
	if !b.loaded {
		b.loaded = true
		if path := d.secretOpsPath(); path != "" {
			if raw, err := os.ReadFile(path); err == nil && diskjson.Unmarshal(raw, &b.last) != nil {
				log.Printf("secret-ops.json: unreadable, starting afresh")
				b.last = nil
			}
		}
	}
	if b.last == nil {
		b.last = map[string]wire.SecretOperation{}
	}
	return b.last
}

// heldSecretNames is every name this machine holds a value for: secrets.env, the sealed
// store, and each session's own.
func (d *Daemon) heldSecretNames() map[string]bool {
	held := map[string]bool{}
	home := d.personalHome()
	if home == "" {
		return held
	}
	for _, n := range skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)).Names() {
		held[n] = true
	}
	for n := range readSealedSecrets(home).Secrets {
		held[n] = true
	}
	if dir := d.sessionSecretsDir(); dir != "" {
		files, _ := os.ReadDir(dir)
		for _, f := range files {
			id := strings.TrimSuffix(f.Name(), ".json")
			if !isAgentFileID(id) {
				continue
			}
			for n := range d.readSessionSecrets(wire.UUID(id)).Secrets {
				held[n] = true
			}
		}
	}
	return held
}

// saveSecretOpsLocked writes the record, bounded to the names this machine holds.
func (d *Daemon) saveSecretOpsLocked() {
	path := d.secretOpsPath()
	if path == "" {
		return
	}
	last := d.secretOps.last
	held := d.heldSecretNames()
	for n := range last {
		if !held[n] {
			delete(last, n)
		}
	}
	trimOldest(last, func(op wire.SecretOperation) wire.Date { return op.At })
	raw, err := json.Marshal(last)
	if err == nil {
		err = store.WriteAtomically(path, raw, 0o600)
	}
	if err != nil {
		log.Printf("secret-ops.json: could not save: %v", err)
		return
	}
	d.secretOps.saved = nowFunc()
}

// secretLastOp is a secret's last operation on this machine, if it has one.
func (d *Daemon) secretLastOp(name string) (wire.SecretOperation, bool) {
	d.secretOps.mu.Lock()
	defer d.secretOps.mu.Unlock()
	op, ok := d.secretOpsLocked()[name]
	return op, ok
}

// secretRead records an agent's read of a secret: use at place.
func (d *Daemon) secretRead(agent wire.UUID, name string, use wire.SecretOperationUse, place string) {
	d.noteSecretOp(wire.SecretOperation{Name: name, What: wire.SecretOperationWhatRead, Use: &use, Place: &place, Agent: agentRef(agent)}, true)
}

// secretDenied records a person's denial of a use with Ask before use.
func (d *Daemon) secretDenied(agent wire.UUID, name string, use wire.SecretUse, place string) {
	u := wire.SecretOperationUse(use)
	d.noteSecretOp(wire.SecretOperation{Name: name, What: wire.SecretOperationWhatDenied, Use: &u, Place: &place, Agent: agentRef(agent)}, true)
}

// secretChanged records a secret added, replaced or removed. audit is false for a change the
// control plane kept already: a person's, in Settings ▸ Secrets.
func (d *Daemon) secretChanged(agent wire.UUID, name string, what wire.SecretOperationWhat, audit bool) {
	d.noteSecretOp(wire.SecretOperation{Name: name, What: what, Agent: agentRef(agent)}, audit)
}

func agentRef(agent wire.UUID) *wire.UUID {
	if agent == "" {
		return nil
	}
	return &agent
}

// noteSecretOp raises the operation's event, keeps it as its secret's last, and sends it to
// the audit: a read in the next batch, anything else at once.
func (d *Daemon) noteSecretOp(op wire.SecretOperation, audit bool) {
	op.Name = strings.TrimSpace(op.Name)
	if op.Name == "" {
		return
	}
	op.At = wire.DateOf(nowFunc())
	d.raise(secretOpEvent(op, d.secretWho(op.Agent)))

	d.secretOps.mu.Lock()
	last := d.secretOpsLocked()
	_, had := last[op.Name]
	if op.What == wire.SecretOperationWhatRemoved {
		delete(last, op.Name)
	} else {
		last[op.Name] = op
	}
	if !had || op.What != wire.SecretOperationWhatRead || nowFunc().Sub(d.secretOps.saved) >= secretOpsSaveEvery {
		d.saveSecretOpsLocked()
	}
	var now []wire.SecretOperation
	if audit && op.What == wire.SecretOperationWhatRead {
		d.batchSecretOpLocked(op)
	} else if audit {
		now = []wire.SecretOperation{op}
	}
	d.secretOps.mu.Unlock()
	if len(now) > 0 {
		go d.tellSecretOps(now)
	}
}

// batchSecretOpLocked counts a read into its entry of the next batch, and starts the batch.
func (d *Daemon) batchSecretOpLocked(op wire.SecretOperation) {
	b := &d.secretOps
	if b.batch == nil {
		b.batch = map[string]*wire.SecretOperation{}
	}
	key := secretOpKey(op)
	if had := b.batch[key]; had != nil {
		n := int64(1)
		if had.Count != nil {
			n = *had.Count
		}
		n++
		had.Count = &n
		return
	}
	b.batch[key] = &op
	b.order = append(b.order, key)
	if b.timer == nil {
		b.timer = time.AfterFunc(secretOpsBatch, d.flushSecretOps)
	}
}

// flushSecretOps sends the batch of reads to the audit.
func (d *Daemon) flushSecretOps() {
	b := &d.secretOps
	b.mu.Lock()
	ops := make([]wire.SecretOperation, 0, len(b.order))
	for _, k := range b.order {
		ops = append(ops, *b.batch[k])
	}
	b.batch, b.order, b.timer = nil, nil, nil
	b.mu.Unlock()
	d.tellSecretOps(ops)
}

// tellSecretOps sends operations to the control plane for its audit. A machine with none keeps
// only its events and its record.
func (d *Daemon) tellSecretOps(ops []wire.SecretOperation) {
	if len(ops) == 0 {
		return
	}
	ask := d.askControl.Load()
	if ask == nil {
		return
	}
	ctx, cancel := context.WithTimeout(d.ctx, secretOpsAsk)
	defer cancel()
	if _, err := (*ask)(ctx, wire.CallMachineSecretOps.Name, wire.MachineSecretOpsCall{Ops: ops}); err != nil {
		log.Printf("secret ops: the control plane was not told of %d: %v", len(ops), err)
	}
}

// secretWho is who did it, as an event's sentence starts.
func (d *Daemon) secretWho(agent *wire.UUID) string {
	if agent == nil {
		return "A person"
	}
	return d.agentWho(*agent)
}

// secretOpEvent is an operation's event: name, machine, agent, use and place, and change for
// secret.changed. Never the value, never its hint.
func secretOpEvent(op wire.SecretOperation, who string) wire.EventDraft {
	details := map[string]string{"name": op.Name, "machine": accountMachine()}
	if op.Agent != nil {
		details["agent"] = string(*op.Agent)
	}
	where := ""
	if op.Use != nil {
		details["use"] = string(*op.Use)
		where = " (" + string(*op.Use)
		if op.Place != nil && *op.Place != "" {
			details["place"] = *op.Place
			where += ", " + *op.Place
		}
		where += ")"
	}
	draft := wire.EventDraft{At: op.At, Scope: macScope(), Details: details}
	switch op.What {
	case wire.SecretOperationWhatRead:
		draft.Name, draft.Sentence = "secret.read", who+" read "+op.Name+where+"."
	case wire.SecretOperationWhatDenied:
		draft.Name, draft.Sentence = "secret.denied", "A person denied "+op.Name+where+"."
	default:
		draft.Name, details["change"] = "secret.changed", string(op.What)
		// A person types the value, also for a session's ask_secret: the sentence names no one.
		draft.Sentence = op.Name + " was " + map[wire.SecretOperationWhat]string{wire.SecretOperationWhatAdded: "added",
			wire.SecretOperationWhatReplaced: "replaced", wire.SecretOperationWhatRemoved: "removed"}[op.What] + "."
	}
	return draft
}

// noteStartSecrets records what a session is given at its start: its own secrets as its
// runtime's variables, and each server's ${NAME} but a flagged one, which agentsd fills on
// each request instead (secretproxy.go). A server missing a secret is not given, so every
// other ${NAME} it names was filled.
func (d *Daemon) noteStartSecrets(agent wire.UUID, entries []sessionEntry) {
	for _, n := range slices.Sorted(maps.Keys(d.sessionSecretValues(agent))) {
		d.secretRead(agent, n, wire.SecretOperationUseEnv, secretSessionPlace)
	}
	for _, e := range entries {
		var names []string
		for _, m := range secretRef.FindAllStringSubmatch(string(e.raw), -1) {
			if !slices.Contains(e.flagged, m[1]) && !slices.Contains(names, m[1]) {
				names = append(names, m[1])
			}
		}
		for _, n := range names {
			d.secretRead(agent, n, wire.SecretOperationUseEnv, e.name)
		}
	}
}

type secretChange struct {
	name string
	what wire.SecretOperationWhat
}

// userSecretChanges is what a sync of the person's secrets changed here: a name new, one with
// a newer version, and one gone.
func userSecretChanges(before, after userSettingsSyncState) []secretChange {
	var out []secretChange
	for _, n := range after.Secrets {
		switch {
		case !slices.Contains(before.Secrets, n):
			out = append(out, secretChange{n, wire.SecretOperationWhatAdded})
		case after.Versions[n] > before.Versions[n] && before.Versions[n] > 0:
			out = append(out, secretChange{n, wire.SecretOperationWhatReplaced})
		}
	}
	for _, n := range before.Secrets {
		if !slices.Contains(after.Secrets, n) {
			out = append(out, secretChange{n, wire.SecretOperationWhatRemoved})
		}
	}
	return out
}
