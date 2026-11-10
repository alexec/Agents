package bitbucketmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// A fake Bitbucket Cloud over HTTP (no account, #2828): the REST API 2.0 paths the server
// reads and writes, for the repository acme/app, with what a test puts in it.

type obj = map[string]any

const (
	repo  = "acme/app"
	token = "bitbucket-test"
)

type fakeBitbucket struct {
	t             *testing.T
	mu            sync.Mutex
	pulls         []obj
	activity      map[int][]obj // pull request → its activity, newest first
	diffstat      map[int][]obj
	prComments    map[int][]obj
	statuses      map[string][]obj  // commit → its statuses
	pipelines     map[int]obj       // Pipelines build number → its run
	steps         map[int][]obj     // Pipelines build number → its steps
	logs          map[string]string // step uuid → its log, served from storage
	ranges        []string          // the Range of each log read from storage
	issues        []obj
	issueComments map[int][]obj
	changes       map[int][]obj
	perms         map[string]string // account id → permission
	members       map[string]bool   // account id → in the workspace
	me            obj
	posted        []obj // what was POSTed, with its path
	// adminless answers 403 to a permission read, as Bitbucket does for a token without admin.
	adminless bool
	// noTracker answers 404 to every issue path, as for a repository with its tracker off.
	noTracker bool
	// email is the email a Basic login must give; "" wants a Bearer token.
	email string
	// branches is each branch's head commit, for refs/branches; the repository's main branch is main.
	branches map[string]string
	// defaultMerge is the main branch's default merge strategy, when set; diffs a pull
	// request's git diff, by its number (the views, #3866).
	defaultMerge string
	diffs        map[int]string
	// milestones, commits (by sha or tag), each compare's commits ("head..base", given two to a
	// page by a token, as Bitbucket's) and each commit's pull requests, for lineage (#3879).
	milestones  []obj
	commits     map[string]obj
	compares    map[string][]obj
	commitPulls map[string][]obj
	status      int // answer every request with this, when set
	server      *httptest.Server
	// storage is where a step's log redirects to, as Bitbucket's goes to its file store.
	storage *httptest.Server
}

func newFake(t *testing.T) *fakeBitbucket {
	f := &fakeBitbucket{t: t, activity: map[int][]obj{}, diffstat: map[int][]obj{}, prComments: map[int][]obj{}, statuses: map[string][]obj{},
		issueComments: map[int][]obj{}, changes: map[int][]obj{},
		perms: map[string]string{"a-alex": "admin", "a-dev": "write", "a-reader": "read"}, members: map[string]bool{}, me: alex}
	f.pipelines, f.steps, f.logs = map[int]obj{}, map[int][]obj{}, map[string]string{}
	f.branches, f.diffs = map[string]string{}, map[int]string{}
	f.commits, f.compares, f.commitPulls = map[string]obj{}, map[string][]obj{}, map[string][]obj{}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	f.storage = httptest.NewServer(http.HandlerFunc(f.serveLog))
	t.Cleanup(f.storage.Close)
	return f
}

// bitbucket is a RealBitbucket of the fake that shares nothing between polls.
func (f *fakeBitbucket) bitbucket() *RealBitbucket {
	bb := NewRealBitbucket(f.server.URL, func() string { return token }, func() string { return f.email },
		func(context.Context) (string, error) { return repo, nil })
	bb.sharing = 0
	return bb
}

func (f *fakeBitbucket) set(change func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change()
}

func person(n int, nickname string) obj {
	return obj{"type": "user", "uuid": "{" + strconv.Itoa(n) + "}", "account_id": "a-" + nickname, "nickname": nickname,
		"display_name": strings.ToUpper(nickname[:1]) + nickname[1:],
		"links":        obj{"avatar": obj{"href": "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/a-" + nickname + "/48"}}}
}

var (
	alex      = person(1, "alex")
	dev       = person(2, "dev")
	stranger  = person(3, "stranger")
	renovate  = person(4, "renovate-bot")
	reader    = person(5, "reader")
	pipelines = obj{"type": "app_user", "uuid": "{6}", "account_id": "a-app", "nickname": "Pipelines"}
)

var start = time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)

// at is start and n minutes, as Bitbucket writes a time.
func at(n int) string {
	return start.Add(time.Duration(n) * time.Minute).Format("2006-01-02T15:04:05.000000-07:00")
}

