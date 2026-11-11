package githubmcp

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// #4654: the open milestones are read with their due dates, as a day; one with none has "".
func TestMilestonesHaveTheirDueDates(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/o/r/milestones" || r.URL.Query().Get("state") != "open" {
			t.Errorf("asked %s?%s", r.URL.Path, r.URL.RawQuery)
		}
		io.WriteString(w, `[{"title":"Planning","due_on":"2026-11-20T08:00:00Z"},{"title":"Later","due_on":null}]`)
	}))
	t.Cleanup(s.Close)
	got, err := NewRealGitHub(s.URL, func() string { return "t" }, nil).Milestones(context.Background(), "o/r")
	if err != nil || len(got) != 2 || got[0] != (Milestone{Title: "Planning", Due: "2026-11-20"}) || got[1] != (Milestone{Title: "Later"}) {
		t.Fatalf("milestones: %+v %v", got, err)
	}
}
