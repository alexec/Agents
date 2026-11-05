package agentsd

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

// The machine lock (#3399, specs/3399-machine-lock): host/lock is the person's whole lock.
// This host checks it, and pins the head it took in <root>/lock-pin.json; it takes only a
// lock that grows from that pin. The first lock it is sent is taken on trust (D9). Until
// #3400's later steps it refuses nothing: a lock that fails the check is logged, and the
// pin stays where it was.

const lockPinFile = "lock-pin.json"

type lockState struct {
	lockMu sync.Mutex
}

func (d *Daemon) lockPinPath() string { return filepath.Join(d.Store.Loc.Root, lockPinFile) }

// LockPin is the head this host last took; zero when it has taken none.
func (d *Daemon) LockPin() machinelock.Pin {
	var pin machinelock.Pin
	if b, err := os.ReadFile(d.lockPinPath()); err == nil {
		json.Unmarshal(b, &pin)
	}
	return pin
}

// toldLock is host/lock.
func (d *Daemon) toldLock(params json.RawMessage) {
	var lock wire.Lock
	if err := json.Unmarshal(params, &lock); err != nil {
		log.Printf("lock: %v", err)
		return
	}
	d.TakeLock(lock)
}

// TakeLock checks a lock against the pin and, when it passes, pins its head. It says
// whether it took it. A lock that fails is only logged, as what this host would refuse.
func (d *Daemon) TakeLock(lock wire.Lock) bool {
	d.lockMu.Lock()
	defer d.lockMu.Unlock()
	pin := d.LockPin()
	state, err := machinelock.Follow(pin, lock)
	if err != nil {
		log.Printf("lock: would refuse %s's lock of %d entries: %v", lock.Person, len(lock.Entries), err)
		return false
	}
	if state.Count() == pin.Count {
		return true
	}
	b, _ := json.Marshal(state.Pin())
	if err := store.WriteAtomically(d.lockPinPath(), b, 0o644); err != nil {
		log.Printf("lock: the head could not be pinned: %v", err)
		return false
	}
	if pin.Count == 0 {
		log.Printf("lock: pinned %s's lock on first use, %d entries, root %s, head %s",
			state.Person, state.Count(), state.Root.Short(), state.Head().Short())
	} else {
		log.Printf("lock: %s's lock grew from %d to %d entries, head %s",
			state.Person, pin.Count, state.Count(), state.Head().Short())
	}
	return true
}
