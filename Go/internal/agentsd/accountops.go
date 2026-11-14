package agentsd

import (
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
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The record of each read and change of an outside account (#4157). manage_accounts raises
// account.read (a get, or a list filtered to the account's service) or account.changed (an add
// that is new, or that took another's place), and tells the control plane, which writes an audit
// entry for each. A list with no service reads no account. This machine keeps each account's last
// operation (none for a removed one, #5253), and the last read of each secret, so an account's lastOp is the newest of its own and
// a secret.read of the secret or card it names.

// accountOpsMost is how many accounts, and how many secrets, the record keeps: the oldest go first.
const accountOpsMost = 500

// accountOpsSaveEvery is how often a secret read again is written down: an MCP header is read on
// each call.
const accountOpsSaveEvery = time.Minute

// accountOpRecord is account-ops.json.
type accountOpRecord struct {
	// Accounts is each account's last operation, by accountOpKey.
	Accounts map[string]wire.AccountLastOp `json:"accounts,omitempty"`
	// Secrets is the last read of each secret, by its name.
	Secrets map[string]wire.Date `json:"secrets,omitempty"`
}

type accountOpBook struct {
	mu     sync.Mutex
	loaded bool
	rec    accountOpRecord
	saved  time.Time // when the record was last written
}

// accountMachine is the machine's name, as an event about an account names it.
var accountMachine = sync.OnceValue(macName)

// accountOpKey is an account as the control plane tells one from another: its service and address.
func accountOpKey(service string, address *string) string {
	return strings.ToLower(service) + "#" + strings.ToLower(deref(address))
}

func (d *Daemon) accountOpsPath() string {
	if d.Store == nil {
		return ""
	}
	return filepath.Join(d.Store.Loc.Root, "account-ops.json")
}

// accountOpsLocked is the record, read from disk the first time.
func (d *Daemon) accountOpsLocked() *accountOpRecord {
	b := &d.accountOps
	if !b.loaded {
		b.loaded = true
		if path := d.accountOpsPath(); path != "" {
			if raw, err := os.ReadFile(path); err == nil && diskjson.Unmarshal(raw, &b.rec) != nil {
				log.Printf("account-ops.json: unreadable, starting afresh")
				b.rec = accountOpRecord{}
			}
		}
	}
	if b.rec.Accounts == nil {
		b.rec.Accounts = map[string]wire.AccountLastOp{}
	}
	if b.rec.Secrets == nil {
		b.rec.Secrets = map[string]wire.Date{}
	}
	return &b.rec
}

func (d *Daemon) saveAccountOpsLocked() {
	path := d.accountOpsPath()
	if path == "" {
		return
	}
	rec := &d.accountOps.rec
	trimOldest(rec.Accounts, func(op wire.AccountLastOp) wire.Date { return op.At })
	trimOldest(rec.Secrets, func(at wire.Date) wire.Date { return at })
	raw, err := json.Marshal(rec)
	if err == nil {
		err = store.WriteAtomically(path, raw, 0o600)
	}
	if err != nil {
		log.Printf("account-ops.json: could not save: %v", err)
		return
	}
	d.accountOps.saved = nowFunc()
}

// trimOldest drops the oldest entries past accountOpsMost.
func trimOldest[V any](m map[string]V, at func(V) wire.Date) {
	if len(m) <= accountOpsMost {
		return
	}
	keys := slices.SortedFunc(maps.Keys(m), func(a, b string) int {
		if at(m[a]) < at(m[b]) {
			return -1
		}
		if at(m[a]) > at(m[b]) {
			return 1
		}
		return strings.Compare(a, b)
	})
	for _, k := range keys[:len(keys)-accountOpsMost] {
		delete(m, k)
	}
}

// noteAccountOps keeps each operation as its account's last and raises its event.
func (d *Daemon) noteAccountOps(agent wire.UUID, ops []wire.AccountOperation) {
	if len(ops) == 0 {
		return
	}
	at := wire.DateOf(nowFunc())
	d.accountOps.mu.Lock()
	rec := d.accountOpsLocked()
	for _, op := range ops {
		key := accountOpKey(op.Service, op.Address)
		if op.What == wire.AccountOperationWhatRemoved {
			// A removed account has no last operation (#5253): one added again starts afresh.
			delete(rec.Accounts, key)
			continue
		}
		rec.Accounts[key] = wire.AccountLastOp{What: op.What, At: at, Agent: op.Agent}
	}
	d.saveAccountOpsLocked()
	d.accountOps.mu.Unlock()
	who := d.agentWho(agent)
	for _, op := range ops {
		details := map[string]string{"service": op.Service, "machine": accountMachine(), "agent": string(agent)}
		if op.Address != nil && *op.Address != "" {
			details["address"] = *op.Address
		}
		name, sentence := "account.read", who+" read the "+op.Service+" account."
		if op.What != wire.AccountOperationWhatRead {
			name, details["change"] = "account.changed", string(op.What)
			sentence = who + " added the " + op.Service + " account."
			switch op.What {
			case wire.AccountOperationWhatEdited:
				sentence = who + " changed the " + op.Service + " account."
			case wire.AccountOperationWhatRemoved:
				sentence = who + " removed the " + op.Service + " account."
			}
		}
		d.raise(wire.EventDraft{Name: name, At: at, Scope: macScope(), Sentence: sentence, Details: details})
	}
}

// noteSecretRead keeps a secret.read's time as the last read of that secret, for the accounts
// that name it.
func (d *Daemon) noteSecretRead(e wire.Event) {
	name := strings.TrimSpace(e.Details["name"])
	if e.Name != "secret.read" || name == "" {
		return
	}
	at := e.At
	if e.LastAt != nil {
		at = *e.LastAt
	}
	d.accountOps.mu.Lock()
	defer d.accountOps.mu.Unlock()
	rec := d.accountOpsLocked()
	last, had := rec.Secrets[name]
	if had && at <= last {
		return
	}
	rec.Secrets[name] = at
	if !had || nowFunc().Sub(d.accountOps.saved) >= accountOpsSaveEvery {
		d.saveAccountOpsLocked()
	}
}

// accountLastOp is an account's newest operation: its own, or a read of its secret or card.
func (d *Daemon) accountLastOp(a wire.OutsideAccount) *wire.AccountLastOp {
	d.accountOps.mu.Lock()
	defer d.accountOps.mu.Unlock()
	rec := d.accountOpsLocked()
	var newest *wire.AccountLastOp
	if op, ok := rec.Accounts[accountOpKey(a.Service, a.Address)]; ok {
		newest = &op
	}
	for _, name := range []*string{a.Secret, a.Card} {
		if name == nil {
			continue
		}
		if at, ok := rec.Secrets[strings.TrimSpace(*name)]; ok && (newest == nil || at > newest.At) {
			newest = &wire.AccountLastOp{What: wire.AccountOperationWhatRead, At: at}
		}
	}
	return newest
}
