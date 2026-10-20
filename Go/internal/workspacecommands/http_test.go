package workspacecommands

// The API presets (#1119) and the request form, against a fake HTTP server that answers as
// DigitalOcean, GitHub and Coder do. No real account is reached: the presets' api (or url)
// points at the fake.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const token = "dop_v1_secret_token_hunter2"

// fakeAPI is one provider's API: the requests it was sent, and a state per workspace that a
// start or stop changes.
type fakeAPI struct {
	mu       sync.Mutex
	said     []string // "METHOD path?query body"
	headers  []http.Header
	states   map[string]string
	answer   func(w http.ResponseWriter, r *http.Request, body string) bool
	listing  func(states map[string]string) any
	header   string // the header that must carry the token
	expected string // its value
}

func newFakeAPI(t *testing.T, f *fakeAPI) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		f.mu.Lock()
		f.said = append(f.said, strings.TrimSpace(r.Method+" "+r.URL.RequestURI()+" "+string(data)))
		f.headers = append(f.headers, r.Header.Clone())
		f.mu.Unlock()
		if r.Header.Get(f.header) != f.expected {
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprint(w, `{"id":"unauthorized","message":"Unable to authenticate you."}`)
			return
		}
		if f.answer != nil && f.answer(w, r, string(data)) {
			return
		}
		if r.Method == http.MethodGet {
			f.mu.Lock()
			listing := f.listing(f.states)
			f.mu.Unlock()
			_ = json.NewEncoder(w).Encode(listing)
			return
		}
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprint(w, `{"message":"Not Found"}`)
	}))
	t.Cleanup(s.Close)
	return s
}

func (f *fakeAPI) set(id, state string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.states[id] = state
}

func (f *fakeAPI) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.said...)
}

// apiProvider is the preset's provider with the token in its environment, its log kept.
func apiProvider(t *testing.T, text, secret, value string) (*Provider, *[]string) {
	t.Helper()
	var logged []string
	var mu sync.Mutex
	p := &Provider{Config: config(t, text), Timing: quick, Run: func(line string, _ time.Duration) Outcome {
		t.Errorf("an API preset ran a command: %s", line)
		return Outcome{Status: 1}
	}, Env: func(name string) (string, bool) {
		if name == secret && value != "" {
			return value, true
		}
		return "", false
	}, Log: func(line string) {
		mu.Lock()
		logged = append(logged, line)
		mu.Unlock()
	}}
	return p, &logged
}

// noToken fails when the token is in any of the texts.
func noToken(t *testing.T, texts ...string) {
	t.Helper()
	for _, text := range texts {
		if strings.Contains(text, token) {
			t.Errorf("the token is in %q", text)
		}
	}
}

// DigitalOcean

func fakeDigitalOcean(t *testing.T) (*fakeAPI, string) {
	f := &fakeAPI{states: map[string]string{"3164494": "off"}, header: "Authorization", expected: "Bearer " + token}
	f.listing = func(states map[string]string) any {
		var droplets []any
		for id, status := range states {
			droplets = append(droplets, map[string]any{"id": json.Number(id), "name": "devbox-" + id, "status": status,
				"networks": map[string]any{"v4": []any{
					map[string]any{"ip_address": "10.0.0.5", "type": "private"},
					map[string]any{"ip_address": "203.0.113.7", "type": "public"}}}})
		}
		return map[string]any{"droplets": droplets, "meta": map[string]any{"total": len(droplets)}}
	}
	f.answer = func(w http.ResponseWriter, r *http.Request, body string) bool {
		if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/actions") {
			id := strings.Split(r.URL.Path, "/")[3]
			var action map[string]any
			_ = json.Unmarshal([]byte(body), &action)
			if action["type"] == "power_on" {
				f.set(id, "active")
			} else {
				f.set(id, "off")
			}
			w.WriteHeader(http.StatusCreated)
			fmt.Fprint(w, `{"action":{"id":1,"status":"in-progress"}}`)
			return true
		}
		if r.Method == http.MethodPost && r.URL.Path == "/v2/droplets" {
			f.set("4000001", "new")
			w.WriteHeader(http.StatusAccepted)
			fmt.Fprint(w, `{"droplet":{"id":4000001}}`)
			return true
		}
		if r.Method == http.MethodDelete {
			f.mu.Lock()
			delete(f.states, strings.Split(r.URL.Path, "/")[3])
			f.mu.Unlock()
			w.WriteHeader(http.StatusNoContent)
			return true
		}
		return false
	}
	s := newFakeAPI(t, f)
	return f, fmt.Sprintf(`{"preset":"digitalocean-api","tag":"agents team","api":%q}`, s.URL)
}

