package azureboardsmcp

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// A fake Azure DevOps over HTTP (no account, #3804): the work item paths the server reads and
// writes, for the project acme/Web App (a project's name may have a space), with what a test
// puts in it.

type obj = map[string]any

const (
	project = "acme/Web App"
	token   = "azure-boards-test"
)

type fakeItem struct {
	fields    obj
	updates   []obj
	comments  []obj
	relations []obj
}

type fakeBoards struct {
	t        *testing.T
	mu       sync.Mutex
	items    map[int]*fakeItem
	me       string
	queries  []string // the WIQL asked, in order
	posted   []obj    // what was POSTed to comments, with its query
	requests []string // every request's method and path
	status   int      // answer every request with this, when set
	// signIn answers as Azure DevOps does a token it does not take: 203 and a sign-in page.
	signIn bool
	server *httptest.Server
}

func newFake(t *testing.T) *fakeBoards {
	f := &fakeBoards{t: t, items: map[int]*fakeItem{}, me: alex["id"].(string)}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

// boards is a RealBoards of the fake that shares nothing between polls.
func (f *fakeBoards) boards() *RealBoards {
	b := NewRealBoards(f.server.URL, func() string { return token }, func(context.Context) (string, error) { return project, nil })
	b.sharing = 0
	return b
}

func (f *fakeBoards) set(change func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change()
}

var (
	alex = obj{"id": "a1", "displayName": "Alex", "uniqueName": "alex@acme.test", "descriptor": "aad.YWxleA"}
	dev  = obj{"id": "d2", "displayName": "Dev", "uniqueName": "dev@acme.test", "descriptor": "aad.ZGV2",
		"imageUrl": "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.ZGV2"}
	builder = obj{"id": "b3", "displayName": "Project Collection Build Service (acme)", "uniqueName": `Build\acme`, "descriptor": "svc.YnVpbGQ"}
)

var start = time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)

// at is start and n minutes, as Azure DevOps writes a time: seven places of a second.
func at(n int) string {
	return start.Add(time.Duration(n) * time.Minute).Format("2006-01-02T15:04:05.0000000Z")
}

// item puts a work item in the fake, made by by at minute n, and is it.
func (f *fakeBoards) item(id int, title, kind, state string, by obj, n int, extra obj) *fakeItem {
	fields := obj{fieldTitle: title, fieldType: kind, fieldState: state, fieldArea: `Web App\Team`, fieldCreatedBy: by,
		fieldCreated: at(n), fieldChanged: at(n), "System.TeamProject": "Web App"}
	for k, v := range extra {
		fields[k] = v
	}
	it := &fakeItem{fields: fields, updates: []obj{{"id": 1, "rev": 1, "revisedBy": by, "revisedDate": "9999-01-01T00:00:00Z",
		"fields": obj{fieldChanged: obj{"newValue": at(n)}, fieldState: obj{"newValue": state}}}}}
	f.set(func() { f.items[id] = it })
	return it
}

func (f *fakeBoards) query(i int) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.queries[i]
}

func (f *fakeBoards) lastQuery() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.queries[len(f.queries)-1]
}

func (f *fakeBoards) asked() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

func (f *fakeBoards) postedNow() []obj {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]obj(nil), f.posted...)
}

// update changes a work item at minute n, by by: each field's old and new value.
func (f *fakeBoards) update(id int, by obj, n int, changes map[string][2]any) {
	f.set(func() {
		it := f.items[id]
		fields := obj{fieldChanged: obj{"oldValue": it.fields[fieldChanged], "newValue": at(n)}}
		for name, c := range changes {
			change := obj{}
			if c[0] != nil {
				change["oldValue"] = c[0]
			}
			if c[1] != nil {
				change["newValue"] = c[1]
				it.fields[name] = c[1]
			} else {
				delete(it.fields, name)
			}
			fields[name] = change
		}
		it.fields[fieldChanged] = at(n)
		it.updates = append(it.updates, obj{"id": len(it.updates) + 1, "revisedBy": by, "fields": fields})
	})
}

