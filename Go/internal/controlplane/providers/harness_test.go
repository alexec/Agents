package providers

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// fakeRouter is the service's router as the tests need it: hosts online or not, each
// linked host's workspace, what was broadcast, and a host's end that answers delivered
// requests.
type fakeRouter struct {
	mu         sync.Mutex
	online     map[string]bool
	workspaces map[string]*MachineWorkspace
	broadcasts []string
	told       []any
	sessions   map[string]bool
	// answer is the host's end: nil for a host that is not there.
	answer    func(host, method string, params json.RawMessage) *Reply
	delivered []delivered
	// stopped: the hosts the Stopped hook closed (#1701).
	stopped []string
}

type delivered struct {
	host, method, client, kind string
	params                     json.RawMessage
}

func newFakeRouter() *fakeRouter {
	return &fakeRouter{online: map[string]bool{}, workspaces: map[string]*MachineWorkspace{}, sessions: map[string]bool{}}
}

func (r *fakeRouter) setOnline(host string, on bool) {
	r.mu.Lock()
	r.online[host] = on
	r.mu.Unlock()
}

func (r *fakeRouter) Online(host string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.online[host]
}

func (r *fakeRouter) HostState(host string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	state := "offline"
	if r.online[host] {
		state = "online"
	}
	shown, _ := Overlay(map[string]any{"state": state}, r.online[host], r.workspaces[host])["state"].(string)
	return shown
}

func (r *fakeRouter) SetWorkspace(host string, ws *MachineWorkspace) {
	r.mu.Lock()
	r.workspaces[host] = ws
	r.mu.Unlock()
}

func (r *fakeRouter) workspace(host string) *MachineWorkspace {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.workspaces[host]
}

func (r *fakeRouter) BroadcastControl(method string, params any) {
	r.mu.Lock()
	r.broadcasts = append(r.broadcasts, method+" "+string(rawOf(params)))
	r.mu.Unlock()
}

func (r *fakeRouter) heard(text string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, b := range r.broadcasts {
		if strings.Contains(b, text) {
			return true
		}
	}
	return false
}

func (r *fakeRouter) DeliverKept(method string, params json.RawMessage, client, kind, host string, patience time.Duration) *Reply {
	r.mu.Lock()
	answer := r.answer
	r.delivered = append(r.delivered, delivered{host, method, client, kind, params})
	r.mu.Unlock()
	if answer == nil {
		return nil
	}
	return answer(host, method, params)
}

func (r *fakeRouter) deliveries() []delivered {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]delivered{}, r.delivered...)
}

func (r *fakeRouter) TellControl(session, method string, params any) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.told = append(r.told, params)
	return r.sessions[session]
}

func (r *fakeRouter) HasSession(session string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.sessions[session]
}

func (r *fakeRouter) Holds(host string) bool { return r.Online(host) }

// row is a hosts/list row, as far as the tests read it.
type row struct {
	ID        string
	State     string
	Workspace *MachineWorkspace
}

type fakeMethods struct {
	router  *fakeRouter
	records *records.Records
}

func (m *fakeMethods) HostRow(h records.MachineRecord) any {
	return row{ID: h.ID, State: m.router.HostState(h.ID), Workspace: m.router.workspace(h.ID)}
}

func (m *fakeMethods) RemoveHost(host string, from Caller) error {
	ok, err := m.records.RemoveHost(context.Background(), host)
	if err == nil && !ok {
		return fail(CodeNoSuchHost, "No machine is called %s.", host)
	}
	return err
}

// standIn is StandInProvider: a provider whose workspaces are what the test says, and which
// counts every call.
type standIn struct {
	mu            sync.Mutex
	workspaces    []MachineInfo
	refuse        string
	failStart     string
	startTakes    time.Duration
	starts, stops int
	firstBootRuns bool
	firstBoots    []string
	deleted       []string
	// fromRepository: its form asks for `repository`, as Codespaces' does (#1809).
	fromRepository bool
	madeWith       []any
}

func newStandIn(ws []MachineInfo) *standIn { return &standIn{workspaces: ws, firstBootRuns: true} }

func (s *standIn) set(refuse, failStart string, startTakes time.Duration) {
	s.mu.Lock()
	s.refuse, s.failStart, s.startTakes = refuse, failStart, startTakes
	s.mu.Unlock()
}