func TestDigitalOceanListsByTagWithTheTokenInAHeaderOnly(t *testing.T) {
	f, text := fakeDigitalOcean(t)
	p, _ := apiProvider(t, text, DigitalOceanSecret, token)
	all, err := p.List()
	if err != nil || len(all) != 1 {
		t.Fatalf("%v %+v", err, all)
	}
	w := all[0]
	if w.ID != "3164494" || w.Name != "devbox-3164494" || w.State != Stopped || *w.SSH() != "root@203.0.113.7" {
		t.Errorf("%+v %s", w, *w.SSH())
	}
	if got := f.requests()[0]; got != "GET /v2/droplets?per_page=200&tag_name=agents+team" {
		t.Errorf("%s", got)
	}
	noToken(t, f.requests()...)
}

func TestDigitalOceanPowersOnAndWaitsForActive(t *testing.T) {
	f, text := fakeDigitalOcean(t)
	p, logged := apiProvider(t, text, DigitalOceanSecret, token)
	w, err := p.Start("3164494")
	if err != nil || w.State != Running {
		t.Fatalf("%v %+v", err, w)
	}
	if !contains(f.requests(), `POST /v2/droplets/3164494/actions {"type":"power_on"}`) {
		t.Errorf("%q", f.requests())
	}
	if w, err := p.Stop("3164494"); err != nil || w.State != Stopped {
		t.Errorf("%v %+v", err, w)
	}
	if !contains(f.requests(), `POST /v2/droplets/3164494/actions {"type":"power_off"}`) {
		t.Errorf("%q", f.requests())
	}
	noToken(t, *logged...)
	if !strings.Contains(strings.Join(*logged, "\n"), "start devbox-3164494: POST "+strings.TrimSuffix(at(j(t, text), "api").(string), "/")+"/v2/droplets/${id}/actions") {
		t.Errorf("%q", *logged)
	}
}

func TestDigitalOceanMakesADropletThatInstallsAsItsOwnUser(t *testing.T) {
	f, text := fakeDigitalOcean(t)
	text = strings.Replace(text, `"tag"`, `"sshKeys":["ab:cd"],"tag"`, 1)
	p, logged := apiProvider(t, text, DigitalOceanSecret, token)
	if !p.Config.Making.FirstBootRuns() {
		t.Error("its user data runs the first boot")
	}
	firstBoot := "curl -fsSL https://cp.example/v1/install.sh | sh -s -- 'HOSTCODE' 'devbox-new'"
	// The fake lists every droplet as devbox-<id>: the one made is named so.
	_, err := p.Create("devbox-4000001", map[string]any{"region": "sfo3"}, firstBoot)
	if err != nil {
		t.Fatal(err)
	}
	var made map[string]any
	for _, r := range f.requests() {
		if strings.HasPrefix(r, "POST /v2/droplets {") {
			_ = json.Unmarshal([]byte(strings.TrimPrefix(r, "POST /v2/droplets ")), &made)
		}
	}
	userData, _ := made["user_data"].(string)
	if made["name"] != "devbox-4000001" || made["region"] != "sfo3" || made["size"] != "s-1vcpu-1gb" ||
		made["image"] != "ubuntu-24-04-x64" || fmt.Sprint(made["tags"]) != "[agents team]" || fmt.Sprint(made["ssh_keys"]) != "[ab:cd]" {
		t.Errorf("%v", made)
	}
	if !strings.Contains(userData, "\n"+firstBoot+"\n") || !strings.Contains(userData, "su - agents") ||
		!strings.Contains(userData, "loginctl enable-linger agents") || strings.Contains(userData, "sudo") {
		t.Errorf("%s", userData)
	}
	// The host code is in the request, never in the log.
	for _, line := range *logged {
		if strings.Contains(line, "HOSTCODE") {
			t.Errorf("%s", line)
		}
	}
	if err := p.Delete("4000001"); err != nil || !contains(f.requests(), "DELETE /v2/droplets/4000001") {
		t.Errorf("%v %q", err, f.requests())
	}
}

