package controlplane

import "sync"

// keyLocks is a lock for each key (a machine, a user) that is in use: the work for one
// key goes in order, the work for different keys does not wait (#5069, #5086). The map
// keeps an entry only for a key that is held or waited for, so it does not grow.
type keyLocks struct {
	mu   sync.Mutex
	held map[string]*keyLock
}

// keyLock is one key's lock, and how many hold it or wait for it.
type keyLock struct {
	mu    sync.Mutex
	users int
}

// lock waits for the earlier holders of key to finish. Call the function it returns to
// let the next one go.
func (k *keyLocks) lock(key string) func() {
	k.mu.Lock()
	if k.held == nil {
		k.held = map[string]*keyLock{}
	}
	l := k.held[key]
	if l == nil {
		l = &keyLock{}
		k.held[key] = l
	}
	l.users++
	k.mu.Unlock()
	l.mu.Lock()
	return func() {
		l.mu.Unlock()
		k.mu.Lock()
		if l.users--; l.users == 0 {
			delete(k.held, key)
		}
		k.mu.Unlock()
	}
}

// inUse is how many keys are held or waited for.
func (k *keyLocks) inUse() int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return len(k.held)
}
