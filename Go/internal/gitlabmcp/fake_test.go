package gitlabmcp

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// A fake GitLab over HTTP (no account, #1629): the REST API v4 paths the server reads and
// writes, for the project group/app, with what a test puts in it.

type obj = map[string]any

const (
	project   = "group/app"
	projectID = 7
	token     = "glpat-test"
)

type fakeGitLab struct {
	t        *testing.T
	mu       sync.Mutex
	mrs      []obj
	pipes    []obj
	jobs     map[int][]obj
	commits  map[string][]obj
	issues   []obj
	activity []obj
	members  map[int]int // user id → access level
	// memberLists counts the calls that list members by user_ids[] (#2952).
	memberLists int
	requests []string
	posted   []obj         // what was POSTed or PUT, with its path
	diffs    map[int][]obj // merge request → its files
	discuss  map[int][]obj // merge request → its discussions
	traces   map[int]string
	labelled map[int][]obj // issue → its resource label events
	status   int           // answer every request with this, when set
	header   http.Header
	sent     int // bytes of the bodies answered
	server   *httptest.Server
}

func newFake(t *testing.T) *fakeGitLab {
	f := &fakeGitLab{t: t, jobs: map[int][]obj{}, commits: map[string][]obj{}, members: map[int]int{}, diffs: map[int][]obj{},
		discuss: map[int][]obj{}, traces: map[int]string{}, labelled: map[int][]obj{}}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

// gitlab is a RealGitLab of the fake that shares nothing between polls.
func (f *fakeGitLab) gitlab() *RealGitLab {
	g := NewRealGitLab(f.server.URL, func() string { return token }, func(context.Context) (string, error) { return project, nil })
	g.sharing = 0
	return g
}

var (
	alex     = obj{"id": 1, "username": "alex"}
	dev      = obj{"id": 2, "username": "dev"}
	stranger = obj{"id": 3, "username": "stranger"}
	tokenBot = obj{"id": 4, "username": "project_7_bot_0a1b2c"}
	guest    = obj{"id": 5, "username": "guest"}
)

func (f *fakeGitLab) addMembers() {
	f.members[1], f.members[2], f.members[4], f.members[5] = 50, 30, 40, 10
}

func mrJSON(iid int, branch string, author obj, extra obj) obj {
	m := obj{"iid": iid, "title": "MR " + strconv.Itoa(iid), "state": "opened", "source_branch": branch, "target_branch": "main",
		"web_url": "https://gitlab.test/group/app/-/merge_requests/" + strconv.Itoa(iid), "author": author, "draft": false,
		"source_project_id": projectID, "target_project_id": projectID, "has_conflicts": false,
		"detailed_merge_status": "mergeable", "merge_status": "can_be_merged", "sha": "head" + strconv.Itoa(iid),
		"created_at": at(-60), "updated_at": at(-60), "labels": []string{}}
	for k, v := range extra {
		m[k] = v
	}
	return m
}

func issueObj(iid int, author obj, extra obj) obj {
	i := obj{"iid": iid, "title": "Issue " + strconv.Itoa(iid), "state": "opened", "author": author,
		"web_url": "https://gitlab.test/group/app/-/issues/" + strconv.Itoa(iid), "labels": []string{}, "assignees": []obj{},
		"created_at": at(-60), "updated_at": at(-60)}
	for k, v := range extra {
		i[k] = v
	}
	return i
}

var (
	start = time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	path  = regexp.MustCompile(`^/api/v4/projects/group%2Fapp(?:/(.*))?$`)
)

func at(minutes int) string { return timeString(start.Add(time.Duration(minutes) * time.Minute)) }

func (f *fakeGitLab) set(fn func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn()
}

func (f *fakeGitLab) asked() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.requests...)
}