func TestDigitalOceanWithoutItsSecretSaysWhichToGive(t *testing.T) {
	f, text := fakeDigitalOcean(t)
	p, _ := apiProvider(t, text, DigitalOceanSecret, "")
	if _, err := p.List(); err == nil || err.Error() != "It needs the DIGITALOCEAN_API_TOKEN secret." {
		t.Errorf("%v", err)
	}
	if len(f.requests()) != 0 {
		t.Errorf("sent %q", f.requests())
	}
}

func TestARefusedTokenIsSaidInTheProvidersWordsWithoutTheToken(t *testing.T) {
	_, text := fakeDigitalOcean(t)
	p, logged := apiProvider(t, text, DigitalOceanSecret, token+"-wrong")
	_, err := p.List()
	if err == nil || !strings.Contains(err.Error(), "answered 401: Unable to authenticate you. Check its secrets, and what the token or key may do.") {
		t.Fatalf("%v", err)
	}
	noToken(t, err.Error())
	noToken(t, *logged...)
}

func TestAProvidersNoIsCutAt1KB(t *testing.T) {
	f := &fakeAPI{header: "Authorization", expected: "Bearer " + token, states: map[string]string{}}
	f.answer = func(w http.ResponseWriter, _ *http.Request, _ string) bool {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_ = json.NewEncoder(w).Encode(map[string]any{"message": "Quota exceeded. " + strings.Repeat("x", 3000)})
		return true
	}
	s := newFakeAPI(t, f)
	p, _ := apiProvider(t, fmt.Sprintf(`{"preset":"digitalocean-api","tag":"a","api":%q}`, s.URL), DigitalOceanSecret, token)
	_, err := p.List()
	if err == nil || !strings.Contains(err.Error(), "answered 422: Quota exceeded.") || len(err.Error()) != 1024 {
		t.Errorf("%d %v", len(err.Error()), err)
	}
}

func TestARedirectIsNotFollowedWithTheToken(t *testing.T) {
	elsewhere := 0
	other := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { elsewhere++ }))
	defer other.Close()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/v2/droplets", http.StatusFound)
	}))
	defer s.Close()
	p, _ := apiProvider(t, fmt.Sprintf(`{"preset":"digitalocean-api","tag":"a","api":%q}`, s.URL), DigitalOceanSecret, token)
	if _, err := p.List(); err == nil || !strings.Contains(err.Error(), "answered 302") {
		t.Errorf("%v", err)
	}
	if elsewhere != 0 {
		t.Error("the redirect was followed")
	}
}

func TestAnUnreachableAPIIsSaidByItsHostOnly(t *testing.T) {
	s := httptest.NewServer(http.NotFoundHandler())
	address := s.URL
	s.Close()
	p, _ := apiProvider(t, fmt.Sprintf(`{"preset":"digitalocean-api","tag":"a","api":%q}`, address), DigitalOceanSecret, token)
	_, err := p.List()
	if err == nil || err.Error() != "It can't be reached: "+strings.TrimPrefix(address, "http://")+"." {
		t.Errorf("%v", err)
	}
}

// GitHub Codespaces

