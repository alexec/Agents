package agentsd

import (
	"context"
	"log"
	"os"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/codespacessh"
)

// GitHub stops a codespace after its idle timeout, and counts no background process as use
// (#4636). While a codespace's machine works, the control plane asks the machine that
// carries its provider to keep it awake (providers/ssh keepAwake, #4637): this machine
// holds one ssh session to it, with a line each few minutes, which GitHub counts as use.

// keepAwakeLease is how long one keepAwake holds the session: the control plane asks again
// each few minutes while the machine works, so a control plane that has gone, or forgot,
// never keeps a codespace up for longer than this.
var keepAwakeLease = 15 * time.Minute

// keepAwakeRetry is how long a session that ended by itself waits before the next one.
var keepAwakeRetry = 30 * time.Second

// keepAwakeSession runs the session; the tests change it.
var keepAwakeSession = func(ctx context.Context, codespace, token string) error {
	return codespacessh.KeepAwake(ctx, codespace, token, os.Environ())
}

// awake is the sessions this machine holds, by codespace.
type awake struct {
	mu   sync.Mutex
	held map[string]*awakeSession
}

type awakeSession struct {
	provider string
	cancel   context.CancelFunc
	lease    *time.Timer
}

// keepAwake holds a session to codespace, with token, for keepAwakeLease from now: a new
// one, or the one held, for longer.
func (a *awake) keepAwake(provider, codespace, token string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.held == nil {
		a.held = map[string]*awakeSession{}
	}
	if s := a.held[codespace]; s != nil {
		s.lease.Reset(keepAwakeLease)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &awakeSession{provider: provider, cancel: cancel}
	s.lease = time.AfterFunc(keepAwakeLease, func() {
		log.Printf("providers: %s kept awake for its time, no longer asked", codespace)
		a.end(codespace, s)
	})
	a.held[codespace] = s
	log.Printf("providers: keeping %s awake", codespace)
	go func() {
		for {
			err := keepAwakeSession(ctx, codespace, token)
			if ctx.Err() != nil {
				return
			}
			log.Printf("providers: %v; again in %s", err, keepAwakeRetry)
			select {
			case <-ctx.Done():
				return
			case <-time.After(keepAwakeRetry):
			}
		}
	}()
}

// letSleep ends codespace's session, if this machine holds one.
func (a *awake) letSleep(codespace string) {
	a.mu.Lock()
	s := a.held[codespace]
	a.mu.Unlock()
	if s != nil {
		log.Printf("providers: letting %s sleep", codespace)
		a.end(codespace, s)
	}
}

// forget ends every session for provider: it is no longer carried here.
func (a *awake) forget(provider string) {
	a.mu.Lock()
	var ending []string
	for codespace, s := range a.held {
		if s.provider == provider {
			ending = append(ending, codespace)
		}
	}
	a.mu.Unlock()
	for _, codespace := range ending {
		a.letSleep(codespace)
	}
}

// end ends s, when it is still codespace's session.
func (a *awake) end(codespace string, s *awakeSession) {
	a.mu.Lock()
	if a.held[codespace] == s {
		delete(a.held, codespace)
	}
	a.mu.Unlock()
	s.lease.Stop()
	s.cancel()
}

// holding is the codespaces this machine keeps awake, for the tests.
func (a *awake) holding() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]string, 0, len(a.held))
	for codespace := range a.held {
		out = append(out, codespace)
	}
	return out
}
