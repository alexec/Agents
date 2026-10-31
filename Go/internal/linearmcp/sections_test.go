package linearmcp

import (
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The Issues page's sections (#2453, specs/2453-team-lists.md), in Linear's words.
func TestAnIssuesSection(t *testing.T) {
	viewer := &Person{ID: "u1", Name: "alex"}
	alex, sam := &Person{ID: "u1", Name: "alex"}, &Person{ID: "u2", Name: "sam"}
	for _, c := range []struct {
		what   string
		issue  Issue
		viewer *Person
		want   string
	}{
		{"assigned to the viewer", Issue{AssigneeID: "u1", Creator: sam}, viewer, sectionNeedsYou},
		{"by the viewer and assigned to the viewer", Issue{AssigneeID: "u1", Creator: alex}, viewer, sectionNeedsYou},
		{"by the viewer", Issue{AssigneeID: "u2", Creator: alex}, viewer, sectionYours},
		{"by a member", Issue{Creator: sam}, viewer, sectionTeam},
		{"by an app", Issue{Creator: &Person{Name: "Sentry", App: true}}, viewer, sectionTeam},
		{"by a guest", Issue{Creator: &Person{ID: "u9", Name: "kim", Guest: true}}, viewer, sectionOthers},
		{"by a deleted user", Issue{}, viewer, sectionOthers},
		{"no viewer: not Needs you", Issue{AssigneeID: "u1", Creator: alex}, nil, sectionTeam},
		{"an app with no id is not the viewer", Issue{Creator: &Person{Name: "app", App: true}}, &Person{Name: "app"}, sectionTeam},
	} {
		if got := issueSection(c.issue, c.viewer, nil); got != c.want {
			t.Errorf("%s: %s, want %s", c.what, got, c.want)
		}
	}
}

// With the control plane's people (#2951), Team is told from Others by email, not Linear's
// member/app/guest flags: a member who is not on this control plane is Others, and a
// control-plane person who is a guest is Team.
func TestTeamIsTheControlPlanesPeopleWhenGiven(t *testing.T) {
	people := teamMeta{"alex@example.com": teamPerson{Name: "Alex", You: true}}
	viewer := &Person{ID: "u1"}
	for _, c := range []struct {
		name  string
		issue Issue
		want  string
	}{
		{"a member not on this control plane", Issue{Creator: &Person{ID: "u2", Email: "sam@example.com"}}, sectionOthers},
		{"a guest who is on this control plane", Issue{Creator: &Person{ID: "u3", Email: "alex@example.com", Guest: true}}, sectionTeam},
		{"no creator", Issue{}, sectionOthers},
	} {
		if got := issueSection(c.issue, viewer, people); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}

func TestTeamMetaOfReadsThePeopleMetaByForge(t *testing.T) {
	meta := mcp.Meta{"people": []any{
		map[string]any{"name": "Alex", "linear": "Alex@Example.com", "you": true},
		map[string]any{"name": "No Linear login", "github": "kim"},
	}}
	people := teamMetaOf(meta, "linear")
	if len(people) != 1 {
		t.Fatalf("got %d people, want 1", len(people))
	}
	if alex, ok := people["alex@example.com"]; !ok || alex.Name != "Alex" || !alex.You {
		t.Errorf("alex: %+v, ok %v", alex, ok)
	}
	if teamMetaOf(nil, "linear") != nil {
		t.Error("no _meta: want nil")
	}
}

func TestAgentOnOfReadsTheLinearKey(t *testing.T) {
	meta := mcp.Meta{"agentOnLinear": map[string]any{"ENG-4": "a session"}}
	if got := agentOnOf(meta, "ENG-4"); got != "a session" {
		t.Errorf("got %q", got)
	}
	if got := agentOnOf(nil, "ENG-4"); got != "" {
		t.Errorf("no _meta: got %q", got)
	}
}