// comment puts a comment on a work item at minute n.
func (f *fakeBoards) comment(id, commentID int, by obj, n int, text string) {
	f.set(func() {
		it := f.items[id]
		it.comments = append(it.comments, obj{"id": commentID, "workItemId": id, "text": text, "createdBy": by, "createdDate": at(n)})
		it.fields[fieldChanged] = at(n)
	})
}

// types is the project's work item types and their states' categories: Agile's.
var types = []obj{
	{"name": "Bug", "states": []obj{{"name": "New", "category": "Proposed"}, {"name": "Active", "category": "InProgress"},
		{"name": "Resolved", "category": "Resolved"}, {"name": "Closed", "category": "Completed"}}},
	{"name": "User Story", "states": []obj{{"name": "New", "category": "Proposed"}, {"name": "Active", "category": "InProgress"},
		{"name": "Closed", "category": "Completed"}, {"name": "Removed", "category": "Removed"}}},
}

var (
	itemPath  = regexp.MustCompile(`^/acme/Web App/_apis/wit/workItems/(\d+)/(updates|comments)$`)
	sinceWIQL = regexp.MustCompile(`\[(System\.CreatedDate|System\.ChangedDate)\] >= '([^']+)'`)
	stateWIQL = regexp.MustCompile(`\[System\.State\] (NOT IN|IN) \(([^)]*)\)`)
	tagWIQL   = regexp.MustCompile(`\[System\.Tags\] CONTAINS '([^']+)'`)
	// typeWIQL is a type or a tag, as the label epic asks (#3939).
	typeWIQL = regexp.MustCompile(`\(\[System\.WorkItemType\] = '([^']+)' OR \[System\.Tags\] CONTAINS '([^']+)'\)`)
)

