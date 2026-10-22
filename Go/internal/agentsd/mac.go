package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// registerMac serves what a sandboxed window asks of its Mac's host (058, R12) — Finder,
// another app, Terminal — and what agents call the person (#121). Off a Mac the three
// verbs say so (mac_other.go), as the Swift host does.
func (d *Daemon) registerMac() {
	On(d, wire.CallMacReveal, func(_ context.Context, _ *Client, r wire.MacPathRequest) (wire.Empty, error) {
		if err := present(r.Path); err != nil {
			return wire.Empty{}, err
		}
		return wire.Empty{}, macOpen("-R", r.Path)
	})
	On(d, wire.CallMacOpen, func(_ context.Context, _ *Client, r wire.MacPathRequest) (wire.Empty, error) {
		if err := present(r.Path); err != nil {
			return wire.Empty{}, err
		}
		if r.App != nil && *r.App != "" {
			return wire.Empty{}, macOpen("-a", *r.App, r.Path)
		}
		return wire.Empty{}, macOpen(r.Path)
	})
	On(d, wire.CallMacTerminal, func(_ context.Context, _ *Client, r wire.MacTerminalRequest) (wire.Empty, error) {
		if r.Path != nil {
			return wire.Empty{}, macOpen("-a", "Terminal", *r.Path)
		}
		return wire.Empty{}, macOpen("-a", "Terminal")
	})

	var mu sync.Mutex
	file := func() string { return filepath.Join(d.SettingsDir, "person.json") }
	On(d, wire.CallPersonState, func(context.Context, *Client, wire.Empty) (wire.PersonSettings, error) {
		mu.Lock()
		defer mu.Unlock()
		return readPerson(file()), nil
	})
	// person/set is said to agents from their next briefing on.
	On(d, wire.CallPersonSet, func(_ context.Context, _ *Client, p wire.PersonSettings) (wire.PersonSettings, error) {
		mu.Lock()
		defer mu.Unlock()
		b, err := storeJSON(p)
		if err == nil {
			os.MkdirAll(d.SettingsDir, 0o700)
			err = store.WriteAtomically(file(), b, 0o644)
		}
		if err != nil {
			return wire.PersonSettings{}, &Error{Code: wire.FailureCouldNotSave, Message: "person.json: " + err.Error()}
		}
		Broadcast(d, wire.NotifyPersonChanged, p)
		return p, nil
	})
}

// readPerson is person.json, empty when it is missing; one that will not read is set
// aside, as StoreFile.load does.
func readPerson(path string) wire.PersonSettings {
	var p wire.PersonSettings
	b, err := os.ReadFile(path)
	if err != nil {
		return p
	}
	if json.Unmarshal(b, &p) != nil {
		os.Rename(path, fmt.Sprintf("%s.corrupt-%d", path, time.Now().Unix()))
		store.TrimSetAsides(path)
		return wire.PersonSettings{}
	}
	return p
}

// present is DaemonCore.gone's check: a path that is not there is fileGone.
func present(path string) error {
	if _, err := os.Stat(path); err != nil {
		return &Error{Code: wire.FailureFileGone, Message: filepath.Base(path) + " is gone."}
	}
	return nil
}
