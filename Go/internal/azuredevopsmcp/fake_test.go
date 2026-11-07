package azuredevopsmcp

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"regexp"
	"strconv"
	"sync"
	"testing"
	"time"
)

// A fake Azure DevOps over HTTP (no account, #2829): the REST API paths the server reads and
// writes, for the repository acme/Web App/app (a project's name may have a space), with what
// a test puts in it.

type obj = map[string]any

const (
	repo  = "acme/Web App/app"
	token = "azure-devops-test"
	// web is the repository's page as the server writes it.
	web = "/acme/Web%20App/_git/app"
)

type fakeAzureDevOps struct {
	t          *testing.T
	mu         sync.Mutex
	pulls      []obj
	threads    map[int][]obj // pull request → its threads
	statuses   map[int][]obj // pull request → its statuses
	iterations map[int][]obj // pull request → its pushes; none for one of one push
	builds     []obj
	timeline   map[int][]obj // build → its records
	logs       map[int]string
	me         string
	posted     []obj // what was POSTed, PATCHed or PUT, with its method and path
	status     int   // answer every request with this, when set
	// signIn answers as Azure DevOps does a token it does not take: 203 and a sign-in page.
	signIn bool
	server *httptest.Server
}

func newFake(t *testing.T) *fakeAzureDevOps {
	f := &fakeAzureDevOps{t: t, threads: map[int][]obj{}, statuses: map[int][]obj{}, iterations: map[int][]obj{}, timeline: map[int][]obj{}, logs: map[int]string{},
		me: alex["id"].(string)}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

// azureDevOps is a RealAzureDevOps of the fake that shares nothing between polls.
func (f *fakeAzureDevOps) azureDevOps() *RealAzureDevOps {
	ado := NewRealAzureDevOps(f.server.URL, func() string { return token }, func(context.Context) (string, error) { return repo, nil })
	ado.sharing = 0
	return ado
}

func (f *fakeAzureDevOps) set(change func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change()
}

var (
	alex     = obj{"id": "a1", "displayName": "Alex", "uniqueName": "alex@acme.test", "descriptor": "aad.YWxleA"}
	dev      = obj{"id": "d2", "displayName": "Dev", "uniqueName": "dev@acme.test", "descriptor": "aad.ZGV2"}
	builder  = obj{"id": "b3", "displayName": "Project Collection Build Service (acme)", "uniqueName": `Build\acme`, "descriptor": "svc.YnVpbGQ"}
	renovate = obj{"id": "r4", "displayName": "renovate-bot", "uniqueName": "renovate@acme.test", "descriptor": "aad.cmVu"}
)

var start = time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)

// at is start and n minutes, as Azure DevOps writes a time: seven places of a second.
func at(n int) string {
	return start.Add(time.Duration(n) * time.Minute).Format("2006-01-02T15:04:05.0000000Z")
}

func pull(number int, branch string, author obj, extra obj) obj {
	p := obj{"pullRequestId": number, "title": "PR " + strconv.Itoa(number), "description": "", "status": "active", "createdBy": author,
		"creationDate": at(0), "sourceRefName": "refs/heads/" + branch, "targetRefName": "refs/heads/main", "mergeStatus": "succeeded",
		"isDraft": false, "lastMergeSourceCommit": obj{"commitId": "sha" + strconv.Itoa(number)}, "reviewers": []any{}}
	for k, v := range extra {
		p[k] = v
	}
	return p
}

func build(id, pr int, sha, name, result string, finished int) obj {
	return obj{"id": id, "buildNumber": "2026.11." + strconv.Itoa(id), "status": "completed", "result": result, "finishTime": at(finished),
		"sourceBranch": "refs/pull/" + strconv.Itoa(pr) + "/merge", "sourceVersion": "merge" + strconv.Itoa(id),
		"triggerInfo": obj{"pr.number": strconv.Itoa(pr), "pr.sourceSha": sha}, "definition": obj{"id": len(name), "name": name},
		"_links": obj{"web": obj{"href": "https://ado.test/acme/Web%20App/_build/results?buildId=" + strconv.Itoa(id)}}}
}

// branchBuild is a build that a push to branch started (a CI trigger), of no pull request.
func branchBuild(id int, branch, sha, name, result string, finished int) obj {
	b := build(id, 0, sha, name, result, finished)
	b["sourceBranch"], b["sourceVersion"], b["triggerInfo"] = "refs/heads/"+branch, sha, obj{}
	return b
}

// prStatus is a status another service set on a pull request, of iteration (0 for none).
func prStatus(id int, genre, name, state string, set, iteration int) obj {
	s := obj{"id": id, "state": state, "description": name, "targetUrl": "https://scan.test/" + strconv.Itoa(id),
		"creationDate": at(set), "updatedDate": at(set), "context": obj{"genre": genre, "name": name}}
	if iteration != 0 {
		s["iterationId"] = iteration
	}
	return s
}

const gitRoot = "/acme/Web App/_apis/git/repositories/app"

var (
	pullsPath      = regexp.MustCompile(`^` + gitRoot + `/pullrequests$`)
	pullPath       = regexp.MustCompile(`^` + gitRoot + `/pullrequests/([0-9]+)$`)
	reviewerPath   = regexp.MustCompile(`^` + gitRoot + `/pullrequests/([0-9]+)/reviewers/([^/]+)$`)
	threadsPath    = regexp.MustCompile(`^` + gitRoot + `/pullRequests/([0-9]+)/threads$`)
	replyPath      = regexp.MustCompile(`^` + gitRoot + `/pullRequests/([0-9]+)/threads/([0-9]+)/comments$`)
	statusesPath   = regexp.MustCompile(`^` + gitRoot + `/pullRequests/([0-9]+)/statuses$`)
	iterationsPath = regexp.MustCompile(`^` + gitRoot + `/pullRequests/([0-9]+)/iterations$`)
	timelinePath   = regexp.MustCompile(`^/acme/Web App/_apis/build/builds/([0-9]+)/timeline$`)
	logPath        = regexp.MustCompile(`^/acme/Web App/_apis/build/builds/([0-9]+)/logs/([0-9]+)$`)
)

