package store

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/diskjson"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// BenchmarkOpen is the store's start with 2,700 records, 99% of them archived, each the
// size of a record on Alex's Mac on 2026-11-10 (a median of 45 KB, most of it the
// runtime's commands and options): what #4510 measured to decide whether old archived
// records should move to a file of their own. Under -short it is a tenth.
//
//	go test -run '^$' -bench Open -benchmem ./internal/agentsd/store
func BenchmarkOpen(b *testing.B) {
	agents, live := 2_700, 27
	if testing.Short() {
		agents, live = agents/10, live/10
	}
	root := b.TempDir()
	s, err := Open(root)
	if err != nil {
		b.Fatal(err)
	}
	b0, err := os.ReadFile(filepath.Join(fixtures, "archived-agent.json"))
	if err != nil {
		b.Fatal(err)
	}
	var shape wire.Agent
	if err := diskjson.Unmarshal(b0, &shape); err != nil {
		b.Fatal(err)
	}
	about := "A command the runtime advertises, as each record keeps the runtime's whole list"
	for i := 0; ; i++ {
		if out, _ := diskjson.Marshal(&shape); len(out) >= 45_000 {
			break
		}
		shape.AvailableCommands = append(shape.AvailableCommands, wire.SlashCommand{Name: fmt.Sprintf("command-%d", i), Description: &about})
	}
	byUser, endTurn := wire.AgentArchivedReasonByUser, wire.EndedReasonEndTurn
	for i := range agents {
		a := shape
		a.ID, a.Cwd = NewUUID(), wire.URL(fmt.Sprintf("file:///src/folder-%03d", i%400))
		a.MadeInRoot = &s.RootID
		if i < live {
			a.State, a.EndedReason, a.ArchivedAt, a.ArchivedReason = wire.AgentStateFinished, &endTurn, nil, nil
		} else {
			a.State, a.ArchivedReason = wire.AgentStateArchived, &byUser
		}
		if err := s.Save(a); err != nil {
			b.Fatal(err)
		}
	}
	// The archived records' summaries are written, as the host's stop writes them (#4653).
	s.FlushSummaries()
	b.ReportAllocs()
	for b.Loop() {
		o, err := Open(root)
		if err != nil || len(o.Agents()) != agents {
			b.Fatal(err)
		}
	}
}
