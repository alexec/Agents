package agentsd

import (
	"encoding/base64"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// Live tiles (#4138, #4139): a still of what an agent drives (the Mac's screen, its session's
// tab of the machine's browser), as live/frame, at the end of its chat. Two rules (Alex,
// 2026-11-08): a frame goes only while the agent drives the source, a call on it in the last
// liveDriveWindow, and only to the connections that have the agent's chat in front, an active
// presence/report that shows it. A frame is held only while it is sent, and never reaches
// d.record or a file (as FR-016 of #3004). The take-over window (browser/watch) keeps its own
// rule: browser/frame while it watches, whoever drives.

// liveDriveWindow is how long after an agent's last call on a source its frames still go.
// Atomic, so a test can shorten it.
var liveDriveWindow = func() *atomic.Int64 {
	var v atomic.Int64
	v.Store(int64(10 * time.Second))
	return &v
}()

type liveKey struct {
	agent  wire.UUID
	source wire.LiveSource
}

// liveTileState is when each agent last drove each source, and the timers that end its drive.
type liveTileState struct {
	liveMu    sync.Mutex
	droveAt   map[liveKey]time.Time
	driveEnds map[liveKey]*time.Timer
	// simulatorWatches is the simulator leases being followed (simulatorlive.go).
	simulatorWatches map[simulatorWatch]bool
}

// drove marks a call of agent's on source: its frames go for liveDriveWindow from now, and
// ended runs once they stop, unless another call comes first.
func (d *Daemon) drove(agent wire.UUID, source wire.LiveSource, ended func()) {
	k := liveKey{sessionKey(agent), source}
	window := time.Duration(liveDriveWindow.Load())
	d.liveMu.Lock()
	defer d.liveMu.Unlock()
	if d.droveAt == nil {
		d.droveAt, d.driveEnds = map[liveKey]time.Time{}, map[liveKey]*time.Timer{}
	}
	d.droveAt[k] = time.Now()
	if t := d.driveEnds[k]; t != nil {
		t.Stop()
	}
	var t *time.Timer
	t = time.AfterFunc(window, func() {
		d.liveMu.Lock()
		if d.driveEnds[k] != t {
			d.liveMu.Unlock()
			return
		}
		delete(d.driveEnds, k)
		delete(d.droveAt, k)
		d.liveMu.Unlock()
		if ended != nil {
			ended()
		}
	})
	d.driveEnds[k] = t
}

// isDriving is whether agent made a call on source in the last liveDriveWindow.
func (d *Daemon) isDriving(agent wire.UUID, source wire.LiveSource) bool {
	d.liveMu.Lock()
	at, ok := d.droveAt[liveKey{sessionKey(agent), source}]
	d.liveMu.Unlock()
	return ok && time.Since(at) < time.Duration(liveDriveWindow.Load())
}

// inFront is the connections whose last presence/report is active and shows the agent, in
// the main window or a window of its own (alsoShowing).
func (d *Daemon) inFront(agent wire.UUID) map[int64]bool {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	out := map[int64]bool{}
	for c, p := range d.presences {
		if !p.active {
			continue
		}
		for id := range p.shown {
			if strings.EqualFold(string(id), string(agent)) {
				out[c] = true
				break
			}
		}
	}
	return out
}

// sendLive sends f to the connections with its agent in front, while the agent drives its
// source. It says whether any connection got it.
func (d *Daemon) sendLive(f wire.LiveFrame) bool {
	if !d.isDriving(f.AgentID, f.Source) {
		return false
	}
	front := d.inFront(f.AgentID)
	if len(front) == 0 {
		return false
	}
	if f.CapturedAt == 0 {
		f.CapturedAt = now()
	}
	sendEach(d, wire.NotifyLiveFrame, func(c *Client) (wire.LiveFrame, bool) { return f, front[c.ID] })
	return true
}

// liveImage is a JPEG as live/frame carries it.
func liveImage(jpeg []byte) *string {
	s := base64.StdEncoding.EncodeToString(jpeg)
	return &s
}
