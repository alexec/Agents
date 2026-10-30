package agentsd

import (
	"encoding/json"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// #2348: a person's connection links a session to an issue and a PR, walks from the issue,
// ends a link, and finds it all again after the host starts again.
func TestLineageOverTheWire(t *testing.T) {
	root := t.TempDir()
	d, c := start(t, root)
	issue := wire.LineageNode{Kind: "issue", Ref: "github:alexec/Agents#2348"}
	session := wire.LineageNode{Kind: "session", Ref: "session:00000000-0000-0000-0000-000000000001"}
	pr := wire.LineageNode{Kind: "pr", Ref: "github:alexec/Agents#2999"}
	c.call(t, 1, "lineage/link", wire.LineageLinkRequest{From: session, To: issue, Rel: "works-on", Source: "start"})
	c.call(t, 2, "lineage/link", wire.LineageLinkRequest{From: session, To: pr, Rel: "opens", Source: "agent"})
	var g wire.LineageGraph
	json.Unmarshal(c.call(t, 3, "lineage/walk", wire.LineageNodeRequest{Node: issue}), &g)
	if len(g.Nodes) != 3 || len(g.Links) != 2 {
		t.Fatalf("%+v", g)
	}
	var ended wire.LineageLinks
	json.Unmarshal(c.call(t, 4, "lineage/end", wire.LineageEndRequest{From: session, To: pr, Rel: "opens"}), &ended)
	if len(ended.Links) != 1 || ended.Links[0].EndedAt == nil {
		t.Fatalf("%+v", ended)
	}
	d.Shutdown()

	d, c = start(t, root)
	defer d.Shutdown()
	var links wire.LineageLinks
	json.Unmarshal(c.call(t, 5, "lineage/links", wire.LineageNodeRequest{Node: pr}), &links)
	if len(links.Links) != 1 || links.Links[0].EndedAt == nil || links.Links[0].Source != "agent" {
		t.Fatalf("%+v", links)
	}
}
