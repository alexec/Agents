package mcpcatalog

import (
	"reflect"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/linearmcp"
	"github.com/alexec/agents/Go/wire"
)

// What ours are written to declare is what they declare: the catalogue shows it before a
// host has checked a copy (#1428).
func TestOursDeclareWhatTheirServersDeclare(t *testing.T) {
	github, _ := OursByID("agents/github")
	linear, _ := OursByID("agents/linear")
	if !reflect.DeepEqual(github.Declares.Events, githubmcp.EventNames()) {
		t.Fatalf("github events: %v, the server's %v", github.Declares.Events, githubmcp.EventNames())
	}
	if !reflect.DeepEqual(linear.Declares.Events, linearmcp.EventNames()) {
		t.Fatalf("linear events: %v, the server's %v", linear.Declares.Events, linearmcp.EventNames())
	}
	// linear-mcp has show_issues (TestTheViewListsOpenIssues); github-mcp has the official ones.
	if !linear.Declares.Tools || !linear.Declares.Views || !github.Declares.Tools {
		t.Fatalf("tools: github %v, linear %v", github.Declares.Tools, linear.Declares.Tools)
	}
}

func TestLevelsComeFromWhatAServerDeclares(t *testing.T) {
	saved := ReadyMadeEvents
	defer func() { ReadyMadeEvents = saved }()

	ReadyMadeEvents = nil
	got := Levels(Declared{Tools: true, HasEvents: true, Events: []string{"pr.opened"}}, false)
	if got != (wire.MCPLevels{Tools: true, Events: true}) {
		t.Fatalf("no ready-made workflows: %+v", got)
	}
	// A workflow names an event, never a server: any server that declares it reaches Workflows.
	ReadyMadeEvents = []string{"pr.opened"}
	got = Levels(Declared{HasEvents: true, Events: []string{"pr.opened"}, Views: true}, true)
	if got != (wire.MCPLevels{Events: true, Views: true, Workflows: true, Tested: true}) {
		t.Fatalf("a ready-made workflow's event: %+v", got)
	}
	if got := Levels(Declared{Tools: true}, false); got != (wire.MCPLevels{Tools: true}) {
		t.Fatalf("tools only: %+v", got)
	}
}

func TestOursAreAddedHostedWithNoSecretToAsk(t *testing.T) {
	// Linear reads the person's connection (#1343), as GitHub does: no key to ask for.
	linear, _ := OursByID("agents/linear")
	built := BuildOurs(linear, func(string) bool { return false })
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != `{"command":"linear-mcp","hosted":true}` {
		t.Fatalf("entry: %s", got)
	}
	if built.NameHere != "linear" || built.ChosenRun != wire.MCPRunKindCommand || len(built.Variables) != 0 {
		t.Fatalf("built: %+v", built)
	}
	if o, ok := OursByCommand("/usr/local/bin/github-mcp"); !ok || o.ID != "agents/github" {
		t.Fatalf("by command: %+v %v", o, ok)
	}
	if _, ok := OursByCommand("npx"); ok {
		t.Fatal("npx is not ours")
	}
	r := OursResult(linear, linear.Declares)
	if r.MadeByAgents == nil || !*r.MadeByAgents || r.Levels == nil || !r.Levels.Tools || !r.Levels.Views || !r.Levels.Events {
		t.Fatalf("result: %+v", r)
	}
}
