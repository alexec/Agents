package githubmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

// #4172: Timeline reads the open epics, then those closed since a time, a page at a time, each
// with its sub-issues' dates and the PRs that close them; the releases come with the first page,
// drafts left out; an epic in both lists is said once.
func TestTimelineReadsEpicsChildrenAndReleases(t *testing.T) {
	issue := func(n int, state, extra string) string {
		return `{"number":` + strconv.Itoa(n) + `,"title":"t","url":"u","issueState":"` + state + `","updatedAt":"2026-11-08T10:00:00Z","author":null,
		 "repository":{"nameWithOwner":"alexec/Agents"},"labels":{"nodes":[{"name":"epic"}]},"assignees":{"nodes":[]},"milestone":null,
		 "commentCount":{"totalCount":0},"parent":null,"subIssuesSummary":{"total":1,"completed":0},
		 "createdAt":"2026-11-01T00:00:00Z","closedAt":null,"stateReason":null` + extra + `}`
	}
	child := `"subIssues":{"nodes":[` + strings.TrimSuffix(issue(11, "CLOSED", `,"closedByPullRequestsReferences":{"nodes":[{"createdAt":"2026-11-02T00:00:00Z"}]}`), "}") +
		`}]}`
	child = strings.Replace(child, `"closedAt":null,"stateReason":null`, `"closedAt":"2026-11-03T00:00:00Z","stateReason":"COMPLETED"`, 1)
	var asked []map[string]any
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &req)
		asked = append(asked, req.Variables)
		releases := `"releases":{"nodes":[{"tagName":"v1","publishedAt":"2026-11-05T00:00:00Z","url":"r1","isDraft":false},{"tagName":"v2","publishedAt":"2026-11-06T00:00:00Z","url":"r2","isDraft":true}]}`
		states := req.Variables["states"].([]any)
		switch {
		case states[0] == "OPEN" && req.Variables["after"] == nil:
			io.WriteString(w, `{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[`+issue(1, "OPEN", ","+child)+`]},`+releases+`}}}`)
		case states[0] == "OPEN":
			io.WriteString(w, `{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[`+issue(2, "OPEN", `,"subIssues":{"nodes":[]}`)+`]},`+releases+`}}}`)
		default:
			io.WriteString(w, `{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false},"nodes":[`+issue(2, "OPEN", `,"subIssues":{"nodes":[]}`)+`,`+
				strings.Replace(issue(3, "CLOSED", `,"subIssues":{"nodes":[]}`), `"closedAt":null,"stateReason":null`, `"closedAt":"2026-11-04T00:00:00Z","stateReason":"NOT_PLANNED"`, 1)+`]},`+releases+`}}}`)
		}
	}))
	t.Cleanup(s.Close)
	g := NewRealGitHub(s.URL, func() string { return "t" }, nil)
	tl, err := g.Timeline(context.Background(), "alexec/Agents", "2026-10-09T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(asked) != 3 || asked[0]["since"] != nil || asked[2]["since"] != "2026-10-09T00:00:00Z" || asked[1]["after"] != "c1" ||
		asked[0]["releases"] != float64(timelineReleases) || asked[1]["releases"] != float64(1) {
		t.Fatalf("asked %v", asked)
	}
	if len(tl.Releases) != 1 || tl.Releases[0].Tag != "v1" {
		t.Fatalf("releases %+v", tl.Releases)
	}
	if len(tl.Epics) != 3 || tl.Epics[2].StateReason != "not_planned" || tl.Epics[2].ClosedAt == "" {
		t.Fatalf("epics %+v", tl.Epics)
	}
	c := tl.Epics[0].Children
	if len(c) != 1 || c[0].State != "closed" || c[0].StateReason != "completed" || c[0].ClosedAt != "2026-11-03T00:00:00Z" ||
		len(c[0].PROpenedAt) != 1 || c[0].CreatedAt != "2026-11-01T00:00:00Z" {
		t.Fatalf("children %+v", c)
	}
}
