package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Notify me (#2034): the project's github server lists its events with two on at first, a
// choice is the person's and kept on the host, and what a chosen event brings is a notice:
// a need of the kind notice with the item's address, one for the same item, gone once opened.
func TestNotifyMeListsChoosesAndNotices(t *testing.T) {
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	project := t.TempDir()
	os.MkdirAll(filepath.Join(project, ".agents"), 0o755)
	b, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{
		"github": map[string]any{"command": "github-mcp"}, "other": map[string]any{"command": "other-mcp"}}})
	os.WriteFile(filepath.Join(project, ".agents", "mcp.json"), b, 0o644)
	c.call(t, 1, "projects/add", map[string]any{"folder": "file://" + project})

	var list wire.NotifyList
	json.Unmarshal(c.call(t, 2, "notify/list", map[string]any{"folder": project}), &list)
	if len(list.Servers) != 1 || list.Servers[0].Server != "github" || list.Servers[0].Title != "GitHub" || len(list.Servers[0].Events) != 4 {
		t.Fatalf("list: %+v", list)
	}
	on := map[string]bool{}
	for _, e := range list.Servers[0].Events {
		on[e.Event] = e.On
	}
	if !on["checks.failed"] || !on["review.requested"] || on["pr.conflicted"] || on["issue.assigned"] {
		t.Fatalf("at first: %v", on)
	}

	json.Unmarshal(c.call(t, 3, "notify/set", map[string]any{"folder": project, "server": "github", "event": "issue.assigned", "on": true}), &list)
	if !list.Servers[0].Events[3].On {
		t.Fatalf("after set: %+v", list.Servers[0].Events)
	}
	kept, _ := os.ReadFile(filepath.Join(root, "notify-me.json"))
	if !strings.Contains(string(kept), `"issue.assigned":true`) {
		t.Fatalf("kept: %s", kept)
	}
	if msg := c.callErr(t, 4, "notify/set", map[string]any{"folder": project, "server": "other", "event": "issue.assigned", "on": true}); msg == "" {
		t.Fatal("a server Notify me does not know took a choice")
	}

	s := &mcpSubscription{project: project, server: "github", event: "review.requested"}
	id, data := "e1", json.RawMessage(`{"pr":{"number":12,"title":"Fix the walk","url":"https://github.com/o/n/pull/12"},"requestedAt":"x"}`)
	d.addNotice(mcpPolled{EventID: &id, Data: data}, s)
	d.addNotice(mcpPolled{EventID: &id, Data: data}, s)
	notices := noticesOf(d)
	if len(notices) != 1 {
		t.Fatalf("notices: %+v", notices)
	}
	n := notices[0]
	if n.Kind != wire.NeedKindNotice || n.AgentID != nil || n.URL == nil || *n.URL != "https://github.com/o/n/pull/12" ||
		n.Headline.H2 != "GitHub" || n.Headline.H3 != "Review requested on #12 Fix the walk" {
		t.Fatalf("notice: %+v", n)
	}
	c.call(t, 5, "notice/open", map[string]any{"id": *n.ID.Notice})
	if len(noticesOf(d)) != 0 {
		t.Fatal("an opened notice stayed")
	}
}

func noticesOf(d *Daemon) []wire.Need {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	var out []wire.Need
	for _, n := range d.needs() {
		if n.Kind == wire.NeedKindNotice {
			out = append(out, n)
		}
	}
	return out
}

func TestNoticeWordsForEachEvent(t *testing.T) {
	for _, c := range []struct{ event, data, want string }{
		{"checks.failed", `{"pr":{"number":3,"title":"A","url":"u"}}`, "Checks failed on #3 A"},
		{"pr.conflicted", `{"pr":{"number":3,"title":"A","url":"u"}}`, "#3 A is in conflict"},
		{"issue.assigned", `{"issue":{"identifier":"ENG-9","title":"B","url":"u"}}`, "Assigned to you: ENG-9 B"},
	} {
		got, url := noticeWords(c.event, json.RawMessage(c.data))
		if got != c.want || url != "u" {
			t.Errorf("%s: %q %q", c.event, got, url)
		}
	}
}