func (f *fakeGitLab) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, r.Method+" "+r.URL.RequestURI())
	answer := func(status int, v any) {
		w.Header().Set("Content-Type", "application/json")
		for k, vs := range f.header {
			w.Header()[k] = vs
		}
		body, _ := json.Marshal(v)
		// GitLab's Rack ETag: a weak one over the body, and 304 for a GET that sends it back.
		if r.Method == http.MethodGet && status == 200 {
			etag := fmt.Sprintf(`W/"%x"`, sha256.Sum256(body))
			w.Header().Set("ETag", etag)
			if r.Header.Get("If-None-Match") == etag {
				w.WriteHeader(http.StatusNotModified)
				return
			}
		}
		w.WriteHeader(status)
		f.sent += len(body)
		_, _ = w.Write(body)
	}
	if r.Header.Get("Authorization") != "Bearer "+token {
		answer(401, obj{"message": "401 Unauthorized"})
		return
	}
	if f.status != 0 {
		answer(f.status, obj{"message": "refused"})
		return
	}
	if r.URL.Path == "/api/v4/user" {
		answer(200, alex)
		return
	}
	m := path.FindStringSubmatch(r.URL.EscapedPath())
	if m == nil {
		answer(404, obj{"message": "404 Project Not Found"})
		return
	}
	parts := strings.Split(m[1], "/")
	q := r.URL.Query()
	byIID := func(list []obj, key string, n string) (obj, bool) {
		for _, o := range list {
			if strconv.Itoa(o[key].(int)) == n {
				return o, true
			}
		}
		return nil, false
	}
	// atHead is whether this request sent merge request iid's head sha.
	atHead := func(iid string) bool {
		o, ok := byIID(f.mrs, "iid", iid)
		return ok && len(f.posted) > 0 && f.posted[len(f.posted)-1]["sha"] == o["sha"]
	}
	// stated is list's items in that state, in the order asked for and the page asked for, as
	// GitLab answers.
	stated := func(list []obj, key, want string) []obj {
		out := []obj{}
		for _, o := range list {
			if want == "" || want == "all" || o[key] == want {
				out = append(out, o)
			}
		}
		if by := q.Get("order_by"); strings.HasSuffix(by, "_at") && q.Get("sort") == "desc" {
			sort.SliceStable(out, func(i, j int) bool { s, _ := out[i][by].(string); t, _ := out[j][by].(string); return s > t })
		}
		if size, _ := strconv.Atoi(q.Get("per_page")); size > 0 {
			page, _ := strconv.Atoi(q.Get("page"))
			first := min(len(out), max(0, page-1)*size)
			out = out[first:min(len(out), first+size)]
		}
		return out
	}
	if r.Method != http.MethodGet {
		body, _ := io.ReadAll(r.Body)
		var sent obj
		_ = json.Unmarshal(body, &sent)
		sent["path"] = m[1]
		f.posted = append(f.posted, sent)
	}
	switch {
	case len(parts) == 1 && parts[0] == "":
		answer(200, obj{"id": projectID, "path_with_namespace": project, "default_branch": "main"})
	case len(parts) == 1 && parts[0] == "merge_requests" && r.Method == http.MethodPost:
		answer(201, mrJSON(12, "agent/issue-2", alex, nil))
	case len(parts) == 5 && parts[0] == "merge_requests" && parts[2] == "discussions" && parts[4] == "notes" && r.Method == http.MethodPost:
		answer(201, obj{"id": 901, "body": "x"})
	case len(parts) == 3 && parts[0] == "issues" && parts[2] == "notes" && r.Method == http.MethodGet:
		answer(200, []obj{{"id": 50, "body": "added ~bug", "system": true, "author": alex},
			{"id": 51, "body": "Please also do this.", "author": stranger}, {"id": 52, "body": "Yes, do.", "author": dev}})
	case len(parts) == 3 && parts[0] == "issues" && parts[2] == "resource_label_events":
		id, _ := strconv.Atoi(parts[1])
		answer(200, orEmpty(f.labelled[id]))
	case len(parts) == 1 && parts[0] == "merge_requests":
		answer(200, whose(stated(f.mrs, "state", q.Get("state")), q))
	case len(parts) == 2 && parts[0] == "merge_requests":
		if o, ok := byIID(f.mrs, "iid", parts[1]); ok {
			answer(200, o)
			return
		}
		answer(404, obj{"message": "404 Not found"})
	case len(parts) == 3 && parts[0] == "merge_requests" && (parts[2] == "merge" || parts[2] == "approve") && !atHead(parts[1]):
		// GitLab's answer to a sha that is not the head.
		answer(409, obj{"message": "SHA does not match HEAD of source branch"})
	case len(parts) == 3 && parts[0] == "merge_requests" && parts[2] == "merge" && r.Method == http.MethodPut:
		answer(200, obj{"iid": 1, "state": "merged", "merge_commit_sha": "merged1"})
	case len(parts) == 3 && parts[0] == "merge_requests" && parts[2] == "diffs":
		id, _ := strconv.Atoi(parts[1])
		answer(200, stated(orEmpty(f.diffs[id]), "", ""))
	case len(parts) == 3 && parts[0] == "merge_requests" && parts[2] == "discussions":
		id, _ := strconv.Atoi(parts[1])
		answer(200, orEmpty(f.discuss[id]))
	case len(parts) == 3 && parts[0] == "merge_requests" && parts[2] == "approve" && r.Method == http.MethodPost:
		answer(201, obj{"id": 1})
	case len(parts) == 3 && parts[0] == "pipelines" && parts[2] == "retry" && r.Method == http.MethodPost:
		answer(201, obj{"id": 100, "status": "pending", "web_url": "https://gitlab.test/p/100"})
	case len(parts) == 3 && parts[0] == "jobs" && parts[2] == "trace":
		id, _ := strconv.Atoi(parts[1])
		w.WriteHeader(200)
		_, _ = io.WriteString(w, f.traces[id])
	case len(parts) == 3 && parts[2] == "notes" && r.Method == http.MethodPost:
		answer(201, obj{"id": 900, "body": "x"})
	case len(parts) == 1 && parts[0] == "pipelines":
		answer(200, stated(f.pipes, "status", q.Get("status")))
	case len(parts) == 2 && parts[0] == "pipelines":
		if o, ok := byIID(f.pipes, "id", parts[1]); ok {
			answer(200, o)
			return
		}
		answer(404, obj{"message": "404 Not found"})
	case len(parts) == 3 && parts[0] == "pipelines" && parts[2] == "jobs":
		id, _ := strconv.Atoi(parts[1])
		jobs := f.jobs[id]
		if jobs == nil {
			jobs = []obj{}
		}
		if q.Get("scope[]") == "failed" {
			jobs = stated(jobs, "status", "failed")
		}
		answer(200, jobs)
	case len(parts) == 4 && parts[0] == "repository" && parts[1] == "commits" && parts[3] == "merge_requests":
		list := f.commits[parts[2]]
		if list == nil {
			list = []obj{}
		}
		answer(200, list)
	case len(parts) == 1 && parts[0] == "issues":
		answer(200, whose(stated(f.issues, "state", q.Get("state")), q))
	case len(parts) == 2 && parts[0] == "issues":
		if o, ok := byIID(f.issues, "iid", parts[1]); ok {
			answer(200, o)
			return
		}
		answer(404, obj{"message": "404 Not found"})
	case len(parts) == 1 && parts[0] == "events":
		answer(200, f.activity)
	case len(parts) == 2 && parts[0] == "members" && parts[1] == "all":
		f.memberLists++
		out := []obj{}
		for _, v := range q["user_ids[]"] {
			id, _ := strconv.Atoi(v)
			if level, ok := f.members[id]; ok {
				out = append(out, obj{"id": id, "access_level": level})
			}
		}
		answer(200, out)
	case len(parts) == 3 && parts[0] == "members" && parts[1] == "all":
		id, _ := strconv.Atoi(parts[2])
		if level, ok := f.members[id]; ok {
			answer(200, obj{"id": id, "access_level": level})
			return
		}
		answer(404, obj{"message": "404 Not found"})
	default:
		answer(404, obj{"message": "404 Not found"})
	}
}

func orEmpty(list []obj) []obj {
	if list == nil {
		return []obj{}
	}
	return list
}

// whose narrows a list as GitLab's author_username, reviewer_username and assignee_username do (#2034).
func whose(list []obj, q url.Values) []obj {
	named := func(o obj, key string) []string {
		var out []string
		switch v := o[key].(type) {
		case obj:
			out = append(out, fmt.Sprint(v["username"]))
		case []obj:
			for _, u := range v {
				out = append(out, fmt.Sprint(u["username"]))
			}
		}
		return out
	}
	out := []obj{}
	for _, o := range list {
		keep := true
		for param, key := range map[string]string{"author_username": "author", "reviewer_username": "reviewers", "assignee_username": "assignees"} {
			if want := q.Get(param); want != "" && !slices.Contains(named(o, key), want) {
				keep = false
			}
		}
		if keep {
			out = append(out, o)
		}
	}
	return out
}
