package forgejomcp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// An epic's plan (#3835) against a stand-in Forgejo: the epic, the issues it depends on (one in
// another repository, and a pull request, left out), each child's own dependencies; and the
// writes, a dependency added and taken off, and a new issue with its labels.

type planFake struct {
	mu   sync.Mutex
	sent []string
}

func dep(repo string, number int, state string, pr bool) obj {
	o := obj{"number": number, "title": fmt.Sprintf("Issue %d", number), "state": state, "html_url": "https://fj.test/" + repo + "/issues/" + fmt.Sprint(number),
		"user": alex, "labels": []obj{}, "updated_at": at(1), "repository": obj{"full_name": repo}}
	if pr {
		o["pull_request"] = obj{"merged": false}
	}
	return o
}

func (f *planFake) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	p := strings.TrimPrefix(r.URL.Path, "/api/v1/")
	if r.Method != http.MethodGet {
		body, _ := io.ReadAll(r.Body)
		f.sent = append(f.sent, r.Method+" "+p+" "+strings.TrimSpace(string(body)))
	}
	w.Header().Set("Content-Type", "application/json")
	var out any = []obj{}
	switch {
	case p == "repos/acme/app/issues/1":
		out = obj{"number": 1, "title": "Export epic", "state": "open", "html_url": "https://fj.test/acme/app/issues/1", "user": alex,
			"labels": []obj{{"id": 1, "name": "epic"}, {"id": 2, "name": "feature:export", "color": "5319E7"}}, "updated_at": at(5)}
	case p == "repos/acme/app/issues/8":
		out = obj{"number": 8, "title": "A pull request", "state": "open", "user": alex, "updated_at": at(5), "pull_request": obj{"merged": false}}
	case p == "repos/acme/app/issues/1/dependencies":
		if r.URL.Query().Get("page") == "1" {
			out = []obj{dep("acme/app", 2, "open", false), dep("acme/app", 3, "closed", false), dep("acme/lib", 4, "open", false), dep("acme/app", 8, "open", true)}
		}
	case p == "repos/acme/app/issues/2/dependencies" && r.URL.Query().Get("page") == "1":
		out = []obj{dep("acme/app", 3, "closed", false), dep("acme/lib", 4, "open", false)}
	case p == "repos/acme/lib/issues/4/dependencies" && r.URL.Query().Get("page") == "1":
		out = []obj{dep("acme/other", 9, "open", false)}
	case p == "repos/acme/app/issues" && r.Method == http.MethodPost:
		out = obj{"number": 12, "title": "New", "state": "open", "html_url": "https://fj.test/acme/app/issues/12", "user": alex}
	case strings.HasSuffix(p, "/labels") || strings.HasSuffix(p, "/dependencies"):
	default:
		w.WriteHeader(http.StatusNotFound)
		out = obj{"message": "not found"}
	}
	_ = json.NewEncoder(w).Encode(out)
}

func newPlanFake(t *testing.T) (*planFake, *RealForgejo) {
	f := &planFake{}
	server := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(server.Close)
	fj := NewRealForgejo(server.URL, func() string { return token }, nil)
	fj.sharing = 0
	return f, fj
}

func TestAPlanIsTheIssuesAnEpicDependsOn(t *testing.T) {
	_, fj := newPlanFake(t)
	p, err := fj.Plan(context.Background(), "acme/app", 1)
	if err != nil {
		t.Fatal(err)
	}
	if p.Epic.Number != 1 || p.Epic.Labels[1] != "feature:export" || p.Epic.LabelColors["feature:export"] != "#5319e7" {
		t.Fatalf("epic: %+v", p.Epic)
	}
	var got []string
	for _, c := range p.Children {
		line := fmt.Sprintf("%s#%d %s:", c.Repo, c.Number, c.State)
		for _, b := range c.BlockedBy {
			line += fmt.Sprintf(" %s#%d open=%v", b.Repo, b.Number, b.Open)
		}
		got = append(got, line)
	}
	want := []string{"acme/app#2 open: acme/app#3 open=false acme/lib#4 open=true", "acme/app#3 closed:", "acme/lib#4 open: acme/other#9 open=true"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("children:\n%s", strings.Join(got, "\n"))
	}
	if _, err := fj.Plan(context.Background(), "acme/app", 8); !IsNotFound(err) {
		t.Fatalf("a pull request's plan: %v", err)
	}
	if _, err := fj.Plan(context.Background(), "acme/app", 404); !IsNotFound(err) {
		t.Fatalf("no such issue: %v", err)
	}
}

func TestThePlansWrites(t *testing.T) {
	f, fj := newPlanFake(t)
	ctx := context.Background()
	if err := fj.SetBlockedBy(ctx, "acme/app", 2, "acme/lib", 4, true); err != nil {
		t.Fatal(err)
	}
	if err := fj.SetBlockedBy(ctx, "acme/app", 2, "acme/app", 3, false); err != nil {
		t.Fatal(err)
	}
	n, url, err := fj.CreateIssue(ctx, "acme/app", "New", []string{"story", "feature:export"})
	if err != nil || n != 12 || url != "https://fj.test/acme/app/issues/12" {
		t.Fatalf("created %d %s %v", n, url, err)
	}
	want := []string{
		`POST repos/acme/app/issues/2/dependencies {"index":4,"owner":"acme","repo":"lib"}`,
		`DELETE repos/acme/app/issues/2/dependencies {"index":3,"owner":"acme","repo":"app"}`,
		`POST repos/acme/app/issues {"title":"New"}`,
		`POST repos/acme/app/issues/12/labels {"labels":["story","feature:export"]}`,
	}
	if strings.Join(f.sent, "\n") != strings.Join(want, "\n") {
		t.Fatalf("sent:\n%s", strings.Join(f.sent, "\n"))
	}
	if err := fj.SetBlockedBy(ctx, "acme/app", 2, "nobody", 4, true); err == nil {
		t.Fatal("a blocker with no owner")
	}
}

// #4242: Blockers are each issue's dependencies, a call each.
func TestBlockersAreEachIssuesDependencies(t *testing.T) {
	_, fj := newPlanFake(t)
	by, err := fj.Blockers(context.Background(), "acme/app", []int{2, 3})
	if err != nil {
		t.Fatal(err)
	}
	if len(by) != 2 || len(by[2]) != 2 || by[2][0] != (Ref{Repo: "acme/app", Number: 3}) || by[2][1] != (Ref{Repo: "acme/lib", Number: 4, Open: true}) ||
		by[3] == nil || len(by[3]) != 0 {
		t.Fatalf("blockers: %+v", by)
	}
}
