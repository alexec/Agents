package controlplane

import (
	"strings"
	"sync"

	"github.com/alexec/agents/Go/wire"
)

// What the person's machines say of each of their secrets (#4158): each copy's hint, the
// last 4 of its value, and the newest operation any machine did with it. Both stay in this
// copy's memory and go only on the person's own rows (user/secretNames): never in the store,
// a log line or an audit entry (direction.md, Credentials). A machine sends them again at
// each join, so a restart loses nothing for long.

// secretInfoMost bounds the names kept for one person and one machine.
const secretInfoMost = 400

type secretHint struct {
	version int64
	hint    string
}

type secretInfoBook struct {
	secretInfoMu sync.Mutex
	// secretHints is each machine's hints, by person, then machine, then name.
	secretHints map[string]map[string]map[string]secretHint
	// secretLast is each name's newest operation, by person, then name.
	secretLast map[string]map[string]wire.SecretLastOp
}

// noteSecretInfo keeps what host, a machine of user's, sent: its operations, and when held is
// there, every secret it holds in place of what it held before.
func (s *Service) noteSecretInfo(host, user string, ops []wire.SecretOperation, held []wire.MachineSecretHeld, all bool) {
	if user == "" || host == "" {
		return
	}
	b := &s.secretInfoBook
	b.secretInfoMu.Lock()
	defer b.secretInfoMu.Unlock()
	if b.secretLast == nil {
		b.secretLast = map[string]map[string]wire.SecretLastOp{}
		b.secretHints = map[string]map[string]map[string]secretHint{}
	}
	last := b.secretLast[user]
	if last == nil {
		last = map[string]wire.SecretLastOp{}
		b.secretLast[user] = last
	}
	newer := func(name string, op wire.SecretLastOp) {
		if had, ok := last[name]; ok && had.At >= op.At {
			return
		}
		if _, ok := last[name]; !ok && len(last) >= secretInfoMost {
			return
		}
		last[name] = op
	}
	for _, op := range ops {
		if name := strings.TrimSpace(op.Name); name != "" {
			newer(name, wire.SecretLastOp{What: op.What, At: op.At})
		}
	}
	if !all {
		return
	}
	hints := map[string]secretHint{}
	for _, h := range held {
		if len(hints) >= secretInfoMost {
			break
		}
		name := string(h.Name)
		if h.LastOp != nil {
			newer(name, *h.LastOp)
		}
		if h.Hint == nil || *h.Hint == "" || len([]rune(*h.Hint)) > 4 {
			continue
		}
		var version int64
		if h.Version != nil {
			version = *h.Version
		}
		hints[name] = secretHint{version: version, hint: *h.Hint}
	}
	if b.secretHints[user] == nil {
		b.secretHints[user] = map[string]map[string]secretHint{}
	}
	b.secretHints[user][host] = hints
}

// addSecretInfo puts each row's hint, from a machine whose copy is the row's version, and its
// last operation on the person's rows.
func (s *Service) addSecretInfo(user string, rows []wire.UserSecretRow) {
	b := &s.secretInfoBook
	b.secretInfoMu.Lock()
	defer b.secretInfoMu.Unlock()
	for i := range rows {
		r := &rows[i]
		name := string(r.Name)
		if op, ok := b.secretLast[user][name]; ok {
			r.LastOp = new(op)
		}
		for _, hints := range b.secretHints[user] {
			h, ok := hints[name]
			if ok && (r.Version == nil || h.version == *r.Version) {
				r.Hint = new(h.hint)
				break
			}
		}
	}
}