func fakeCodespaces(t *testing.T, repo string) (*fakeAPI, string) {
	f := &fakeAPI{states: map[string]string{"psychic-train-7v9": "Shutdown"}, header: "Authorization", expected: "Bearer " + token}
	f.listing = func(states map[string]string) any {
		var all []any
		for name, state := range states {
			all = append(all, map[string]any{"name": name, "display_name": "psychic train", "state": state,
				"git_status": map[string]any{"ref": "main"}})
		}
		return map[string]any{"total_count": len(all), "codespaces": all}
	}
	f.answer = func(w http.ResponseWriter, r *http.Request, _ string) bool {
		if r.Method != http.MethodPost {
			return false
		}
		parts := strings.Split(r.URL.Path, "/")
		if parts[4] == "start" {
			f.set(parts[3], "Available")
		} else {
			f.set(parts[3], "Shutdown")
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{}`)
		return true
	}
	s := newFakeAPI(t, f)
	return f, fmt.Sprintf(`{"preset":"codespaces-api","api":%q%s}`, s.URL, repo)
}

func TestCodespacesStartAndStopAreRealCallsAndSSHGoesThroughGh(t *testing.T) {
	f, text := fakeCodespaces(t, "")
	p, _ := apiProvider(t, text, GitHubSecret, token)
	all, err := p.List()
	if err != nil || len(all) != 1 || all[0].State != Stopped || *all[0].SSH() != "cs.psychic-train-7v9.main" || !all[0].Commands.Tunnel {
		t.Fatalf("%v %+v", err, all)
	}
	if w, err := p.Start("psychic-train-7v9"); err != nil || w.State != Running {
		t.Errorf("%v %+v", err, w)
	}
	if w, err := p.Stop("psychic-train-7v9"); err != nil || w.State != Stopped {
		t.Errorf("%v %+v", err, w)
	}
	got := f.requests()
	if got[0] != "GET /user/codespaces?per_page=100" || !contains(got, "POST /user/codespaces/psychic-train-7v9/start") ||
		!contains(got, "POST /user/codespaces/psychic-train-7v9/stop") {
		t.Errorf("%q", got)
	}
	if h := f.headers[0]; h.Get("Accept") != "application/vnd.github+json" || h.Get("X-GitHub-Api-Version") != "2022-11-28" {
		t.Errorf("%v", h)
	}
}

func TestCodespacesOfOneRepo(t *testing.T) {
	f, text := fakeCodespaces(t, `,"repo":"alexec/agents","ssh":"my-codespace"`)
	p, _ := apiProvider(t, text, GitHubSecret, token)
	all, err := p.List()
	if err != nil || *all[0].SSH() != "my-codespace" || f.requests()[0] != "GET /repos/alexec/agents/codespaces?per_page=100" {
		t.Errorf("%v %q", err, f.requests())
	}
	refused(t, `{"preset":"codespaces-api","repo":"agents"}`, "the codespaces-api preset's repo is owner/name")
}

// Coder

func TestCoderBuildsATransitionWithItsSessionToken(t *testing.T) {
	f := &fakeAPI{states: map[string]string{"7c1b": "stopped"}, header: "Coder-Session-Token", expected: token}
	f.listing = func(states map[string]string) any {
		var all []any
		for id, state := range states {
			all = append(all, map[string]any{"id": id, "name": "dev", "latest_build": map[string]any{"status": state}})
		}
		return map[string]any{"workspaces": all, "count": len(all)}
	}
	f.answer = func(w http.ResponseWriter, r *http.Request, body string) bool {
		if r.Method != http.MethodPost {
			return false
		}
		id := strings.Split(r.URL.Path, "/")[4]
		if strings.Contains(body, `"start"`) {
			f.set(id, "running")
		} else {
			f.set(id, "stopped")
		}
		w.WriteHeader(http.StatusCreated)
		fmt.Fprint(w, `{"id":"build-1"}`)
		return true
	}
	s := newFakeAPI(t, f)
	p, _ := apiProvider(t, fmt.Sprintf(`{"preset":"coder-api","url":%q}`, s.URL+"/"), CoderSecret, token)
	w, err := p.Start("7c1b")
	if err != nil || w.State != Running || *w.SSH() != "coder.dev" {
		t.Fatalf("%v %+v", err, w)
	}
	got := f.requests()
	if got[0] != "GET /api/v2/workspaces?q=owner%3Ame" || !contains(got, `POST /api/v2/workspaces/7c1b/builds {"transition":"start"}`) {
		t.Errorf("%q", got)
	}
	refused(t, `{"preset":"coder-api"}`, "the coder-api preset needs url, the deployment's address")
}

// The request form, written by hand

func TestARequestFormListsStartsAndStops(t *testing.T) {
	f := &fakeAPI{states: map[string]string{"a b": "down"}, header: "X-Api-Key", expected: token}
	f.listing = func(states map[string]string) any {
		var all []any
		for id, state := range states {
			all = append(all, map[string]any{"key": id, "status": state})
		}
		return map[string]any{"data": map[string]any{"machines": all}}
	}
	f.answer = func(w http.ResponseWriter, r *http.Request, _ string) bool {
		if r.Method != http.MethodPut {
			return false
		}
		f.set("a b", map[bool]string{true: "up", false: "down"}[strings.HasSuffix(r.URL.Path, "/up")])
		return true
	}
	s := newFakeAPI(t, f)
	text := fmt.Sprintf(`{"list":{"url":"%[1]s/machines","headers":{"X-Api-Key":"${MY_KEY}"}},
		"json":{"items":"data.machines","id":"key","state":"status"},
		"states":{"up":"running","down":"stopped"},
		"start":{"method":"put","url":"%[1]s/machines/${id}/up","headers":{"X-Api-Key":"${MY_KEY}"}},
		"stop":{"method":"PUT","url":"%[1]s/machines/${id}/down","headers":{"X-Api-Key":"${MY_KEY}"}}}`, s.URL)
	p, _ := apiProvider(t, text, "MY_KEY", token)
	if w, err := p.Start("a b"); err != nil || w.State != Running {
		t.Fatalf("%v %+v", err, w)
	}
	// A value is one path segment, escaped.
	if !contains(f.requests(), "PUT /machines/a%20b/up") {
		t.Errorf("%q", f.requests())
	}
}

func TestARequestFormIsChecked(t *testing.T) {
	refused(t, `{"list":{"url":"ftp://x/y"},"json":{"id":"id"},"start":"a","stop":"b"}`, "list.url must start with https://")
	refused(t, `{"list":{"method":"GET"},"json":{"id":"id"},"start":"a","stop":"b"}`, "list needs a url")
	refused(t, `{"list":{"url":"https://x"},"columns":["id"],"start":"a","stop":"b"}`, "a list request needs json paths")
	refused(t, `{"list":"x","columns":["id"],"start":{"url":"https://x","headers":{"A":1}},"stop":"b"}`, "start.headers.A must be text")
	refused(t, `{"list":"x","columns":["id"],"start":7,"stop":"b"}`, "start must be a command or a request")
	c := config(t, `{"list":"x","columns":["id"],"start":"a","stop":"b","create":{"method":"POST","url":"https://x/new","body":{"boot":"${firstBoot}"}},"delete":{"method":"DELETE","url":"https://x/${id}"}}`)
	if !c.Making.CanCreate() || !c.Making.CanDelete() || !c.Making.FirstBootRuns() {
		t.Errorf("%+v", c.Making)
	}
}

func TestAPathPicksTheItemWhoseKeyIsAValue(t *testing.T) {
	v := j(t, `{"v4":[{"type":"private","ip":"10.0.0.1"},{"type":"public","ip":"203.0.113.9"}],"n":[{"id":2,"x":"two"}]}`)
	if got, _ := PathText("v4[type=public].ip", v); got != "203.0.113.9" {
		t.Errorf("%s", got)
	}
	if got, _ := PathText("n[id=2].x", v); got != "two" {
		t.Errorf("%s", got)
	}
	if PathValue("v4[type=none].ip", v) != nil || PathValue("v4[1].ip", v) != "203.0.113.9" {
		t.Error("a selector that matches nothing is nothing")
	}
}

func TestAnAPIPresetOffersCreateOnlyWhenItCan(t *testing.T) {
	_, do := fakeDigitalOcean(t)
	if names := toolNames(t, NewServer(config(t, do), quick, nil, "test")); !contains(names, "workspace_create") || !contains(names, "workspace_delete") {
		t.Errorf("%v", names)
	}
	_, cs := fakeCodespaces(t, "")
	if names := toolNames(t, NewServer(config(t, cs), quick, nil, "test")); contains(names, "workspace_create") {
		t.Errorf("%v", names)
	}
}
