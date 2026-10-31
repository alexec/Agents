package linearmcp

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// RealLinear over answers in Linear's shape, kept in testdata/ by query name.

type recorded struct {
	mu        sync.Mutex
	asked     []map[string]any // each request's variables
	names     []string
	auth      string
	status    int
	answer    string // when set, the body of every answer
	header    http.Header
	testdataT *testing.T
}

var operation = regexp.MustCompile(`^\s*query (\w+)`)

func (r *recorded) serve(w http.ResponseWriter, req *http.Request) {
	var body struct {
		Query     string         `json:"query"`
		Variables map[string]any `json:"variables"`
	}
	data, _ := io.ReadAll(req.Body)
	if err := json.Unmarshal(data, &body); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	name := operation.FindStringSubmatch(body.Query)[1]
	r.mu.Lock()
	r.asked = append(r.asked, body.Variables)
	r.names = append(r.names, name)
	r.auth = req.Header.Get("Authorization")
	r.mu.Unlock()
	for k, v := range r.header {
		w.Header()[k] = v
	}
	if r.status != 0 {
		w.WriteHeader(r.status)
	}
	if r.answer != "" {
		_, _ = io.WriteString(w, r.answer)
		return
	}
	answer, err := os.ReadFile("testdata/" + name + ".json")
	if err != nil {
		r.testdataT.Errorf("no testdata for %s", name)
	}
	_, _ = w.Write(answer)
}

func newRecorded(t *testing.T) (*recorded, *RealLinear) {
	r := &recorded{testdataT: t}
	server := httptest.NewServer(http.HandlerFunc(r.serve))
	t.Cleanup(server.Close)
	return r, NewRealLinear(server.URL, func() string { return "lin_api_test" })
}

func TestOpenedReadsIssuesCreatedSince(t *testing.T) {
	r, l := newRecorded(t)
	items, truncated, err := l.Activity(context.Background(), Opened, "ENG", "2026-10-16T12:00:00.000Z")
	if err != nil || truncated || len(items) != 1 {
		t.Fatalf("%v %v %v", items, truncated, err)
	}
	if r.auth != "lin_api_test" {
		t.Fatalf("a personal key goes as it is, not %q", r.auth)
	}
	filter, _ := json.Marshal(r.asked[0]["filter"])
	if string(filter) != `{"createdAt":{"gte":"2026-10-16T12:00:00.000Z"},"team":{"key":{"eq":"ENG"}}}` {
		t.Fatalf("filter %s", filter)
	}
	it := items[0]
	if it.ID != "7d1c" || it.Issue.Identifier != "ENG-5" || it.Issue.Team != "ENG" || it.Issue.Labels[0] != "Bug" || !it.trusted() {
		t.Fatalf("%+v", it)
	}
}

func TestCommentedSkipsCommentsOnNoIssue(t *testing.T) {
	_, l := newRecorded(t)
	items, _, err := l.Activity(context.Background(), Commented, "", "2026-10-16T12:00:00.000Z")
	if err != nil || len(items) != 1 {
		t.Fatalf("%v %v", items, err)
	}
	if items[0].CommentBody != "Seen it too" || items[0].By.Name != "alex" || items[0].Issue.Identifier != "ENG-5" {
		t.Fatalf("%+v", items[0])
	}
}

func TestLabelsAndClosesComeFromHistorySince(t *testing.T) {
	r, l := newRecorded(t)
	since := "2026-10-16T12:00:00.000Z"
	labels, truncated, err := l.Activity(context.Background(), Labelled, "", since)
	if err != nil || !truncated {
		t.Fatalf("%v %v", truncated, err)
	}
	// h1 is before since; h2 was GitHub's integration, an app.
	if len(labels) != 1 || labels[0].ID != "h2:Mac" || labels[0].Label != "Mac" || labels[0].trusted() {
		t.Fatalf("labels %+v", labels)
	}
	closes, _, err := l.Activity(context.Background(), Closed, "", since)
	if err != nil {
		t.Fatal(err)
	}
	// h4 moves from one closed state to another: not a close.
	if len(closes) != 1 || closes[0].ID != "h3" || closes[0].Reason != "completed" || !closes[0].trusted() {
		t.Fatalf("closes %+v", closes)
	}
	if len(r.names) != 1 {
		t.Fatalf("labels and closes share one query in a poll: %v", r.names)
	}
}

func TestOneAnswerIsSharedForAPoll(t *testing.T) {
	r, l := newRecorded(t)
	for range 3 {
		if _, _, err := l.Activity(context.Background(), Opened, "", "2026-10-16T12:00:00.000Z"); err != nil {
			t.Fatal(err)
		}
	}
	if len(r.names) != 1 {
		t.Fatalf("asked %d times", len(r.names))
	}
}

func TestIssueDetailsRenderMarkdown(t *testing.T) {
	r, l := newRecorded(t)
	details, err := l.IssueDetails(context.Background(), "ENG-5")
	if err != nil || details["identifier"] != "ENG-5" || !strings.Contains(details["descriptionHTML"].(string), "<strong>Inspect</strong>") {
		t.Fatalf("details %v, %v", details, err)
	}
	if len(r.names) != 1 || r.names[0] != "IssueDetails" || r.asked[0]["id"] != "ENG-5" {
		t.Fatalf("query: %v %v", r.names, r.asked)
	}
}

func TestLinearsRefusals(t *testing.T) {
	for _, c := range []struct {
		status int
		body   string
		header http.Header
		kind   ErrorKind
	}{
		{400, `{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}`,
			http.Header{"X-Ratelimit-Requests-Reset": {strconv.FormatInt(time.Now().Add(time.Minute).UnixMilli(), 10)}}, RateLimited},
		{400, `{"errors":[{"message":"Authentication required, not authenticated","extensions":{"code":"AUTHENTICATION_ERROR"}}]}`, nil, NotSignedIn},
		{200, `{"data":null,"errors":[{"message":"Entity not found: Issue","extensions":{"code":"INVALID_INPUT"}}]}`, nil, NotFound},
		{500, `oops`, nil, Failed},
	} {
		r, l := newRecorded(t)
		r.status, r.answer, r.header = c.status, c.body, c.header
		_, _, err := l.Activity(context.Background(), Opened, "", "2026-10-16T12:00:00.000Z")
		var le *LinearError
		if !errors.As(err, &le) || le.Kind != c.kind {
			t.Fatalf("%s: %v", c.body, err)
		}
		if c.kind == RateLimited && (le.RetryAfterMs <= 0 || le.RetryAfterMs > 60000) {
			t.Fatalf("retry %d", le.RetryAfterMs)
		}
	}
	l := NewRealLinear("http://127.0.0.1:1", func() string { return "" })
	var le *LinearError
	if _, _, err := l.Activity(context.Background(), Opened, "", "2026-10-16T12:00:00.000Z"); !errors.As(err, &le) || le.Kind != NotSignedIn {
		t.Fatalf("no key: %v", err)
	}
}

// issue.assigned (#2034): an assignment to the connection's owner, by anyone, from the same history.
func TestAssignedIsToTheViewerFromTheSameHistory(t *testing.T) {
	_, l := newRecorded(t)
	got, _, err := l.Activity(context.Background(), Assigned, "", "2026-10-16T12:00:00.000Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ID != "h5" || got[0].data()["by"] != "bob" || got[0].data()["assignedAt"] == nil {
		t.Fatalf("assigned %+v", got)
	}
}
