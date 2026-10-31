package agentsd

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/mac"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// registerWake serves wake/state, wake/settings and wake/set, and keeps the Mac awake
// while an agent works (024). The count is looked at every two seconds, so a hold ends
// within FR-004's five; the power every fifteen, as tickWorkflows reads it.
func (d *Daemon) registerWake() {
	w := &waker{
		file:  filepath.Join(d.Store.Loc.Root, "wake.json"),
		power: mac.ReadPower,
		hold:  holdTheMac,
		tell:  func(s wire.WakeState) { Broadcast(d, wire.NotifyWakeChanged, s) },
	}
	On(d, wire.CallWakeState, func(context.Context, *Client, wire.Empty) (wire.WakeState, error) {
		return w.State(), nil
	})
	On(d, wire.CallWakeSettings, func(context.Context, *Client, wire.Empty) (wire.WakeSettings, error) {
		return w.Settings(), nil
	})
	On(d, wire.CallWakeSet, func(_ context.Context, _ *Client, s wire.WakeSettings) (wire.WakeSettings, error) {
		return w.Set(s), nil
	})
	safe.Go("wake", func() {
		w.Revise(d.agentsInFlight(), true)
		count := time.NewTicker(2 * time.Second)
		defer count.Stop()
		power := time.NewTicker(15 * time.Second)
		defer power.Stop()
		for {
			select {
			case <-d.ctx.Done():
				w.Stop()
				return
			case <-count.C:
				w.Revise(d.agentsInFlight(), false)
			case <-power.C:
				w.Revise(d.agentsInFlight(), true)
			}
		}
	})
}

// holdTheMac is caffeinate's hold. A test's host holds nothing: CI's Mac, or the one a
// person runs the tests on, is not kept awake by them.
func holdTheMac() (func(), error) {
	if testing.Testing() {
		return func() {}, nil
	}
	h, err := mac.HoldAwake()
	if err != nil {
		return nil, err
	}
	return h.Release, nil
}

// agentsInFlight counts the agents starting or running: what keeps the Mac awake. One
// waiting on a person is not counted, so a question left overnight holds nothing.
// It lives here because only a Mac calls it; a Linux build would call it unused.
func (d *Daemon) agentsInFlight() int {
	n := 0
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateStarting || a.State == wire.AgentStateRunning {
			n++
		}
	}
	return n
}