func (f *fakeAzureDevOps) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.signIn {
		w.Header().Set("Content-Type", "text/html")
		w.WriteHeader(http.StatusNonAuthoritativeInfo)
		_, _ = w.Write([]byte("<html>Sign in</html>"))
		return
	}
	if r.Header.Get("Authorization") != "Basic "+base64.StdEncoding.EncodeToString([]byte(":"+token)) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if f.status != 0 {
		w.Header().Set("Retry-After", "7")
		w.WriteHeader(f.status)
		_, _ = w.Write([]byte(`{"message":"no"}`))
		return
	}
	q := r.URL.Query()
	p := r.URL.Path
	if p != "/acme/_apis/connectionData" && q.Get("api-version") != apiVersion {
		f.t.Errorf("fake Azure DevOps: %s %s has no api-version %s", r.Method, r.URL, apiVersion)
	}
	reply := func(v any) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(v)
	}
	list := func(items []obj) {
		if items == nil {
			items = []obj{}
		}
		if q.Get("$skip") != "" && q.Get("$skip") != "0" {
			items = []obj{}
		}
		reply(obj{"count": len(items), "value": items})
	}
	n := func(m []string) int { i, _ := strconv.Atoi(m[1]); return i }
	if r.Method != http.MethodGet {
		var body obj
		data, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(data, &body)
		body["_method"], body["_path"] = r.Method, p
		f.posted = append(f.posted, body)
		switch {
		case pullsPath.MatchString(p):
			reply(pull(9, body["sourceRefName"].(string)[len("refs/heads/"):], alex,
				obj{"title": body["title"], "targetRefName": body["targetRefName"], "isDraft": body["isDraft"]}))
		case threadsPath.MatchString(p):
			reply(obj{"id": 77})
		case replyPath.MatchString(p):
			reply(obj{"id": 2})
		case pullPath.MatchString(p), reviewerPath.MatchString(p):
			reply(obj{})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
		return
	}
	switch {
	case p == "/acme/_apis/connectionData":
		reply(obj{"authenticatedUser": obj{"id": f.me, "providerDisplayName": "Alex"}})
	case p == gitRoot:
		reply(obj{"id": "repo-guid", "name": "app", "defaultBranch": "refs/heads/main"})
	case pullsPath.MatchString(p):
		out := []obj{}
		for _, pr := range f.pulls {
			status := q.Get("searchCriteria.status")
			if status != "all" && pr["status"] != status {
				continue
			}
			if q.Get("searchCriteria.queryTimeRangeType") == "closed" {
				closed, _ := pr["closedDate"].(string)
				if closed == "" || before(closed, q.Get("searchCriteria.minTime")) {
					continue
				}
			}
			if src := q.Get("searchCriteria.sourceRefName"); src != "" && pr["sourceRefName"] != src {
				continue
			}
			out = append(out, pr)
		}
		list(out)
	case pullPath.MatchString(p):
		for _, pr := range f.pulls {
			if pr["pullRequestId"] == n(pullPath.FindStringSubmatch(p)) {
				reply(pr)
				return
			}
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"message":"TF401180: The requested pull request was not found."}`))
	case threadsPath.MatchString(p):
		list(f.threads[n(threadsPath.FindStringSubmatch(p))])
	case statusesPath.MatchString(p):
		list(f.statuses[n(statusesPath.FindStringSubmatch(p))])
	case iterationsPath.MatchString(p):
		list(f.iterations[n(iterationsPath.FindStringSubmatch(p))])
	case p == "/acme/Web App/_apis/build/builds":
		if q.Get("repositoryId") != "repo-guid" {
			f.t.Errorf("builds of %q", q.Get("repositoryId"))
		}
		out := []obj{}
		for i := len(f.builds) - 1; i >= 0; i-- { // newest first
			b := f.builds[i]
			if (q.Get("resultFilter") != "" && b["result"] != q.Get("resultFilter")) ||
				(q.Get("minTime") != "" && before(b["finishTime"].(string), q.Get("minTime"))) ||
				(q.Get("branchName") != "" && b["sourceBranch"] != q.Get("branchName")) {
				continue
			}
			out = append(out, b)
		}
		list(out)
	case timelinePath.MatchString(p):
		reply(obj{"records": f.timeline[n(timelinePath.FindStringSubmatch(p))]})
	case logPath.MatchString(p):
		id, _ := strconv.Atoi(logPath.FindStringSubmatch(p)[2])
		lines := []string{}
		if text, ok := f.logs[id]; ok {
			lines = append(lines, "start", text)
		}
		reply(obj{"count": len(lines), "value": lines})
	default:
		f.t.Errorf("fake Azure DevOps: no %s %s", r.Method, r.URL)
		w.WriteHeader(http.StatusNotFound)
	}
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

func newPoller(t *testing.T, f *fakeAzureDevOps, name string, args map[string]any) *poller {
	clock := start
	p := &poller{t: t, name: name, args: args, clock: &clock}
	p.events = &Events{AzureDevOps: f.azureDevOps(), Now: func() time.Time { return *p.clock }}
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