func pull(number int, branch string, author obj, extra obj) obj {
	p := obj{"id": number, "title": "PR " + strconv.Itoa(number), "description": "", "state": "OPEN", "author": author, "draft": false,
		"links":       obj{"html": obj{"href": "https://bitbucket.org/acme/app/pull-requests/" + strconv.Itoa(number)}},
		"source":      obj{"branch": obj{"name": branch}, "commit": obj{"hash": "sha" + strconv.Itoa(number)}, "repository": obj{"full_name": repo}},
		"destination": obj{"branch": obj{"name": "main"}, "commit": obj{"hash": "base"}, "repository": obj{"full_name": repo}},
		"created_on":  at(0), "updated_on": at(0), "reviewers": []any{}}
	for k, v := range extra {
		p[k] = v
	}
	return p
}

func issue(number int, reporter obj, extra obj) obj {
	i := obj{"id": number, "title": "Issue " + strconv.Itoa(number), "content": obj{"raw": ""}, "state": "new", "kind": "bug",
		"priority": "major", "reporter": reporter, "assignee": nil,
		"links":      obj{"html": obj{"href": "https://bitbucket.org/acme/app/issues/" + strconv.Itoa(number)}},
		"created_on": at(0), "updated_on": at(0)}
	for k, v := range extra {
		i[k] = v
	}
	return i
}

func comment(id int, by obj, body, when string, extra obj) obj {
	c := obj{"id": id, "content": obj{"raw": body}, "user": by, "created_on": when, "deleted": false,
		"links": obj{"html": obj{"href": "https://bitbucket.org/c/" + strconv.Itoa(id)}}}
	for k, v := range extra {
		c[k] = v
	}
	return c
}

const root = "/repositories/acme/app"

var (
	pullsPath         = regexp.MustCompile(`^` + root + `/pullrequests$`)
	pullPath          = regexp.MustCompile(`^` + root + `/pullrequests/([0-9]+)$`)
	activityPath      = regexp.MustCompile(`^` + root + `/pullrequests/([0-9]+)/activity$`)
	diffstatPath      = regexp.MustCompile(`^` + root + `/pullrequests/([0-9]+)/diffstat$`)
	diffPath          = regexp.MustCompile(`^` + root + `/pullrequests/([0-9]+)/diff$`)
	prCommentsPath    = regexp.MustCompile(`^` + root + `/pullrequests/([0-9]+)/comments$`)
	prCommentPath     = regexp.MustCompile(`^` + root + `/pullrequests/([0-9]+)/comments/([0-9]+)$`)
	mergePath         = regexp.MustCompile(`^` + root + `/pullrequests/([0-9]+)/(merge|approve)$`)
	statusesPath      = regexp.MustCompile(`^` + root + `/commit/([^/]+)/statuses$`)
	issuesPath        = regexp.MustCompile(`^` + root + `/issues$`)
	issuePath         = regexp.MustCompile(`^` + root + `/issues/([0-9]+)$`)
	issueCommentsPath = regexp.MustCompile(`^` + root + `/issues/([0-9]+)/comments$`)
	changesPath       = regexp.MustCompile(`^` + root + `/issues/([0-9]+)/changes$`)
	pipelinesPath     = regexp.MustCompile(`^` + root + `/pipelines/$`)
	pipelinePath      = regexp.MustCompile(`^` + root + `/pipelines/([0-9]+)$`)
	stepsPath         = regexp.MustCompile(`^` + root + `/pipelines/([0-9]+)/steps$`)
	branchPath        = regexp.MustCompile(`^` + root + `/refs/branches/([^/]+)$`)
	logPath           = regexp.MustCompile(`^` + root + `/pipelines/([0-9]+)/steps/(\{[^/]+\})/log$`)
	milestonesPath    = regexp.MustCompile(`^` + root + `/milestones$`)
	milestonePath     = regexp.MustCompile(`^` + root + `/milestones/([0-9]+)$`)
	commitPath        = regexp.MustCompile(`^` + root + `/commit/([^/]+)$`)
	commitPullsPath   = regexp.MustCompile(`^` + root + `/commit/([^/]+)/pullrequests$`)
	commitsPath       = regexp.MustCompile(`^` + root + `/commits$`)
	permPath          = regexp.MustCompile(`^` + root + `/permissions-config/users/([^/]+)$`)
	memberPath        = regexp.MustCompile(`^/workspaces/acme/members/([^/]+)$`)
	sinceQuery        = regexp.MustCompile(`updated_on>=(\S+)`)
	assigneeQuery     = regexp.MustCompile(`assignee\.uuid="([^"]+)"`)
	kindQuery         = regexp.MustCompile(`kind="([^"]+)"`)
)

