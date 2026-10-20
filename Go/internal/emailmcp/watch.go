package emailmcp

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
)

// IDLE (RFC 2177): a connection of its own per folder that a subscription asks about, which
// the mail server tells when mail comes. Each change counts one; so does each new
// connection, as what came while it was down is not known. A poll that finds the count as it
// left it, on a connection that stayed up, knows nothing came and asks the server nothing.
// The events draft takes only poll delivery here, so IDLE makes polls cheap, not pushed.

// maxWatched is the most folders watched at once: each is a connection the server counts.
const maxWatched = 4

// Watch is one folder's IDLE connection.
type Watch struct {
	changes atomic.Uint64
	live    atomic.Bool
}

// State is the count of changes, and whether IDLE holds the folder now.
func (w *Watch) State() (uint64, bool) {
	if w == nil {
		return 0, false
	}
	return w.changes.Load(), w.live.Load()
}

// Watchers starts a Watch per folder when first asked, until ctx ends.
type Watchers struct {
	ctx     context.Context
	account func() (Account, error)
	// Retry is how long after a failed connection it tries again; 30 seconds when zero.
	Retry time.Duration

	mu      sync.Mutex
	folders map[string]*Watch
}

// NewWatchers watches the account's folders until ctx ends.
func NewWatchers(ctx context.Context, account func() (Account, error)) *Watchers {
	return &Watchers{ctx: ctx, account: account, folders: map[string]*Watch{}}
}

// Folder is folder's Watch, started now if it was not; nil when maxWatched are watched.
func (ws *Watchers) Folder(folder string) *Watch {
	if ws == nil {
		return nil
	}
	ws.mu.Lock()
	defer ws.mu.Unlock()
	if w, ok := ws.folders[folder]; ok {
		return w
	}
	if len(ws.folders) >= maxWatched {
		return nil
	}
	w := &Watch{}
	ws.folders[folder] = w
	go ws.run(folder, w)
	return w
}

func (ws *Watchers) run(folder string, w *Watch) {
	retry := ws.Retry
	if retry <= 0 {
		retry = 30 * time.Second
	}
	wait := retry
	for ws.ctx.Err() == nil {
		ok, idleable := ws.idle(folder, w)
		if !idleable {
			return // no IDLE here: every poll asks the server
		}
		if ok {
			wait = retry
		} else {
			wait = min(wait*2, 10*time.Minute)
		}
		select {
		case <-ws.ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

// idle holds one IDLE connection until it drops. ok is whether it got as far as IDLE;
// idleable is false when the server has no IDLE.
func (ws *Watchers) idle(folder string, w *Watch) (ok, idleable bool) {
	handler := &imapclient.UnilateralDataHandler{
		Mailbox: func(data *imapclient.UnilateralDataMailbox) {
			if data.NumMessages != nil {
				w.changes.Add(1)
			}
		},
	}
	c, err := dialAccount(ws.account, handler)
	if err != nil {
		return false, true
	}
	defer c.Close()
	if !c.Caps().Has(imap.CapIdle) {
		return false, false
	}
	if _, err := c.Select(folder, &imap.SelectOptions{ReadOnly: true}).Wait(); err != nil {
		return false, true
	}
	cmd, err := c.Idle()
	if err != nil {
		return false, true
	}
	w.changes.Add(1)
	w.live.Store(true)
	defer w.live.Store(false)
	select {
	case <-ws.ctx.Done():
		_ = cmd.Close()
	case <-c.Closed():
	}
	return true, true
}
