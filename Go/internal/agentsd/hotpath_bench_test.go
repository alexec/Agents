package agentsd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The agentsd hot path (#4504): each changeAgent sends its folder's summary, and today
// that summary is made from every folder's. These benchmarks run it on a store the shape
// of Alex's on 2026-11-10: 400 folders and 2,700 agents, 99% of them archived (#4505).
// Under -short the store is a tenth of that, so a quick run stays quick.
//
//	go test -run '^$' -bench 'ChangeAgent|Folders' -benchmem ./internal/agentsd
//
// Baseline (#4505, main at 7dc9acccd, the golang:1.26 container on an Apple M5 with 2 CPUs,
// the full store, -benchmem, the median of -count=3):
//
//	BenchmarkChangeAgent-2   1   2163858287 ns/op    838359864 B/op   27246 allocs/op
//	BenchmarkFolders-2       1   2393204860 ns/op    961036984 B/op   30489 allocs/op
//
// A1 to A6 of #4504 show their gain against these numbers.

const (
	benchFolders = 400
	benchAgents  = 2_700
	benchLive    = 27 // 1%; the rest are archived
)

// hotPathStore is a daemon whose store has the folders and agents above, with no client
// connected, and the id of one live agent in it.
func hotPathStore(b *testing.B) (*Daemon, wire.UUID) {
	b.Helper()
	folders, agents, live := benchFolders, benchAgents, benchLive
	if testing.Short() {
		folders, agents, live = folders/10, agents/10, live/10
	}
	d, err := New(context.Background(), b.TempDir())
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(d.Shutdown)
	b.Cleanup(d.stopFolderWatches)
	root := b.TempDir()
	records := make([]wire.Folder, folders)
	for i := range records {
		dir := filepath.Join(root, fmt.Sprintf("folder-%03d", i))
		if err := os.Mkdir(dir, 0o750); err != nil {
			b.Fatal(err)
		}
		records[i] = wire.Folder{Folder: store.FolderURL(dir), AddedAt: now()}
	}
	// Into the store, not by folders/add: the folder watches would start on each.
	if err := d.Store.SaveFolders(records); err != nil {
		b.Fatal(err)
	}
	var liveID wire.UUID
	byUser := wire.AgentArchivedReasonByUser
	for i := range agents {
		at := now() - wire.Date(agents-i)
		a := wire.Agent{ID: store.NewUUID(), RuntimeID: "claude", Cwd: records[i%folders].Folder, State: wire.AgentStateFinished,
			EndedReason: reason(wire.EndedReasonEndTurn), AdvertisedOptions: []wire.ConfigOption{}, AvailableCommands: []wire.SlashCommand{},
			StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{}, ExtraArguments: []string{}}, CreatedAt: at, LastActivityAt: at}
		if i >= live {
			a.State, a.ArchivedAt, a.ArchivedReason = wire.AgentStateArchived, &at, &byUser
		} else {
			liveID = a.ID
		}
		if err := d.Store.Save(a); err != nil {
			b.Fatal(err)
		}
	}
	return d, liveID
}

// BenchmarkChangeAgent is one change to one live agent's record, as each streamed chunk
// or tool update makes (#4504).
func BenchmarkChangeAgent(b *testing.B) {
	d, id := hotPathStore(b)
	b.ReportAllocs()
	for b.Loop() {
		if d.change(id, func(a *wire.Agent) { a.Title = nil }) == nil {
			b.Fatal("no agent")
		}
	}
}

// BenchmarkFolders is the summary of every folder, archived ones too, as folderChanged
// makes it today (#4504).
func BenchmarkFolders(b *testing.B) {
	d, _ := hotPathStore(b)
	b.ReportAllocs()
	for b.Loop() {
		if len(d.folders(true)) == 0 {
			b.Fatal("no folders")
		}
	}
}

// BenchmarkArmBlockTimer is one aim of the block timer with a due block on an agent in a
// turn (#4687). Before the fix the timer fired every 20 ms for as long as that turn went
// on, and each pass read every record twice.
func BenchmarkArmBlockTimer(b *testing.B) {
	d, id := hotPathStore(b)
	d.change(id, func(a *wire.Agent) {
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Message: "Waiting for CI.", At: now(),
			Block: &wire.Block{Waits: []wire.Wait{{AgentID: store.NewUUID(), NameAtReport: "CI watcher"}}, Deadline: new(wire.DateOf(time.Now().Add(-time.Minute)))}}
	})
	l := d.live(id)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	b.ReportAllocs()
	for b.Loop() {
		d.armBlockTimer()
	}
}