func (f *fakeBitbucket) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	user, pass, basic := r.BasicAuth()
	if (f.email == "" && r.Header.Get("Authorization") != "Bearer "+token) || (f.email != "" && (!basic || user != f.email || pass != token)) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if f.status != 0 {
		w.Header().Set("Retry-After", "7")
		w.WriteHeader(f.status)
		_, _ = w.Write([]byte(`{"type":"error","error":{"message":"no"}}`))
		return
	}
	reply := func(v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	page := func(list []obj) {
		if list == nil {
			list = []obj{}
		}
		reply(obj{"values": list, "pagelen": 50})
	}
	notFound := func() {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"type":"error","error":{"message":"not here"}}`))
	}
	n := func(m []string) int { i, _ := strconv.Atoi(m[1]); return i }
	q := r.URL.Query()
	p := r.URL.Path
	if commitsPath.MatchString(p) {
		// Two to a page; the next page's token is not a number.
		list := f.compares[q.Get("include")+".."+q.Get("exclude")]
		if q.Get("page") == "t2" {
			list = list[min(2, len(list)):]
		} else if len(list) > 2 {
			reply(obj{"values": list[:2], "next": f.server.URL + p + "?include=" + q.Get("include") + "&exclude=" + q.Get("exclude") + "&page=t2"})
			return
		}
		page(list)
		return
	}
	if q.Get("page") != "" && q.Get("page") != "1" {
		page(nil)
		return
	}
	if f.noTracker && strings.HasPrefix(p, root+"/issues") {
		notFound()
		return
	}
	if r.Method == http.MethodPut && prCommentPath.MatchString(p) {
		var body obj
		data, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(data, &body)
		m := prCommentPath.FindStringSubmatch(p)
		id, _ := strconv.Atoi(m[2])
		for _, c := range f.prComments[n(m)] {
			if c["id"] == id && c["deleted"] != true {
				c["content"] = body["content"]
				body["_path"] = p
				f.posted = append(f.posted, body)
				reply(c)
				return
			}
		}
		notFound()
		return
	}
	if r.Method == http.MethodPost {
		var body obj
		data, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(data, &body)
		if body == nil {
			body = obj{}
		}
		body["_path"] = p
		f.posted = append(f.posted, body)
		switch {
		case pullsPath.MatchString(p):
			source := body["source"].(obj)["branch"].(obj)["name"].(string)
			target := "main"
			if d, ok := body["destination"].(obj); ok {
				target = d["branch"].(obj)["name"].(string)
			}
			reply(pull(9, source, alex, obj{"title": body["title"], "draft": body["draft"],
				"destination": obj{"branch": obj{"name": target}, "repository": obj{"full_name": repo}}}))
		case prCommentsPath.MatchString(p), issueCommentsPath.MatchString(p):
			reply(obj{"id": 55, "links": obj{"html": obj{"href": "https://bitbucket.org/c/55"}}})
		case mergePath.MatchString(p):
			reply(obj{})
		case pipelinesPath.MatchString(p):
			next := 1
			for n := range f.pipelines {
				next = max(next, n+1)
			}
			run := obj{"uuid": fmt.Sprintf("{p%d}", next), "build_number": next, "target": body["target"], "state": obj{"name": "PENDING"}}
			f.pipelines[next] = run
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(run)
		default:
			notFound()
		}
		return
	}
	switch {
	case p == "/user":
		reply(f.me)
	case p == root:
		reply(obj{"full_name": repo, "has_issues": !f.noTracker, "mainbranch": obj{"name": "main"},
			"links": obj{"html": obj{"href": "https://bitbucket.org/" + repo}}})
	case branchPath.MatchString(p):
		if hash, ok := f.branches[branchPath.FindStringSubmatch(p)[1]]; ok {
			reply(obj{"name": branchPath.FindStringSubmatch(p)[1], "target": obj{"hash": hash}})
			return
		}
		if f.defaultMerge != "" && branchPath.FindStringSubmatch(p)[1] == "main" {
			reply(obj{"name": "main", "merge_strategies": []string{"merge_commit", "squash"}, "default_merge_strategy": f.defaultMerge})
			return
		}
		notFound()
	case pullsPath.MatchString(p):
		out := []obj{}
		for _, pr := range f.pulls {
			for _, st := range q["state"] {
				if pr["state"] == st {
					out = append(out, pr)
				}
			}
		}
		sort.SliceStable(out, func(i, j int) bool { return out[i]["updated_on"].(string) > out[j]["updated_on"].(string) })
		page(out)
	case pullPath.MatchString(p):
		for _, pr := range f.pulls {
			if pr["id"] == n(pullPath.FindStringSubmatch(p)) {
				reply(pr)
				return
			}
		}
		notFound()
	case activityPath.MatchString(p):
		page(f.activity[n(activityPath.FindStringSubmatch(p))])
	case diffstatPath.MatchString(p):
		page(f.diffstat[n(diffstatPath.FindStringSubmatch(p))])
	case diffPath.MatchString(p):
		_, _ = io.WriteString(w, f.diffs[n(diffPath.FindStringSubmatch(p))])
	case prCommentsPath.MatchString(p):
		page(newestFirst(f.prComments[n(prCommentsPath.FindStringSubmatch(p))]))
	case prCommentPath.MatchString(p):
		m := prCommentPath.FindStringSubmatch(p)
		id, _ := strconv.Atoi(m[2])
		for _, c := range f.prComments[n(m)] {
			if c["id"] == id {
				reply(c)
				return
			}
		}
		notFound()
	case statusesPath.MatchString(p):
		page(f.statuses[statusesPath.FindStringSubmatch(p)[1]])
	case issuesPath.MatchString(p):
		out := []obj{}
		since, assignee := sinceQuery.FindStringSubmatch(q.Get("q")), assigneeQuery.FindStringSubmatch(q.Get("q"))
		kind := kindQuery.FindStringSubmatch(q.Get("q"))
		for _, i := range f.issues {
			// (kind="x" OR component.name="x"), as list_issues and show_issues ask.
			if kind != nil && i["kind"] != kind[1] && (i["component"] == nil || i["component"].(obj)["name"] != kind[1]) {
				continue
			}
			if since != nil && before(i["updated_on"].(string), since[1]) {
				continue
			}
			if assignee != nil && (i["assignee"] == nil || i["assignee"].(obj)["uuid"] != assignee[1] || closedStates[i["state"].(string)]) {
				continue
			}
			out = append(out, i)
		}
		sort.SliceStable(out, func(i, j int) bool { return out[i]["updated_on"].(string) > out[j]["updated_on"].(string) })
		page(out)
	case issuePath.MatchString(p):
		for _, i := range f.issues {
			if i["id"] == n(issuePath.FindStringSubmatch(p)) {
				reply(i)
				return
			}
		}
		notFound()
	case issueCommentsPath.MatchString(p):
		page(newestFirst(f.issueComments[n(issueCommentsPath.FindStringSubmatch(p))]))
	case changesPath.MatchString(p):
		page(newestFirst(f.changes[n(changesPath.FindStringSubmatch(p))]))
	case pipelinePath.MatchString(p):
		if run, ok := f.pipelines[n(pipelinePath.FindStringSubmatch(p))]; ok {
			reply(run)
			return
		}
		notFound()
	case stepsPath.MatchString(p):
		page(f.steps[n(stepsPath.FindStringSubmatch(p))])
	case logPath.MatchString(p):
		uuid := logPath.FindStringSubmatch(p)[2]
		if _, ok := f.logs[uuid]; !ok {
			notFound()
			return
		}
		// Another host's name, as Bitbucket's file store has: Go keeps the token on a redirect to the same one.
		store := strings.Replace(f.storage.URL, "127.0.0.1", "localhost", 1)
		http.Redirect(w, r, store+"/logs/"+url.PathEscape(uuid), http.StatusTemporaryRedirect)
	case milestonesPath.MatchString(p):
		page(f.milestones)
	case milestonePath.MatchString(p):
		for _, m := range f.milestones {
			if m["id"] == n(milestonePath.FindStringSubmatch(p)) {
				reply(m)
				return
			}
		}
		notFound()
	case commitPullsPath.MatchString(p):
		if list, ok := f.commitPulls[commitPullsPath.FindStringSubmatch(p)[1]]; ok {
			page(list)
			return
		}
		notFound()
	case commitPath.MatchString(p):
		if c, ok := f.commits[commitPath.FindStringSubmatch(p)[1]]; ok {
			reply(c)
			return
		}
		notFound()
	case permPath.MatchString(p):
		if f.adminless {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"type":"error","error":{"message":"You must be an admin"}}`))
			return
		}
		if perm, ok := f.perms[permPath.FindStringSubmatch(p)[1]]; ok {
			reply(obj{"permission": perm})
			return
		}
		notFound()
	case memberPath.MatchString(p):
		if f.members[memberPath.FindStringSubmatch(p)[1]] {
			reply(obj{"type": "workspace_membership"})
			return
		}
		notFound()
	default:
		f.t.Errorf("fake Bitbucket: no %s %s", r.Method, r.URL)
		notFound()
	}
}

