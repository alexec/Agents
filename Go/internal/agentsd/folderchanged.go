package agentsd

import (
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// folder.changed is sent at most once a folder in each folderChangedWindow (#4508). Each
// streamed chunk and tool update changes an agent, and each change used to send its
// folder's summary at once: many a second for one folder, each a redraw on every client.
// Now a change marks the folder dirty, and the first one starts the window; at its end the
// folder's newest summary goes out. A change made after the summary is read starts the
// next window, so the last change is never lost. agent.changed is not delayed.

// folderChangedWindow is how long a folder's changes are kept before one summary says
// them; a test's own.
var folderChangedWindow = 250 * time.Millisecond

type folderChangedState struct {
	folderChangedMu sync.Mutex
	// folderDirty is the folders whose window is open.
	folderDirty map[string]bool
	// folderAfter runs f after the window; time.AfterFunc unless a test's clock.
	folderAfter func(time.Duration, func())
}

func (d *Daemon) folderChanged(folder string) {
	d.folderChangedMu.Lock()
	if d.folderDirty[folder] {
		d.folderChangedMu.Unlock()
		return
	}
	if d.folderDirty == nil {
		d.folderDirty = map[string]bool{}
	}
	d.folderDirty[folder] = true
	after := d.folderAfter
	d.folderChangedMu.Unlock()
	// Work Shutdown waits for, and none once the host is going (#4666): the summary reads
	// your policy, whose first read makes the first-start move into the root.
	send := func() { d.goAfterTurn("folder changed", func() { d.sendFolderChanged(folder) }) }
	if after != nil {
		after(folderChangedWindow, send)
		return
	}
	time.AfterFunc(folderChangedWindow, send)
}

// sendFolderChanged is the window's end: the folder's summary as it is now.
func (d *Daemon) sendFolderChanged(folder string) {
	// Closed before the summary is read: a change from here on opens the next window.
	d.folderChangedMu.Lock()
	delete(d.folderDirty, folder)
	d.folderChangedMu.Unlock()
	if d.ctx.Err() != nil {
		return
	}
	if s, ok := d.folderSummary(folder); ok {
		Broadcast(d, wire.NotifyFolderChanged, s)
	}
}