func (s *standIn) Check() (Checked, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.refuse != "" {
		return Checked{}, &ProviderFailure{s.refuse}
	}
	return Checked{Contract: 1, Capabilities: []string{"create", "delete", "options"}, Workspaces: append([]MachineInfo{}, s.workspaces...), Items: -1}, nil
}

func (s *standIn) List() ([]MachineInfo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]MachineInfo{}, s.workspaces...), nil
}

func (s *standIn) setState(id, state string) {
	for i := range s.workspaces {
		if s.workspaces[i].ID == id {
			s.workspaces[i].State = state
		}
	}
}

func (s *standIn) setStateLocked(id, state string) {
	s.mu.Lock()
	s.setState(id, state)
	s.mu.Unlock()
}

func (s *standIn) find(id string) *MachineInfo {
	for _, w := range s.workspaces {
		if w.ID == id {
			return &w
		}
	}
	return nil
}

func (s *standIn) Start(id string) (*MachineInfo, error) {
	s.mu.Lock()
	s.starts++
	takes, failStart := s.startTakes, s.failStart
	s.mu.Unlock()
	time.Sleep(takes)
	if failStart != "" {
		return nil, &ProviderFailure{failStart}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.setState(id, "running")
	return s.find(id), nil
}

func (s *standIn) Stop(id string) (*MachineInfo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stops++
	s.setState(id, "stopped")
	return s.find(id), nil
}

func (s *standIn) Options() (any, error) {
	s.mu.Lock()
	fromRepository := s.fromRepository
	s.mu.Unlock()
	if fromRepository {
		return mustParse(`{"type": "object", "properties": {"repository": {"type": "string", "title": "Repository"}}}`), nil
	}
	return mustParse(`{"type": "object", "properties": {"size": {"type": "string", "title": "Size", "enum": ["small", "big"],
		"x-costs": {"small": "$0.01/hour", "big": "$0.05/hour"}}}}`), nil
}

func (s *standIn) Create(name string, options any, firstBoot *string) (*MachineInfo, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if firstBoot != nil {
		s.firstBoots = append(s.firstBoots, *firstBoot)
	}
	s.madeWith = append(s.madeWith, options)
	made := MachineInfo{ID: "ws-" + name, Name: name, State: "starting", SSH: new("root@10.0.0.9")}
	s.workspaces = append(s.workspaces, made)
	return &made, s.firstBootRuns, nil
}

func (s *standIn) Delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.deleted = append(s.deleted, id)
	var kept []MachineInfo
	for _, w := range s.workspaces {
		if w.ID != id {
			kept = append(kept, w)
		}
	}
	s.workspaces = kept
	return nil
}

func (s *standIn) Tools() ([]any, error) { return nil, providerFailure("It can’t list its tools.") }
func (s *standIn) End()                  {}

func (s *standIn) count() (int, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.starts, s.stops
}

// sshStarts records where agentsd was started over ssh.
type sshStarts struct {
	mu           sync.Mutex
	destinations []string
}

func (s *sshStarts) add(d string) {
	s.mu.Lock()
	s.destinations = append(s.destinations, d)
	s.mu.Unlock()
}

func (s *sshStarts) all() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string{}, s.destinations...)
}

// harness is ProviderHarness.
type harness struct {
	t         *testing.T
	store     *store.Memory
	records   *records.Records
	router    *fakeRouter
	methods   *fakeMethods
	providers *Providers
	provider  *standIn
	home      string
	ssh       *sshStarts
	caller    Caller
}

const devbox, other = "devbox01", "other001"

type harnessOptions struct {
	timing        Timing
	workspaces    []MachineInfo
	sshFails      string
	installedOver string
	backUp        func(host string, caller Caller) (bool, error)
}

func quickTiming() Timing {
	return Timing{ListEvery: time.Hour, SSHAfter: time.Hour, GiveUp: time.Hour, LookEvery: 20 * time.Millisecond,
		Calls: StandardCalls, IdleMinute: time.Minute, WakeLookEvery: time.Hour}
}

