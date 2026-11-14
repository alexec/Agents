package agentsd

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #4553: a PR's node keeps its opening, its needs-approval label and its first answer by a
// person, not a bot's or an agent's, and time/history says how long it waited.
func TestLineageApprovalWait(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	const url = "https://github.com/alexec/Agents/pull/9"
	opened := time.Now().Add(-3 * time.Hour).UTC().Truncate(time.Second)
	stamp := func(after time.Duration) string { return opened.Add(after).Format(time.RFC3339) }
	raise := func(name, payload string) {
		d.lineageEvent(wire.Event{Name: name, Details: map[string]string{"payload": payload}})
	}
	comment := func(after time.Duration, author, body string) {
		raise("pr.commented", fmt.Sprintf(`{"pr":{"number":9,"url":%q},"comment":{"author":%q,"body":%q},"commentedAt":%q}`,
			url, author, body, stamp(after)))
	}
	review := func(after time.Duration, author string) {
		raise("pr.reviewed", fmt.Sprintf(`{"pr":{"number":9,"url":%q},"review":{"author":%q,"state":"approved","body":""},"reviewedAt":%q}`,
			url, author, stamp(after)))
	}
	raise("pr.opened", fmt.Sprintf(`{"pr":{"number":9,"title":"A","url":%q},"openedAt":%q}`, url, stamp(0)))
	// An answer before the label is not an answer to it.
	comment(2*time.Minute, "alexec", "Looks odd")
	raise("pr.labelled", fmt.Sprintf(`{"pr":{"number":9,"url":%q},"label":"needs-approval","by":"alexec","labelledAt":%q}`, url, stamp(5*time.Minute)))
	raise("pr.labelled", fmt.Sprintf(`{"pr":{"number":9,"url":%q},"label":"approved","by":"alexec","labelledAt":%q}`, url, stamp(time.Minute)))
	comment(10*time.Minute, "alexec", "<!-- agent --> Screenshots are up")
	review(20*time.Minute, "alexec-agents[bot]")
	review(65*time.Minute, "alexec")
	comment(90*time.Minute, "alexec", "ship it")
	d.lineageSettle(5 * time.Second)

	repo, n, _ := d.prOfURLHere(url)
	d.workMu.Lock()
	got := d.costLedgerLocked().Nodes[costKey(repo.pr(n))]
	d.workMu.Unlock()
	date := func(after time.Duration) wire.Date { return wire.DateOf(opened.Add(after)) }
	if got.OpenedAt == nil || *got.OpenedAt != date(0) || got.AskedAt == nil || *got.AskedAt != date(5*time.Minute) {
		t.Fatalf("opened %v, asked %v", got.OpenedAt, got.AskedAt)
	}
	if got.AnsweredAt == nil || *got.AnsweredAt != date(65*time.Minute) {
		t.Fatalf("answered %v", got.AnsweredAt)
	}

	var h wire.TimeHistory
	if err := json.Unmarshal(c.call(t, 1, "time/history", wire.Empty{}), &h); err != nil {
		t.Fatal(err)
	}
	w := h.ApprovalWait
	if w == nil || w.Count != 1 || w.Value == nil || *w.Value != 3600 || w.P90 == nil || len(w.Weeks) != 4 {
		t.Fatalf("approval wait %+v", w)
	}
}

func TestPersonsAnswer(t *testing.T) {
	for _, tc := range []struct {
		author, body string
		want         bool
	}{
		{"alexec", "ship it", true},
		{"alexec", "  <!-- agent --> done", false},
		{"alexec-agents[bot]", "ok", false},
		{"CodeRabbitAI[Bot]", "ok", false},
		{"", "ok", false},
	} {
		if got := personsAnswer(tc.author, tc.body); got != tc.want {
			t.Errorf("%q %q: %v", tc.author, tc.body, got)
		}
	}
}
