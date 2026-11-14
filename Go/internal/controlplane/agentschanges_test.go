package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// fakeCompare is GitHub's compare of agentsRepo for a test: ahead commits numbered 1 … ahead,
// oldest first, each the squash of PR 1000+i, and the addresses it was asked.
type fakeCompare struct {
	mu     sync.Mutex
	ahead  map[string]int
	behind map[string]int
	asked  []string
}

func (f *fakeCompare) get(_ context.Context, address string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, address)
	u, err := url.Parse(address)
	if err != nil {
		return nil, err
	}
	pair := u.Path[strings.LastIndex(u.Path, "/")+1:]
	ahead, known := f.ahead[pair]
	if !known {
		return nil, fmt.Errorf("no compare %s", pair)
	}
	size, _ := strconv.Atoi(u.Query().Get("per_page"))
	page, _ := strconv.Atoi(u.Query().Get("page"))
	commits := []map[string]any{}
	for i := (page-1)*size + 1; i <= min(page*size, ahead); i++ {
		commits = append(commits, map[string]any{
			"sha": fmt.Sprintf("sha%d", i),
			"commit": map[string]any{
				"message":   fmt.Sprintf("Change %d (#%d) (#%d)\n\nbody", i, i, 1000+i),
				"committer": map[string]any{"date": "2026-11-13T15:13:00Z"},
			},
		})
	}
	answer := map[string]any{"ahead_by": ahead, "behind_by": f.behind[pair], "commits": commits}
	return json.Marshal(answer)
}

// #5273: the changes from one version to another are GitHub's compare of their commits,
// newest first, each its squash title with the PR's number taken off; only the pages that
// hold the newest are asked, and a compare is asked once.
func TestAgentsChangesAreTheCompareNewestFirst(t *testing.T) {
	t.Parallel()
	fake := &fakeCompare{ahead: map[string]int{"v0.18.0...8162a5a06": 244}, behind: map[string]int{}}
	s := &Service{}
	s.agentsCompares.get = fake.get

	c, err := s.agentsChanges(context.Background(), "0.18.0", "0.18.1-dev.244+g8162a5a06", 6)
	if err != nil {
		t.Fatal(err)
	}
	if c.Ahead != 244 || len(c.Changes) != 6 || c.Complete {
		t.Fatalf("the newest 6 of 244: %+v", c)
	}
	first := c.Changes[0]
	if first.Sha != "sha244" || first.Title != "Change 244 (#244)" || first.Number == nil || *first.Number != 1244 {
		t.Fatalf("the newest first, the PR off its title: %+v", first)
	}
	if c.Changes[5].Sha != "sha239" {
		t.Fatalf("in order: %+v", c.Changes[5])
	}
	// The counts, then page 3 alone (commits 201 … 244 hold 239 … 244).
	if len(fake.asked) != 2 || !strings.Contains(fake.asked[1], "per_page=100&page=3") {
		t.Fatalf("asked %v", fake.asked)
	}
	again, _ := s.agentsChanges(context.Background(), "0.18.0", "0.18.1-dev.244+g8162a5a06", 3)
	if len(fake.asked) != 2 || len(again.Changes) != 3 {
		t.Fatalf("kept: asked %d, %+v", len(fake.asked), again)
	}
	all, _ := s.agentsChanges(context.Background(), "0.18.0", "0.18.1-dev.244+g8162a5a06", 0)
	if !all.Complete || len(all.Changes) != 244 || all.Changes[243].Sha != "sha1" {
		t.Fatalf("all: %d, complete %v", len(all.Changes), all.Complete)
	}
	if _, err := s.agentsChanges(context.Background(), "0.18.0", "custom", 0); err == nil {
		t.Fatal("a version with no commit has no changes")
	}
}

// #5273: machines/agents is a machine page's Agents section: its version since its first
// hello, the version before and the newest changes since it, its history, and the person's
// other machines with how far each is behind.
func TestMachineAgentsSaysTheVersionTheChangesAndTheOthers(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	fake := &fakeCompare{
		ahead:  map[string]int{"v0.18.0...8162a5a06": 544, "8162a5a06...v0.18.0": 0},
		behind: map[string]int{"8162a5a06...v0.18.0": 544},
	}
	p.s.agentsCompares.get = fake.get
	mac, server := p.host("OWNERS-MAC"), p.host("BUILD-BOX")
	_, owner := p.client("Owner's window")
	hello := func(host, version string) {
		t.Helper()
		params, _ := json.Marshal(wire.MachineHello{Version: version, Platform: "macOS", MachineID: host})
		if _, err := p.s.methods.HostSaid(host, "machine/hello", params); err != nil {
			t.Fatal(err)
		}
	}
	hello(mac.member.Host, "0.18.0")
	hello(mac.member.Host, "0.18.1-dev.544+g8162a5a06")
	hello(server.member.Host, "0.18.0")

	var a wire.MachineAgents
	if err := json.Unmarshal(call(t, owner, "", "machines/agents", wire.MachineRequest{Host: wire.MachineRef(mac.member.Host)}), &a); err != nil {
		t.Fatal(err)
	}
	if a.Version != "0.18.1-dev.544+g8162a5a06" || a.Since == nil || a.Previous == nil || *a.Previous != "0.18.0" {
		t.Fatalf("the version, since when, the one before: %+v", a)
	}
	if a.Changes == nil || a.Changes.Ahead != 544 || len(a.Changes.Changes) != agentsChangesShown {
		t.Fatalf("the newest changes since 0.18.0: %+v (%v)", a.Changes, a.ChangesError)
	}
	if len(a.History) == 0 || a.History[0].Version != a.Version {
		t.Fatalf("history, newest first: %+v", a.History)
	}
	var other *wire.MachineAgentsOther
	for i := range a.Others {
		if string(a.Others[i].Host) == server.member.Host {
			other = &a.Others[i]
		}
		if string(a.Others[i].Host) == mac.member.Host {
			t.Fatal("the page's machine is not one of the others")
		}
	}
	if other == nil || other.Version != "0.18.0" || other.Behind == nil || *other.Behind != 544 || other.Ahead == nil || *other.Ahead != 0 {
		t.Fatalf("the server, 544 behind: %+v", other)
	}

	var all wire.AgentsChanges
	if err := json.Unmarshal(call(t, owner, "", "machines/agentsChanges",
		wire.AgentsChangesRequest{Base: "0.18.0", Head: "0.18.1-dev.544+g8162a5a06"}), &all); err != nil {
		t.Fatal(err)
	}
	if len(all.Changes) != 544 || !all.Complete {
		t.Fatalf("all of them: %d", len(all.Changes))
	}
}