func newHarness(t *testing.T, opts ...func(*harnessOptions)) *harness {
	o := harnessOptions{timing: quickTiming(), workspaces: []MachineInfo{
		{ID: "agents-devbox", Name: "agents-devbox", State: "stopped", SSH: new("alex@127.0.0.1 -p 2222")},
		{ID: "scratch-1", Name: "scratch-1", State: "running"},
	}}
	for _, f := range opts {
		f(&o)
	}
	h := &harness{t: t, store: store.NewMemory(), router: newFakeRouter(), provider: newStandIn(o.workspaces),
		home: t.TempDir(), ssh: &sshStarts{}, caller: Caller{Session: records.NewUUID(), Client: records.NewUUID(), Kind: "mac"}}
	h.records = records.New(h.store)
	h.methods = &fakeMethods{router: h.router, records: h.records}
	provider, ssh := h.provider, h.ssh
	h.providers = NewProviders(Config{Store: h.store, Records: h.records, Router: h.router, Methods: h.methods,
		Secrets: NewSecrets(h.home), Timing: o.timing, Hooks: Hooks{
			SSHStart: func(_ records.MachineRecord, destination string, renewKey bool) error {
				if renewKey {
					destination += " (new key taken)"
				}
				ssh.add(destination)
				if o.sshFails != "" {
					return &ProviderFailure{o.sshFails}
				}
				return nil
			},
			InstalledOver: func(string) string { return o.installedOver },
			Stopped: func(host string) {
				h.router.mu.Lock()
				h.router.stopped = append(h.router.stopped, host)
				h.router.mu.Unlock()
				h.router.setOnline(host, false)
			},
			HostCommand: func(string) (string, error) {
				return "curl -fsSL https://cp.local/v1/install.sh | sh -s -- 'agents-control:2:h:secret'", nil
			},
			Connect: func(ProviderRecord, map[string]string) (Provider, error) { return provider, nil },
			BackUp:  o.backUp,
		}})
	t.Cleanup(h.providers.Stop)
	for _, host := range [][2]string{{devbox, "devbox"}, {other, "other"}} {
		h.enroll(host[0], host[1])
	}
	return h
}

func (h *harness) enroll(id, name string) {
	h.t.Helper()
	if err := h.records.SaveHost(context.Background(), records.MachineRecord{ID: id, Name: name, Platform: "linux", Version: "1"}); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) call(method string, params any) (any, error) {
	return h.providers.Answer(method, rawOf(params), h.caller)
}

func (h *harness) must(method string, params any) any {
	h.t.Helper()
	out, err := h.call(method, params)
	if err != nil {
		h.t.Fatalf("%s: %v", method, err)
	}
	return out
}

// add adds the stand-in as DigitalOcean, with a secret.
func (h *harness) add() string {
	h.t.Helper()
	out := h.must(MethodProvidersAdd, map[string]any{"name": "DigitalOcean", "kind": "commands",
		"commands": map[string]any{"preset": "doctl", "tag": "agents"}, "secrets": map[string]string{"DIGITALOCEAN_TOKEN": "hunter2"}})
	return string(out.(ProviderSummary).ID)
}

func (h *harness) link(provider, host, workspace string) {
	h.t.Helper()
	h.must(MethodHostsLink, MachineLink{Host: wire.MachineRef(host), Provider: wire.ProviderID(provider), Workspace: workspace})
}

func (h *harness) row(host string) row {
	record := h.records.Host(host)
	if record == nil {
		return row{}
	}
	return h.methods.HostRow(*record).(row)
}

// waitFor waits for the row to say state, and what else is asked, for up to seconds.
func (h *harness) waitFor(state, host string, seconds int, extra func(row) bool) row {
	deadline := time.Now().Add(time.Duration(seconds) * time.Second)
	for time.Now().Before(deadline) {
		r := h.row(host)
		if r.State == state && (extra == nil || extra(r)) {
			return r
		}
		time.Sleep(10 * time.Millisecond)
	}
	return h.row(host)
}

func failureOf(err error) *Failure {
	var f *Failure
	if errors.As(err, &f) {
		return f
	}
	return nil
}

func eventually(t *testing.T, what func() bool) bool {
	t.Helper()
	for range 300 {
		if what() {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return what()
}

func TestMain(m *testing.M) {
	if mode, ok := os.LookupEnv("FAKE_PROVIDER"); ok {
		fakeProvider(mode)
		return
	}
	os.Exit(m.Run())
}
