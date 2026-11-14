package agentsd

import (
	"sort"
	"sync"

	"github.com/agentloops-dev/agents/Go/wire"
)

// The moves to another machine under way (#4641): Move to Machine… answers once the move is
// checked, and move/changed says how it goes, the branch's bytes and then the session, to
// every client, as send/changed does for Send to (#4613). A client that connects mid-move
// finds them with agents/moves. Every move says so, whoever asked: the person, an agent's
// move_session, or an agent that moves itself when its turn ends.

// movesUnderWay are the moves under way, by session: one at a time for each.
type movesUnderWay struct {
	mu sync.Mutex
	by map[wire.UUID]*moving
}

// moving is one move under way: how it goes, and the session's title, for the words.
type moving struct {
	n     wire.MoveNotification
	title *string
}

// beginMove says that the session id starts to move by order, and refuses a second move of
// it while one is under way.
func (d *Daemon) beginMove(id wire.UUID, order machineMove) (*moving, error) {
	a := d.Store.Agent(id)
	if a == nil {
		return nil, noSuchAgent()
	}
	d.moves.mu.Lock()
	if other, ok := d.moves.by[id]; ok {
		d.moves.mu.Unlock()
		return nil, Invalid("Nothing was moved: %s is moving to %s already.", quotedTitle(a.Title), other.n.MachineName)
	}
	if d.moves.by == nil {
		d.moves.by = map[wire.UUID]*moving{}
	}
	m := &moving{title: a.Title, n: wire.MoveNotification{AgentID: id, Machine: order.machine, MachineName: order.label(),
		Folder: order.folder, StartedAt: now()}}
	d.moves.by[id] = m
	n := m.n
	d.moves.mu.Unlock()
	Broadcast(d, wire.NotifyMoveChanged, n)
	return m, nil
}

// alreadyMoving refuses to move a while a move of it is under way.
func (d *Daemon) alreadyMoving(a *wire.Agent) error {
	d.moves.mu.Lock()
	defer d.moves.mu.Unlock()
	if other, ok := d.moves.by[a.ID]; ok {
		return Invalid("Nothing was moved: %s is moving to %s already.", quotedTitle(a.Title), other.n.MachineName)
	}
	return nil
}

// moveChanged changes how m goes, and says so.
func (d *Daemon) moveChanged(m *moving, change func(*wire.MoveNotification)) {
	d.moves.mu.Lock()
	change(&m.n)
	n := m.n
	d.moves.mu.Unlock()
	Broadcast(d, wire.NotifyMoveChanged, n)
}

// endMove says that m ended: with err, why it stopped, and the session stays here.
func (d *Daemon) endMove(m *moving, err error) {
	d.moves.mu.Lock()
	if d.moves.by[m.n.AgentID] == m {
		delete(d.moves.by, m.n.AgentID)
	}
	m.n.Finished = true
	if err != nil {
		_, msg := errMessage(err)
		problem := quotedTitle(m.title) + " was not moved to " + m.n.MachineName + ": " + msg + " It stays here."
		m.n.Problem = &problem
	}
	n := m.n
	d.moves.mu.Unlock()
	Broadcast(d, wire.NotifyMoveChanged, n)
}

// movesUnderWay are the moves under way, the oldest first.
func (d *Daemon) movesUnderWay() []wire.MoveNotification {
	d.moves.mu.Lock()
	out := make([]wire.MoveNotification, 0, len(d.moves.by))
	for _, m := range d.moves.by {
		out = append(out, m.n)
	}
	d.moves.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].StartedAt < out[j].StartedAt })
	return out
}
