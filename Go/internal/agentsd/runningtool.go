package agentsd

import (
	"time"

	"github.com/alexec/agents/Go/wire"
)

// What a working agent is doing, for the sidebars (#1902): running a tool, or thinking
// (which takes in replying, and waiting on the model). The turn's tool calls still in
// flight are kept here; the newest one's title goes on Agent.RunningTool, and none is
// thinking. A change goes on the record only once it has held for toolSettle, both ways,
// so a tool that ends at once never shows, a short gap between two never flashes back to
// thinking, and each agent sends at most one such change a second. A change of mark,
// thinking to a tool or back, also waits until the last one has held for markHold
// (#2046), so a row changes its mark at most once in that time; a new title on the
// same mark waits only for toolSettle.

var (
	toolSettle = time.Second
	markHold   = 5 * time.Second
)

// toolsInFlight is the turn's tool calls that are pending or in progress, oldest first.
type toolsInFlight struct {
	open   []openTool
	shown  string // on the record: "" is thinking
	target string // what the timer will put there
	timer  *time.Timer
	markAt time.Time // when the record last changed between thinking and a tool
}

type openTool struct{ id, title string }

func toolEnded(status *string) bool {
	return status != nil && (*status == "completed" || *status == "failed")
}

// noteToolCall is a tool_call (begun) or a tool_call_update (changed or ended).
func (l *live) noteToolCall(call wire.ToolCall, begun bool) {
	if call.ToolCallID == nil {
		return
	}
	id := *call.ToolCallID
	l.mu.Lock()
	defer l.mu.Unlock()
	t := &l.tools
	at := -1
	for i, o := range t.open {
		if o.id == id {
			at = i
		}
	}
	switch {
	case toolEnded(call.Status):
		if at >= 0 {
			t.open = append(t.open[:at:at], t.open[at+1:]...)
		}
	case at < 0 && begun:
		t.open = append(t.open, openTool{id: id, title: call.Title})
	case at >= 0 && begun:
		t.open[at].title = call.Title
	}
	l.settleToolLocked()
}

// settleToolLocked starts the wait for what the record should say now, if it differs.
func (l *live) settleToolLocked() {
	t := &l.tools
	want := ""
	if n := len(t.open); n > 0 {
		want = t.open[n-1].title
	}
	if want == t.shown {
		if t.timer != nil {
			t.timer.Stop()
			t.timer = nil
		}
		t.target = want
		return
	}
	if t.timer != nil && t.target == want {
		return
	}
	if t.timer != nil {
		t.timer.Stop()
	}
	t.target = want
	wait := toolSettle
	if (want == "") != (t.shown == "") {
		wait = max(wait, time.Until(t.markAt.Add(markHold)))
	}
	t.timer = time.AfterFunc(wait, l.showTool)
}

// showTool puts what has held for toolSettle on the record, while the turn runs.
func (l *live) showTool() {
	l.mu.Lock()
	t := &l.tools
	want := ""
	if n := len(t.open); n > 0 {
		want = t.open[n-1].title
	}
	if want != t.target || want == t.shown {
		l.mu.Unlock()
		return
	}
	if (want == "") != (t.shown == "") {
		t.markAt = time.Now()
	}
	t.shown, t.timer = want, nil
	l.mu.Unlock()
	l.d.change(l.id, func(a *wire.Agent) {
		if a.State != wire.AgentStateRunning {
			return
		}
		if want == "" {
			a.RunningTool = nil
		} else {
			a.RunningTool = &want
		}
	})
}

// forgetTools is a turn beginning or ending: nothing in flight, thinking. The record's
// RunningTool is cleared by whoever ends the turn.
func (l *live) forgetTools() {
	l.mu.Lock()
	if l.tools.timer != nil {
		l.tools.timer.Stop()
	}
	l.tools = toolsInFlight{}
	l.mu.Unlock()
}
