package azureboardsmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
)

// The forge reads and writes (#3815) against the fake Azure DevOps: the organization's WIQL and
// batch reads, a work item with its links, and the JSON Patch writes.

var (
	orgItemPath   = regexp.MustCompile(`^/acme/_apis/wit/workitems/(\d+)$`)
	patchItemPath = regexp.MustCompile(`^/acme/Web App/_apis/wit/workitems/(\d+)$`)
	makeItemPath  = regexp.MustCompile(`^/acme/Web App/_apis/wit/workitems/\$(.+)$`)
)

// serveForge answers the forge's paths, and says whether it did. f.mu is held.
func (f *fakeBoards) serveForge(w http.ResponseWriter, r *http.Request, answer func(any)) bool {
	q := r.URL.Query()
	full := func(id int, it *fakeItem) obj {
		relations := it.relations
		if relations == nil {
			relations = []obj{}
		}
		return obj{"id": id, "rev": len(it.updates), "fields": it.fields, "relations": relations}
	}
	switch {
	case r.URL.Path == "/acme/_apis/wit/wiql" && r.Method == http.MethodPost && q.Get("timePrecision") == "true":
		var body struct{ Query string }
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.queries = append(f.queries, body.Query)
		top, _ := strconv.Atoi(q.Get("$top"))
		answer(obj{"workItems": f.wiql(body.Query, top)})
	case r.URL.Path == "/acme/_apis/wit/workitemsbatch" && r.Method == http.MethodPost:
		var body struct {
			IDs    []int    `json:"ids"`
			Fields []string `json:"fields"`
			Expand string   `json:"$expand"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Expand != "" && len(body.Fields) > 0 {
			w.WriteHeader(http.StatusBadRequest) // as Azure DevOps: not both
			return true
		}
		list := []any{}
		for _, id := range body.IDs {
			it, ok := f.items[id]
			switch {
			case !ok:
				list = append(list, nil)
			case body.Expand == "relations":
				list = append(list, full(id, it))
			default:
				fields := obj{}
				for _, name := range body.Fields {
					if v, ok := it.fields[name]; ok {
						fields[name] = v
					}
				}
				list = append(list, obj{"id": id, "fields": fields})
			}
		}
		answer(obj{"count": len(list), "value": list})
	case orgItemPath.MatchString(r.URL.Path) && r.Method == http.MethodGet && q.Get("$expand") == "relations":
		id, _ := strconv.Atoi(orgItemPath.FindStringSubmatch(r.URL.Path)[1])
		it, ok := f.items[id]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"message":"TF401232: Work item does not exist"}`)
			return true
		}
		answer(full(id, it))
	case patchItemPath.MatchString(r.URL.Path) && r.Method == http.MethodPatch:
		id, _ := strconv.Atoi(patchItemPath.FindStringSubmatch(r.URL.Path)[1])
		it := f.items[id]
		if r.Header.Get("Content-Type") != "application/json-patch+json" || it == nil {
			w.WriteHeader(http.StatusBadRequest)
			return true
		}
		var ops []obj
		_ = json.NewDecoder(r.Body).Decode(&ops)
		if !f.apply(it, ops) {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"message":"TF26071: This work item has been changed by someone else since you opened it."}`)
			return true
		}
		answer(full(id, it))
	case makeItemPath.MatchString(r.URL.Path) && r.Method == http.MethodPost:
		kind := makeItemPath.FindStringSubmatch(r.URL.Path)[1]
		var ops []obj
		_ = json.NewDecoder(r.Body).Decode(&ops)
		id := 100 + len(f.items)
		it := &fakeItem{fields: obj{fieldType: kind, fieldState: "New", "System.TeamProject": "Web App", fieldChanged: at(99)}}
		f.apply(it, ops)
		f.items[id] = it
		answer(full(id, it))
	case r.URL.Path == "/acme/Web App/Payments/_apis/work/teamsettings/teamfieldvalues" && q.Get("api-version") == apiVersion:
		answer(obj{"field": obj{"referenceName": fieldArea}, "defaultValue": `Web App\Payments`,
			"values": []obj{{"value": `Web App\Payments`, "includeChildren": true}, {"value": "Web App", "includeChildren": false}}})
	case r.URL.Path == "/acme/Web App/Custom/_apis/work/teamsettings/teamfieldvalues":
		answer(obj{"field": obj{"referenceName": "Acme.Team"}, "values": []obj{{"value": "Custom"}}})
	case r.URL.Path == "/acme/Web App/_apis/wit/tags" && q.Get("api-version") == tagsVersion:
		answer(obj{"count": 2, "value": []obj{{"id": "t1", "name": "billing"}, {"id": "t2", "name": "ux"}}})
	default:
		return false
	}
	return true
}

// apply is a JSON Patch on a work item, as one update; false when its test fails.
func (f *fakeBoards) apply(it *fakeItem, ops []obj) bool {
	for _, op := range ops {
		path, _ := op["path"].(string)
		switch {
		case op["op"] == "test" && path == "/rev":
			if int(op["value"].(float64)) != len(it.updates) {
				return false
			}
		case op["op"] == "add" && strings.HasPrefix(path, "/fields/"):
			it.fields[strings.TrimPrefix(path, "/fields/")] = op["value"]
		case op["op"] == "add" && path == "/relations/-":
			it.relations = append(it.relations, op["value"].(obj))
		case op["op"] == "remove" && strings.HasPrefix(path, "/relations/"):
			n, _ := strconv.Atoi(strings.TrimPrefix(path, "/relations/"))
			it.relations = slices.Delete(it.relations, n, n+1)
		default:
			f.t.Errorf("the fake has no patch %v", op)
		}
	}
	it.updates = append(it.updates, obj{"id": len(it.updates) + 1})
	return true
}

func (f *fakeBoards) link(from int, rel string, to int) {
	f.set(func() {
		it := f.items[from]
		it.relations = append(it.relations, obj{"rel": rel, "url": f.server.URL + "/acme/_apis/wit/workItems/" + strconv.Itoa(to)})
	})
}

func (f *fakeBoards) field(id int, name string) any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.items[id].fields[name]
}

// forgeFake is a fake with a story, a closed bug, and an active bug of the story's assigned to Alex.
func forgeFake(t *testing.T) (*fakeBoards, *RealBoards) {
	f := newFake(t)
	f.item(1, "Export the invoices", "User Story", "New", alex, 1, obj{fieldTags: "billing", fieldComments: 1,
		fieldDesc: "<p><b>Bold</b> words.</p><script>alert(1)</script>"})
	f.item(2, "A crash", "Bug", "Closed", dev, 2, nil)
	f.item(3, "Read the invoices", "Bug", "Active", dev, 3, obj{fieldAssigned: alex, fieldParent: 1})
	return f, f.boards()
}

func ids(items []Item) []int {
	out := []int{}
	for _, i := range items {
		out = append(out, i.ID)
	}
	return out
}

// #3815: a list is the open work items, the last changed first, with the state's name, its
// type's category as open or closed, its tags, parent and assignee, in pages that go on.
func TestForgeSearch(t *testing.T) {
	f, b := forgeFake(t)
	ctx := context.Background()
	page, err := b.Search(ctx, []string{"acme/Web App"}, SearchFilter{}, "", 50)
	if err != nil || !slices.Equal(ids(page.Items), []int{3, 1}) || page.Next != "" {
		t.Fatalf("open: %v %+v", err, page)
	}
	i := page.Items[0]
	if i.Project != "acme/web app" || i.State != "open" || i.Status != "Active" || i.Type != "Bug" || i.Parent != 1 ||
		!slices.Equal(i.Assignees, []string{"alex@acme.test"}) || i.Author != "dev@acme.test" ||
		i.AuthorAvatar != "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.ZGV2" ||
		i.URL != f.server.URL+"/acme/web%20app/_workitems/edit/3" || i.UpdatedAt != mcpevents.Normalized(at(3)) {
		t.Fatalf("item: %+v", i)
	}
	if !strings.Contains(f.lastQuery(), "[System.TeamProject] IN ('web app')") || !strings.Contains(f.lastQuery(), "[System.State] NOT IN ('Closed', 'Removed')") {
		t.Fatalf("query: %s", f.lastQuery())
	}
	if page.Items[1].Comments != 1 || !slices.Equal(page.Items[1].Labels, []string{"billing"}) {
		t.Fatalf("story: %+v", page.Items[1])
	}
	page, _ = b.Search(ctx, []string{"acme/web app"}, SearchFilter{State: "closed"}, "", 50)
	if !slices.Equal(ids(page.Items), []int{2}) || page.Items[0].State != "closed" {
		t.Fatalf("closed: %+v", page)
	}
	// One at a time: each page goes on from the last.
	var seen []int
	after := ""
	for range 4 {
		page, err = b.Search(ctx, []string{"acme/web app"}, SearchFilter{State: "all"}, after, 1)
		if err != nil {
			t.Fatal(err)
		}
		seen = append(seen, ids(page.Items)...)
		if after = page.Next; after == "" {
			break
		}
	}
	if !slices.Equal(seen, []int{3, 2, 1}) {
		t.Fatalf("pages: %v", seen)
	}
	if _, err := b.Search(ctx, []string{"acme/web app"}, SearchFilter{}, "acme=x", 1); err == nil {
		t.Fatal("a cursor no list gave was taken")
	}
}

// #3815: the WIQL a filter makes: a project's quotes doubled, tags, an assignee and words.
func TestForgeSearchWhere(t *testing.T) {
	got := SearchWhere([]string{"acme/Kim's app", "acme/web"}, SearchFilter{State: "closed", Label: "ux", Feature: "work", Assignee: "kim@acme.test", Query: "export"},
		[]string{"Closed"})
	want := "[System.TeamProject] IN ('Kim''s app', 'web') AND [System.State] IN ('Closed') AND [System.Tags] CONTAINS 'ux' AND " +
		"[System.Tags] CONTAINS 'feature:work' AND [System.AssignedTo] = 'kim@acme.test' AND " +
		"([System.Title] CONTAINS 'export' OR [System.Description] CONTAINS WORDS 'export')"
	if got != want {
		t.Fatalf("where:\n%s\nnot\n%s", got, want)
	}
}

// #3939: the label epic finds the Epic work items, with or without the tag, and a story tagged
// epic, for Work ▸ Features; a feature narrows them.
func TestForgeSearchFindsEpicsByTheirType(t *testing.T) {
	f, b := forgeFake(t)
	f.item(4, "Invoices", "Epic", "New", alex, 4, obj{fieldTags: "feature:billing"})
	f.item(5, "Payments", "Epic", "Active", alex, 5, nil)
	f.item(6, "Tagged", "User Story", "New", alex, 6, obj{fieldTags: "Epic; feature:billing"})
	ctx := context.Background()
	page, err := b.Search(ctx, []string{"acme/web app"}, SearchFilter{State: "all", Label: "epic"}, "", 50)
	if err != nil || !slices.Equal(ids(page.Items), []int{6, 5, 4}) {
		t.Fatalf("epics: %v %v", err, ids(page.Items))
	}
	if !strings.Contains(f.lastQuery(), "([System.WorkItemType] = 'Epic' OR [System.Tags] CONTAINS 'epic')") {
		t.Fatalf("query: %s", f.lastQuery())
	}
	page, _ = b.Search(ctx, []string{"acme/web app"}, SearchFilter{State: "all", Label: "epic", Feature: "billing"}, "", 50)
	if !slices.Equal(ids(page.Items), []int{6, 4}) || page.Items[1].Type != "Epic" {
		t.Fatalf("billing's epics: %v", ids(page.Items))
	}
}

// #3815: a work item's page: its description, made safe, as Markdown, its comments oldest first
// (HTML ones as Markdown), and the other states of its type.
func TestForgeItemPage(t *testing.T) {
	f, b := forgeFake(t)
	f.comment(1, 7, dev, 4, "<p>Hi <b>there</b></p>")
	f.comment(1, 8, builder, 5, "**Built.**")
	f.set(func() { f.items[1].comments[1]["format"] = "markdown" })
	f.link(1, relChild, 3)
	d, err := b.ItemPage(context.Background(), "acme/Web App", 1, "")
	if err != nil {
		t.Fatal(err)
	}
	if d.Body != "**Bold** words." || d.Status != "New" || d.SubTotal != 1 || d.Before != "" {
		t.Fatalf("page: %+v", d)
	}
	if len(d.Thread) != 2 || d.Thread[0].Body != "Hi **there**" || d.Thread[0].Author != "dev@acme.test" ||
		d.Thread[0].Avatar != "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.ZGV2" || d.Thread[1].Body != "**Built.**" || !d.Thread[1].Bot {
		t.Fatalf("comments: %+v", d.Thread)
	}
	want := []Transition{{"Active", "Active", "indeterminate"}, {"Closed", "Closed", "done"}, {"Removed", "Removed", "done"}}
	if !slices.Equal(d.Transitions, want) {
		t.Fatalf("transitions: %+v", d.Transitions)
	}
	if _, err := b.ItemPage(context.Background(), "acme/web app", 404, ""); err == nil || err.(*BoardsError).Kind != NotFound {
		t.Fatalf("404: %v", err)
	}
	if _, err := b.ItemPage(context.Background(), "acme/other", 1, ""); err == nil || err.(*BoardsError).Kind != NotFound {
		t.Fatalf("a work item of another project: %v", err)
	}
}

// #4626: a work item's page has its children, by id, with their titles and states, from one
// batch read; a work item with no child has an empty list and no read more.
func TestForgeItemPageChildren(t *testing.T) {
	f, b := forgeFake(t)
	f.link(1, relChild, 3)
	f.link(1, relChild, 2)
	d, err := b.ItemPage(context.Background(), "acme/Web App", 1, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Children) != 2 || d.Children[0].ID != 2 || d.Children[0].Title != "A crash" || d.Children[0].State != "closed" ||
		d.Children[1].ID != 3 || d.Children[1].State != "open" || d.Children[1].URL != f.server.URL+"/acme/web%20app/_workitems/edit/3" {
		t.Fatalf("children: %+v", d.Children)
	}
	d, err = b.ItemPage(context.Background(), "acme/Web App", 3, "")
	if err != nil || d.Children == nil || len(d.Children) != 0 {
		t.Fatalf("no children: %v %+v", err, d.Children)
	}
}

// #3815: tags are added and taken off in one change, a state is one of its type's, and close
// and reopen are its type's first Completed and Proposed states; a comment is Markdown.
func TestForgeWrites(t *testing.T) {
	f, b := forgeFake(t)
	ctx := context.Background()
	if err := b.SetTags(ctx, "acme/web app", 1, []string{"ux", "Billing"}, []string{"nope"}); err != nil {
		t.Fatal(err)
	}
	if err := b.SetTags(ctx, "acme/web app", 1, []string{"api"}, []string{"BILLING"}); err != nil {
		t.Fatal(err)
	}
	if got := f.field(1, fieldTags); got != "ux; api" {
		t.Fatalf("tags: %v", got)
	}
	if err := b.Transition(ctx, "acme/web app", 3, "Resolved"); err != nil || f.field(3, fieldState) != "Resolved" {
		t.Fatalf("Resolved: %v %v", err, f.field(3, fieldState))
	}
	if err := b.Transition(ctx, "acme/web app", 3, "Removed"); err == nil {
		t.Fatal("a Bug moved to Removed, a state it does not have")
	}
	if err := b.SetState(ctx, "acme/web app", 3, true); err != nil || f.field(3, fieldState) != "Closed" {
		t.Fatalf("close: %v %v", err, f.field(3, fieldState))
	}
	if err := b.SetState(ctx, "acme/web app", 3, false); err != nil || f.field(3, fieldState) != "New" {
		t.Fatalf("reopen: %v %v", err, f.field(3, fieldState))
	}
	url, err := b.Comment(ctx, "acme/web app", 1, "**On it.**")
	if posted := f.postedNow(); err != nil || len(posted) != 1 || posted[0]["format"] != "markdown" || url != f.server.URL+"/acme/web%20app/_workitems/edit/1" {
		t.Fatalf("comment: %v %q %v", err, url, posted)
	}
	names, _, err := b.Labels(ctx, "acme/web app", 1)
	if err != nil || !slices.Equal(names, []string{"api", "billing", "ux"}) {
		t.Fatalf("labels: %v %q", err, names)
	}
}

// #3815: a plan is a work item's children, each blocked by its predecessors (open or not); a
// new child is of its level's type, and a child that is there changes its parent.
func TestForgePlanAndItsWrites(t *testing.T) {
	f, b := forgeFake(t)
	ctx := context.Background()
	f.item(4, "Write the export", "User Story", "Active", dev, 4, nil)
	f.link(1, relChild, 3)
	f.link(1, relChild, 4)
	f.link(4, relPredecessor, 3)
	f.link(4, relPredecessor, 2)
	p, err := b.Plan(ctx, "acme/web app", 1)
	if err != nil {
		t.Fatal(err)
	}
	if p.Epic.ID != 1 || p.Epic.SubTotal != 2 || p.Epic.SubDone != 0 || !slices.Equal(ids([]Item{p.Children[0].Item, p.Children[1].Item}), []int{3, 4}) {
		t.Fatalf("plan: %+v", p)
	}
	if want := []Ref{{"acme/web app", 3, true}, {"acme/web app", 2, false}}; !slices.Equal(p.Children[1].BlockedBy, want) {
		t.Fatalf("blockers: %+v", p.Children[1].BlockedBy)
	}

	id, url, err := b.AddChild(ctx, "acme/web app", 1, "Send the export", []string{"story", "feature:work"}, "story")
	if err != nil || url != f.server.URL+"/acme/web%20app/_workitems/edit/"+itoa(id) {
		t.Fatalf("child: %v %d %q", err, id, url)
	}
	if f.field(id, fieldType) != "User Story" || f.field(id, fieldTitle) != "Send the export" || f.field(id, fieldTags) != "story; feature:work" {
		t.Fatalf("child's fields: %v", f.items[id].fields)
	}
	if rel := f.items[id].relations; len(rel) != 1 || rel[0]["rel"] != relParent || !strings.HasSuffix(rel[0]["url"].(string), "/acme/_apis/wit/workItems/1") {
		t.Fatalf("child's parent: %v", rel)
	}
	if _, _, err := b.AddChild(ctx, "acme/web app", 1, "Send it", nil, "task"); err == nil {
		t.Fatal("a Task in a process with none")
	}

	f.item(5, "Another epic", "User Story", "New", dev, 5, nil)
	f.link(3, relParent, 1)
	if err := b.SetParent(ctx, "acme/web app", 3, 5); err != nil {
		t.Fatal(err)
	}
	if rel := f.items[3].relations; len(rel) != 1 || !strings.HasSuffix(rel[0]["url"].(string), "/workItems/5") {
		t.Fatalf("3's parent: %v", rel)
	}
	if err := b.SetBlockedBy(ctx, "acme/web app", 4, 2, false); err != nil {
		t.Fatal(err)
	}
	if err := b.SetBlockedBy(ctx, "acme/web app", 4, 5, true); err != nil {
		t.Fatal(err)
	}
	if err := b.SetBlockedBy(ctx, "acme/web app", 4, 5, true); err != nil {
		t.Fatal(err)
	}
	var blockers []string
	for _, r := range f.items[4].relations {
		blockers = append(blockers, r["url"].(string)[strings.LastIndex(r["url"].(string), "/")+1:])
	}
	if !slices.Equal(blockers, []string{"3", "5"}) {
		t.Fatalf("4's predecessors: %v", blockers)
	}
}

// #3816: a board's team is its area paths, and a list narrowed to it is the work items in them;
// a team by another field is refused.
func TestForgeTeamAreas(t *testing.T) {
	_, b := forgeFake(t)
	ctx := context.Background()
	areas, err := b.TeamAreas(ctx, "acme/Web App", "Payments")
	if err != nil || !slices.Equal(areas, []Area{{Path: `Web App\Payments`, Under: true}, {Path: "Web App"}}) {
		t.Fatalf("areas: %v %+v", err, areas)
	}
	got := SearchWhere([]string{"acme/Web App"}, SearchFilter{State: "all", Areas: areas}, []string{"Closed"})
	if want := `[System.TeamProject] IN ('Web App') AND ([System.AreaPath] UNDER 'Web App\Payments' OR [System.AreaPath] = 'Web App')`; got != want {
		t.Fatalf("where:\n%s\nnot\n%s", got, want)
	}
	if _, err := b.TeamAreas(ctx, "acme/Web App", "Custom"); err == nil || !strings.Contains(err.Error(), "Acme.Team") {
		t.Fatalf("a custom team field: %v", err)
	}
}

// #4242: Blockers are each work item's predecessors, from one read of their links and one of
// the predecessors' states; one with none says none.
func TestBlockersAreThePredecessors(t *testing.T) {
	f, b := forgeFake(t)
	f.item(4, "Write the export", "User Story", "Active", dev, 4, nil)
	f.link(4, relPredecessor, 3)
	f.link(4, relPredecessor, 2)
	by, err := b.Blockers(context.Background(), "acme/Web App", []int{4, 3})
	if err != nil {
		t.Fatal(err)
	}
	if want := []Ref{{"acme/web app", 3, true}, {"acme/web app", 2, false}}; !slices.Equal(by[4], want) || by[3] == nil || len(by[3]) != 0 {
		t.Fatalf("blockers: %+v", by)
	}
	if by, err := b.Blockers(context.Background(), "acme/web app", nil); err != nil || len(by) != 0 {
		t.Fatalf("none asked: %v %v", by, err)
	}
}

// A closed work item's state category and System.Reason say why it closed (#4365).
func TestStateReasonOf(t *testing.T) {
	for _, c := range []struct{ category, reason, want string }{
		{"Completed", "Work finished", "completed"},
		{"Completed", "Duplicate", "duplicate"},
		{"Completed", "Cut", "not_planned"},
		{"Completed", "Removed from the backlog", "not_planned"},
		{"Removed", "Moved to state Removed", "not_planned"},
	} {
		if got := stateReasonOf(c.category, c.reason); got != c.want {
			t.Errorf("%s %q: %q, want %q", c.category, c.reason, got, c.want)
		}
	}
}

// #4373: a work item says when it was made, and a closed one when its state last changed.
func TestForgeItemDates(t *testing.T) {
	states := map[string]map[string]string{"Task": {"Active": "InProgress", "Closed": "Completed"}}
	for state, closed := range map[string]string{"Active": "", "Closed": "2026-10-02T10:00:00.000Z"} {
		w := workItemJSON{ID: 1, Fields: map[string]json.RawMessage{fieldType: json.RawMessage(`"Task"`), fieldState: json.RawMessage(`"` + state + `"`),
			fieldCreated: json.RawMessage(`"2026-10-01T10:00:00Z"`), fieldStateChanged: json.RawMessage(`"2026-10-02T10:00:00Z"`)}}
		if i := (&RealBoards{}).forgeItem("acme", w, states); i.CreatedAt != "2026-10-01T10:00:00.000Z" || i.ClosedAt != closed {
			t.Errorf("%s: %q %q", state, i.CreatedAt, i.ClosedAt)
		}
	}
}