func (f *fakeBoards) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, r.Method+" "+r.URL.Path)
	// Azure DevOps's names do not care about case: the forge names the project in lower case.
	if rest, ok := strings.CutPrefix(r.URL.Path, "/acme/web app/"); ok {
		r.URL.Path = "/acme/Web App/" + rest
	}
	if f.signIn {
		w.Header().Set("Content-Type", "text/html")
		w.WriteHeader(http.StatusNonAuthoritativeInfo)
		_, _ = io.WriteString(w, "<html>Sign in</html>")
		return
	}
	if f.status != 0 {
		w.Header().Set("Retry-After", "7")
		w.WriteHeader(f.status)
		_, _ = io.WriteString(w, `{"message":"no"}`)
		return
	}
	if r.Header.Get("Authorization") != "Basic "+base64.StdEncoding.EncodeToString([]byte(":"+token)) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	q := r.URL.Query()
	version := q.Get("api-version")
	answer := func(v any) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(v)
	}
	if f.serveForge(w, r, answer) {
		return
	}
	switch {
	case r.URL.Path == "/acme/_apis/connectionData":
		answer(obj{"authenticatedUser": obj{"id": f.me}})
	case r.URL.Path == "/acme/Web App/_apis/wit/workitemtypes" && version == apiVersion:
		answer(obj{"value": types})
	case r.URL.Path == "/acme/Web App/_apis/wit/wiql" && r.Method == http.MethodPost && version == apiVersion && q.Get("timePrecision") == "true":
		var body struct{ Query string }
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.queries = append(f.queries, body.Query)
		top, _ := strconv.Atoi(q.Get("$top"))
		answer(obj{"workItems": f.wiql(body.Query, top)})
	case r.URL.Path == "/acme/Web App/_apis/wit/workitemsbatch" && r.Method == http.MethodPost && version == apiVersion:
		var body struct {
			IDs    []int    `json:"ids"`
			Fields []string `json:"fields"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		list := []any{}
		for _, id := range body.IDs {
			it, ok := f.items[id]
			if !ok {
				list = append(list, nil)
				continue
			}
			fields := obj{}
			for _, name := range body.Fields {
				if v, ok := it.fields[name]; ok {
					fields[name] = v
				}
			}
			list = append(list, obj{"id": id, "fields": fields})
		}
		answer(obj{"count": len(list), "value": list})
	case itemPath.MatchString(r.URL.Path):
		m := itemPath.FindStringSubmatch(r.URL.Path)
		id, _ := strconv.Atoi(m[1])
		it, ok := f.items[id]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"message":"TF401232: Work item does not exist"}`)
			return
		}
		if m[2] == "updates" && version == apiVersion {
			top, _ := strconv.Atoi(q.Get("$top"))
			skip, _ := strconv.Atoi(q.Get("$skip"))
			page := it.updates[min(skip, len(it.updates)):min(skip+top, len(it.updates))]
			answer(obj{"count": len(page), "value": page})
			return
		}
		if m[2] == "comments" && version == commentsVersion && r.Method == http.MethodGet {
			list := append([]obj(nil), it.comments...)
			if q.Get("order") == "desc" {
				sort.SliceStable(list, func(i, j int) bool { return list[i]["createdDate"].(string) > list[j]["createdDate"].(string) })
			}
			top, _ := strconv.Atoi(q.Get("$top"))
			answer(obj{"totalCount": len(list), "count": min(top, len(list)), "comments": list[:min(top, len(list))]})
			return
		}
		if m[2] == "comments" && version == commentsVersion && r.Method == http.MethodPost {
			var body obj
			_ = json.NewDecoder(r.Body).Decode(&body)
			body["format"] = q.Get("format")
			f.posted = append(f.posted, body)
			made := obj{"id": 900 + len(f.posted), "text": body["text"], "createdBy": alex, "createdDate": at(99)}
			it.comments = append(it.comments, made)
			answer(made)
			return
		}
		w.WriteHeader(http.StatusBadRequest)
	default:
		f.t.Errorf("the fake has no %s %s", r.Method, r.URL)
		w.WriteHeader(http.StatusNotFound)
	}
}

// wiql is the work items a query finds, changed last first, at most top: by its time, its
// states (every state clause), a type or a tag, a tag and @Me, the parts of WIQL the server writes.
func (f *fakeBoards) wiql(query string, top int) []obj {
	var ids []int
	for id, it := range f.items {
		if m := sinceWIQL.FindStringSubmatch(query); m != nil && mcpevents.Normalized(it.fields[m[1]].(string)) < m[2] {
			continue
		}
		kept := true
		for _, m := range stateWIQL.FindAllStringSubmatch(query, -1) {
			if in := strings.Contains(m[2], "'"+it.fields[fieldState].(string)+"'"); in != (m[1] == "IN") {
				kept = false
			}
		}
		if !kept {
			continue
		}
		tag, _ := it.fields[fieldTags].(string)
		if m := typeWIQL.FindStringSubmatch(query); m != nil && it.fields[fieldType] != m[1] && !containsFold(tags(tag), m[2]) {
			continue
		}
		if m := tagWIQL.FindStringSubmatch(typeWIQL.ReplaceAllString(query, "")); m != nil {
			if !containsFold(tags(tag), m[1]) {
				continue
			}
		}
		if strings.Contains(query, "[System.AssignedTo] = @Me") {
			who, _ := it.fields[fieldAssigned].(obj)
			if who == nil || who["id"] != f.me {
				continue
			}
		}
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool {
		a, b := f.items[ids[i]].fields[fieldChanged].(string), f.items[ids[j]].fields[fieldChanged].(string)
		if a == b {
			return ids[i] > ids[j]
		}
		return a > b
	})
	out := []obj{}
	for _, id := range ids[:min(top, len(ids))] {
		out = append(out, obj{"id": id, "url": f.server.URL + "/_apis/wit/workItems/" + strconv.Itoa(id)})
	}
	return out
}