// serveLog is the file store a step's log redirects to: it takes a Range of the log's end,
// and never the person's token.
func (f *fakeBitbucket) serveLog(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("Authorization") != "" {
		f.t.Errorf("the file store got the token")
	}
	f.ranges = append(f.ranges, r.Header.Get("Range"))
	log := f.logs[strings.TrimPrefix(r.URL.Path, "/logs/")]
	var want int
	if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=-%d", &want); err != nil {
		_, _ = io.WriteString(w, log)
		return
	}
	if len(log) == 0 {
		w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
		return
	}
	start := max(0, len(log)-want)
	w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(log)-1, len(log)))
	w.WriteHeader(http.StatusPartialContent)
	_, _ = io.WriteString(w, log[start:])
}

// step is a Pipelines step, done with result (SUCCESSFUL, FAILED, ERROR), or still state.
func step(uuid, name, result string) obj {
	state := obj{"name": "COMPLETED", "result": obj{"name": result}}
	if result == "" {
		state = obj{"name": "IN_PROGRESS"}
	}
	return obj{"uuid": uuid, "name": name, "state": state}
}

// newestFirst is list by created_on, newest first, as sort=-created_on asks.
func newestFirst(list []obj) []obj {
	out := append([]obj(nil), list...)
	sort.SliceStable(out, func(i, j int) bool { return out[i]["created_on"].(string) > out[j]["created_on"].(string) })
	return out
}

