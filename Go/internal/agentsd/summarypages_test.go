package agentsd

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The Summary row and page (#3721): summaries/list has the saved pages newest first, with
// their titles and writers; only the newest is unread, and reading it marks it and its
// writer's session read.
func TestSummaryPagesListAndRead(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	wid := dailySummaryID
	first := seeded(t, d, home, func(a *wire.Agent) { a.State, a.StartedByWorkflow = wire.AgentStateRunning, &wid })
	second := seeded(t, d, home, func(a *wire.Agent) { a.State, a.StartedByWorkflow = wire.AgentStateRunning, &wid })

	var pages []wire.SummaryPage
	json.Unmarshal(c.call(t, 1, "summaries/list", map[string]any{}), &pages)
	if len(pages) != 0 {
		t.Fatalf("pages before any was saved: %+v", pages)
	}
	at := time.Date(2026, 11, 5, 18, 10, 0, 0, time.Local)
	if _, err := d.saveSummary(first.ID, "# Daily summary, Thu 5 Nov\n", "", at); err != nil {
		t.Fatal(err)
	}
	if _, err := d.saveSummary(second.ID, "# Daily summary, Fri 6 Nov\n\n## Landed\n", "", at.AddDate(0, 0, 1)); err != nil {
		t.Fatal(err)
	}
	unseen := true
	d.change(second.ID, func(a *wire.Agent) { a.IsUnread = &unseen })

	json.Unmarshal(c.call(t, 2, "summaries/list", map[string]any{}), &pages)
	if len(pages) != 2 || pages[0].Name != "2026-11-06-1810" || pages[0].Title != "Daily summary, Fri 6 Nov" ||
		!pages[0].Unread || pages[0].Writer == nil || *pages[0].Writer != second.ID ||
		pages[1].Unread || pages[1].Writer == nil || *pages[1].Writer != first.ID || pages[0].SavedAt != wire.DateOf(at.AddDate(0, 0, 1)) {
		t.Fatalf("%+v", pages)
	}

	var older wire.SummaryPageText
	json.Unmarshal(c.call(t, 3, "summaries/read", wire.SummaryReadRequest{Name: pages[1].Name}), &older)
	if older.Markdown != "# Daily summary, Thu 5 Nov\n" || older.Page.Title != "Daily summary, Thu 5 Nov" {
		t.Fatalf("%+v", older)
	}
	var newest wire.SummaryPageText
	json.Unmarshal(c.call(t, 4, "summaries/read", wire.SummaryReadRequest{Name: pages[0].Name}), &newest)
	if newest.Page.Unread || summaryPagesUnread(d) {
		t.Fatalf("the newest page is still unread: %+v", newest.Page)
	}
	if a := d.Store.Agent(second.ID); a.IsUnread != nil && *a.IsUnread {
		t.Fatal("the writer's session is still unread")
	}
	if e := c.callError(t, 5, "summaries/read", wire.SummaryReadRequest{Name: "../secrets"}); e == nil {
		t.Fatal("a name that is no saved page was read")
	}
	if _, err := os.Stat(summaryMarksFile(home)); err != nil {
		t.Fatal(err)
	}
}

func summaryPagesUnread(d *Daemon) bool {
	for _, p := range d.summaryPages() {
		if p.Unread {
			return true
		}
	}
	return false
}