// poller polls one event as the daemon does, keeping its cursor, on a clock a minute on each poll.
type poller struct {
	t      *testing.T
	events *Events
	name   string
	args   map[string]any
	cursor any
	clock  *time.Time
}

func newPoller(t *testing.T, f *fakeBitbucket, name string, args map[string]any) *poller {
	clock := start
	p := &poller{t: t, name: name, args: args, clock: &clock}
	p.events = &Events{Bitbucket: f.bitbucket(), Now: func() time.Time { return *p.clock }}
	return p
}

func (p *poller) poll() ([]string, map[string]any) {
	p.t.Helper()
	params := map[string]any{"name": p.name, "arguments": p.args}
	if p.cursor != nil {
		params["cursor"] = p.cursor
	}
	raw, _ := json.Marshal(params)
	result, err := p.events.Poll(context.Background(), raw)
	if err != nil {
		p.t.Fatalf("%s: %v", p.name, err)
	}
	p.cursor = result["cursor"]
	*p.clock = p.clock.Add(time.Minute)
	var ids []string
	for _, e := range result["events"].([]any) {
		ids = append(ids, e.(map[string]any)["eventId"].(string))
	}
	return ids, result
}

func data(t *testing.T, result map[string]any, i int) map[string]any {
	t.Helper()
	return result["events"].([]any)[i].(map[string]any)["data"].(map[string]any)
}

func same(t *testing.T, got, want any) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

// try is one poll's error, for arguments it refuses.
func (p *poller) try() (map[string]any, *rpcError) {
	raw, _ := json.Marshal(map[string]any{"name": p.name, "arguments": p.args})
	return p.events.Poll(context.Background(), raw)
}
