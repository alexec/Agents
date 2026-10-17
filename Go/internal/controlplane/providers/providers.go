package providers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// HostRecords is what Providers needs of ControlRecords; records.Records has it.
type HostRecords interface {
	Hosts() []records.HostRecord
	Host(id string) *records.HostRecord
	SaveHost(ctx context.Context, h records.HostRecord) error
}

// Router is what Providers, Kept and Drafts need of ControlRouter. The service's router
// implements it.
type Router interface {
	// Online says whether a host's uplink is up (HostState.isOnline).
	Online(host string) bool
	// HostState is the state hosts/list shows for a host, its workspace laid over it.
	HostState(host string) string
	// SetWorkspace is ControlRouter.setWorkspace: a linked host's workspace changed, or the
	// link went (nil). Said to every client in control/hostChanged when it differs, and laid
	// over the host's state with Overlay.
	SetWorkspace(host string, ws *HostWorkspace)
	// BroadcastControl tells every client session a control notification.
	BroadcastControl(method string, params any)
	// DeliverKept is ControlRouter.deliverKept: a request sent to a host on a channel of
	// its own, bound to the client that asked, and its reply. Nil when the host is not here,
	// goes before it answers, or takes longer than patience.
	DeliverKept(method string, params json.RawMessage, client, kind, host string, patience time.Duration) *Reply
	// TellControl tells one client session a control notification; false when it has gone.
	TellControl(session, method string, params any) bool
	// HasSession says a client session is still here.
	HasSession(session string) bool
	// Holds says this copy has the host's real uplink.
	Holds(host string) bool
}

// Methods is what Providers needs of ControlMethods.
type Methods interface {
	// HostRow is one hosts/list row, as it stands now (DaemonAPI.ControlHost).
	HostRow(h records.HostRecord) any
	// RemoveHost is hosts/remove, as that client asked it.
	RemoveHost(host string, from Caller) error
}

// Timing is WorkspaceProviders.Timing.
type Timing struct {
	// How often every provider is listed (FR-004).
	ListEvery time.Duration
	// How long a started workspace's agentsd has to connect before it is started over ssh.
	SSHAfter time.Duration
	// How long a start has, in all, before it is given up (US1 AS3).
	GiveUp time.Duration
	// How often a start looks for the host's connection.
	LookEvery time.Duration
	Calls     CallTiming
	// What one minute of a stop when idle lasts: a minute, but shorter in tests.
	IdleMinute time.Duration
	// How often stopped workspaces are looked at for a wake-up call that is due (#1004).
	WakeLookEvery time.Duration
}

// StandardTiming is WorkspaceProviders.Timing.standard.
var StandardTiming = Timing{ListEvery: 300 * time.Second, SSHAfter: 120 * time.Second, GiveUp: 600 * time.Second,
	LookEvery: time.Second, Calls: StandardCalls, IdleMinute: time.Minute, WakeLookEvery: 15 * time.Second}

// Hooks is WorkspaceProviders.Hooks: what the executable does for it, what needs ssh,
// processes or the tunnels.
type Hooks struct {
	// SSHStart starts a host's agentsd over ssh, as an install leaves it, without installing.
	SSHStart func(host records.HostRecord, destination string) error
	// OpenTunnel opens the host's reverse tunnel now, if it has one.
	OpenTunnel func(host string)
	// InstalledOver is the ssh destination the host was installed over, when its tunnel
	// keeps it (#965); "" for none.
	InstalledOver func(host string) string
	// Connect is a connection to a provider, as its record says.
	Connect func(record ProviderRecord, secrets map[string]string) (Provider, error)
	// HostCommand is the one line that installs a host with a new host code, for a new
	// workspace's first boot (US5).
	HostCommand func() (string, error)
}

// Config is what NewProviders is given.
type Config struct {
	Store   store.Store
	Records HostRecords
	Router  Router
	Methods Methods
	Secrets *Secrets
	Timing  Timing
	Hooks   Hooks
	Log     func(string)
}

// listed is WorkspaceProviders.Listed: a provider's last list.
type listed struct {
	workspaces []WorkspaceInfo
	listedAt   *time.Time
	// False once a list has failed after a good one.
	current bool
	problem string
}

type activityKind int

const (
	starting activityKind = iota + 1
	stopping
)

// activity is WorkspaceProviders.Activity: a start or stop under way, for one host.
type activity struct {
	kind  activityKind
	phase string
	since time.Time
}

type heldProvider struct {
	record ProviderRecord
	etag   string
}

// joining is WorkspaceProviders.Joining: a workspace made here that installs on its first
// boot, until it joins and is linked.
type joining struct {
	provider  string
	workspace string
	// What it clones once it has joined (#1122), as the client that made it.
	clones []string
	caller *Caller
}

// ClonePatience is WorkspaceProviders.clonePatience: how long one clone on a new host may
// take before the next is sent.
const ClonePatience = time.Hour

// Providers is WorkspaceProviders (#691, plan.md): the providers' records, their last
// lists, the links from hosts to workspaces, and every start and stop, one at a time per
// workspace. What it learns it lays over each linked host's state in the router
// (SetWorkspace). It runs only on a control plane with one copy (research R4).
type Providers struct {
	store   store.Store
	records HostRecords
	router  Router
	methods Methods
	secrets *Secrets
	timing  Timing
	hooks   Hooks
	log     func(string)

	mu          sync.Mutex
	// Held while changed() reads the records and tells the router, so two at once can
	// never leave the older overlay there (#1296).
	publishing  sync.Mutex
	providers   map[string]heldProvider
	connections map[string]Provider
	listed      map[string]*listed
	activities  map[string]*activity
	// Why each host's last start or stop failed, until the next one.
	problems map[string]string
	kept     *Kept
	drafts   *Drafts
	// What each host last said about whether it is idle (US4).
	statuses map[string]HostStatus
	// Each linked host's stop when idle, counting down while it stays idle.
	idleTimers map[string]*time.Timer
	// Stops under way because a host was idle, by how many minutes.
	idleStopping map[string]int
	// "Stopped by Agents after 30 minutes idle", until it is started again.
	stoppedBy map[string]string
	joining   map[string]*joining
	done      chan struct{}
	stopOnce  sync.Once
}

// NewProviders is WorkspaceProviders.init.
func NewProviders(cfg Config) *Providers {
	if cfg.Log == nil {
		cfg.Log = func(string) {}
	}
	if cfg.Timing.IdleMinute == 0 {
		cfg.Timing.IdleMinute = time.Minute
	}
	if cfg.Timing.WakeLookEvery == 0 {
		cfg.Timing.WakeLookEvery = 15 * time.Second
	}
	if cfg.Timing.Calls == (CallTiming{}) {
		cfg.Timing.Calls = StandardCalls
	}
	h := &cfg.Hooks
	if h.SSHStart == nil {
		h.SSHStart = func(records.HostRecord, string) error {
			return providerFailure("This control plane can’t start agentsd over ssh.")
		}
	}
	if h.OpenTunnel == nil {
		h.OpenTunnel = func(string) {}
	}
	if h.InstalledOver == nil {
		h.InstalledOver = func(string) string { return "" }
	}
	if h.HostCommand == nil {
		h.HostCommand = func() (string, error) { return "", providerFailure("This control plane can’t give out host codes.") }
	}
	return &Providers{store: cfg.Store, records: cfg.Records, router: cfg.Router, methods: cfg.Methods,
		secrets: cfg.Secrets, timing: cfg.Timing, hooks: cfg.Hooks, log: cfg.Log,
		providers: map[string]heldProvider{}, connections: map[string]Provider{}, listed: map[string]*listed{},
		activities: map[string]*activity{}, problems: map[string]string{}, statuses: map[string]HostStatus{},
		idleTimers: map[string]*time.Timer{}, idleStopping: map[string]int{}, stoppedBy: map[string]string{},
		joining: map[string]*joining{}, done: make(chan struct{})}
}

// KeepWith keeps prompts and starts for this control plane's stopped hosts (US3).
func (p *Providers) KeepWith(kept *Kept) {
	p.mu.Lock()
	p.kept = kept
	p.mu.Unlock()
}

// Kept is the kept requests, or nil.
func (p *Providers) Kept() *Kept {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.kept
}

// DraftWith lets an agent write a provider's map or commands at Add Provider (#858).
func (p *Providers) DraftWith(drafts *Drafts) {
	p.mu.Lock()
	p.drafts = drafts
	p.mu.Unlock()
}

// Drafts is Write It for Me's drafts, or nil.
func (p *Providers) Drafts() *Drafts {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.drafts
}

// BusyHost is WorkspaceProviders.busyHost: the host linked to a provider's workspace, by
// name, when agents are working there; "" when none. A writer cannot ask to stop it
// (#858, FR-020).
func (p *Providers) BusyHost(provider, workspace string) string {
	if provider == "" {
		return ""
	}
	for _, h := range p.records.Hosts() {
		link := LinkOf(&h)
		if link == nil || link.Provider != provider || link.Workspace != workspace {
			continue
		}
		p.mu.Lock()
		running := len(p.statuses[h.ID].Running)
		p.mu.Unlock()
		if running > 0 {
			return h.Name
		}
	}
	return ""
}

// Start is WorkspaceProviders.start: reads the providers, lists each, and lists again
// every ListEvery (FR-004).
func (p *Providers) Start() {
	p.load()
	if kept := p.Kept(); kept != nil {
		kept.Load()
	}
	p.Refresh("")
	go p.every(p.timing.ListEvery, func() { p.Refresh("") })
	go p.every(p.timing.WakeLookEvery, func() { p.wakeUps(time.Now()) })
}

func (p *Providers) every(interval time.Duration, do func()) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-p.done:
			return
		case <-t.C:
			do()
		}
	}
}

// sleep waits d, or says false when the providers stopped.
func (p *Providers) sleep(d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-p.done:
		return false
	case <-t.C:
		return true
	}
}

// Stop is WorkspaceProviders.stop: the lists stop, and every connection ends.
func (p *Providers) Stop() {
	p.stopOnce.Do(func() { close(p.done) })
	p.mu.Lock()
	connections := p.connections
	p.connections = map[string]Provider{}
	for _, t := range p.idleTimers {
		t.Stop()
	}
	p.idleTimers = map[string]*time.Timer{}
	p.mu.Unlock()
	for _, c := range connections {
		c.End()
	}
}

func (p *Providers) load() {
	ctx := context.Background()
	keys, err := p.store.List(ctx, ProvidersPrefix)
	if err != nil {
		return
	}
	for _, key := range keys {
		object, err := p.store.Get(ctx, key.Key)
		if err != nil || object == nil {
			continue
		}
		var record ProviderRecord
		if json.Unmarshal(object.Data, &record) != nil || (record.Forgotten != nil && *record.Forgotten) {
			continue
		}
		p.mu.Lock()
		p.providers[record.ID] = heldProvider{record, object.ETag}
		p.mu.Unlock()
	}
}

// MARK: WorkspaceHandling

// Answer is WorkspaceHandling.answer: one of WorkspaceMethods, from a client.
func (p *Providers) Answer(method string, params json.RawMessage, from Caller) (any, error) {
	return p.answer(method, params, from, "client "+shortID(from.Client))
}

// HostSaid answers host/workspaces, host/providerDraft and host/status, which a host says
// on its channel 0, as ControlMethods.hostSaid does for them.
func (p *Providers) HostSaid(host, method string, params json.RawMessage) (any, error) {
	switch method {
	case MethodHostWorkspaces:
		var call HostWorkspaceCall
		if err := requireParams(params, &call, "HostWorkspaceCall", "agent", "method", "params"); err != nil {
			return nil, err
		}
		if !AgentWorkspaceMethods[call.Method] {
			return nil, fail(CodeNotPermitted, "Agents can’t ask that of the control plane.")
		}
		return p.AgentCall(host, call.Agent, call.Method, call.Params)
	case MethodHostProviderDraft:
		var call HostProviderDraftCall
		if err := requireParams(params, &call, "HostProviderDraftCall", "agentID", "draft", "tool"); err != nil {
			return nil, err
		}
		if !isUUID(call.AgentID) || !isUUID(call.Draft) {
			return nil, invalid("Those parameters are not a HostProviderDraftCall.")
		}
		return p.DraftCall(host, call)
	case MethodHostStatus:
		var status HostStatus
		if requireParams(params, &status, "HostStatus", "idle", "running") == nil {
			p.Heard(host, status)
		}
		return map[string]any{}, nil
	}
	return nil, methodNotFound(method)
}

// DraftCall is WorkspaceHandling.draftCall: a writing agent on host called one of the
// writer's tools (#858).
func (p *Providers) DraftCall(host string, call HostProviderDraftCall) (any, error) {
	drafts := p.Drafts()
	if drafts == nil {
		return nil, fail(CodeNotPermitted, "%s", NotYoursWords)
	}
	return drafts.Call(host, call)
}

// AgentCall is WorkspaceHandling.agentCall: an agent on host asked through its workspace
// tools (US6), one of AgentWorkspaceMethods, logged as that agent's.
func (p *Providers) AgentCall(host, agent, method string, params json.RawMessage) (any, error) {
	hostName := host
	if h := p.records.Host(host); h != nil {
		hostName = h.Name
	}
	// No client: the host's own channel.
	caller := Caller{Session: records.NewUUID(), Client: records.NewUUID(), Kind: "unknown"}
	if method == MethodWorkspacesAgent {
		return p.forAgent(), nil
	}
	var given map[string]any
	if decodeJSON(params, &given) != nil || given == nil {
		return nil, invalid("Those parameters aren’t an object.")
	}
	// An agent names hosts and providers as it saw them listed: by name, or by id.
	if named, ok := str(given["host"]); ok && p.records.Host(named) == nil {
		found := ""
		for _, h := range p.records.Hosts() {
			if strings.EqualFold(h.Name, named) {
				found = h.ID
				break
			}
		}
		if found == "" {
			return nil, fail(CodeNoSuchHost, "No host is called %s.", named)
		}
		given["host"] = found
	}
	if named, ok := str(given["id"]); ok && (method == MethodProvidersCreate || method == MethodProvidersOptions) {
		p.mu.Lock()
		_, known := p.providers[named]
		found := ""
		if !known {
			for _, held := range p.providers {
				if strings.EqualFold(held.record.Name, named) {
					found = held.record.ID
					break
				}
			}
		}
		p.mu.Unlock()
		if !known {
			if found == "" {
				return nil, invalid("No provider is called %s.", named)
			}
			given["id"] = found
		}
	}
	return p.answer(method, rawOf(given), caller, "agent "+agent+" on "+hostName)
}

// forAgent is what an agent is shown (US6 AS1): every provider's workspaces and their
// hosts, and what a new one could be, never a secret or its name.
func (p *Providers) forAgent() AgentWorkspaces {
	hosts := p.records.Hosts()
	out := AgentWorkspaces{Providers: []AgentProvider{}}
	for _, summary := range p.Summaries() {
		canMake, canDelete := contains(summary.Capabilities, "create"), contains(summary.Capabilities, "delete")
		var options any
		if canMake {
			options, _ = p.providerCall(summary.ID, func(c Provider) (any, error) { return c.Options() })
		}
		workspaces := []AgentWorkspace{}
		for _, w := range summary.Workspaces {
			aw := AgentWorkspace{ID: w.ID, Name: w.Name, State: w.State, Cost: w.Cost}
			for _, h := range hosts {
				if w.Host != "" && h.ID == w.Host {
					aw.Host = h.Name
					aw.HostState = p.router.HostState(h.ID)
				}
			}
			workspaces = append(workspaces, aw)
		}
		out.Providers = append(out.Providers, AgentProvider{ID: summary.ID, Name: summary.Name, CanMake: canMake,
			CanDelete: canDelete, Options: options, Workspaces: workspaces})
	}
	return out
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func (p *Providers) answer(method string, params json.RawMessage, caller Caller, who string) (any, error) {
	switch method {
	case MethodProvidersList:
		// As last listed: a page that opens asks for providers/refresh too (FR-004).
		return map[string]any{"providers": p.Summaries()}, nil
	case MethodProvidersRefresh:
		var request providerRequest
		decodeJSON(params, &request)
		go p.Refresh(request.ID)
		return map[string]any{}, nil
	case MethodProvidersAdd, MethodProvidersUpdate:
		var request ProviderAdd
		if err := requireParams(params, &request, "ProviderAdd", "name", "kind"); err != nil {
			return nil, err
		}
		if !knownKind(request.Kind) || (request.Draft != "" && !isUUID(request.Draft)) {
			return nil, invalid("Those parameters are not a ProviderAdd.")
		}
		return p.save(request, method == MethodProvidersUpdate)
	case MethodProvidersRemove:
		var request providerRequest
		if err := requireParams(params, &request, "ProviderRequest"); err != nil {
			return nil, err
		}
		if request.ID == "" {
			return nil, invalid("Which provider?")
		}
		return map[string]any{}, p.remove(request.ID)
	case MethodHostsLink:
		var request HostLink
		if err := requireParams(params, &request, "HostLink", "host", "provider", "workspace"); err != nil {
			return nil, err
		}
		return p.link(request)
	case MethodHostsUnlink:
		var request hostRequest
		if err := requireParams(params, &request, "HostRequest", "host"); err != nil {
			return nil, err
		}
		return p.changeLink(request.Host, func(h *records.HostRecord) { setLink(h, nil) }, nil)
	case MethodHostsSetOptions:
		var options HostWorkspaceOptions
		if err := requireParams(params, &options, "HostWorkspaceOptions", "host"); err != nil {
			return nil, err
		}
		return p.changeLink(options.Host, func(h *records.HostRecord) {
			link := LinkOf(h)
			if link == nil {
				return
			}
			if options.StartWhenUsed != nil {
				link.StartWhenUsed = options.StartWhenUsed
			}
			if options.StopWhenIdleMinutes != nil {
				if *options.StopWhenIdleMinutes > 0 {
					link.StopWhenIdleMinutes = options.StopWhenIdleMinutes
				} else {
					link.StopWhenIdleMinutes = nil
				}
			}
			if options.StartForSchedules != nil {
				link.StartForSchedules = options.StartForSchedules
			}
			setLink(h, link)
		}, func() { p.countIdle(options.Host) })
	case MethodHostsStart:
		var request hostRequest
		if err := requireParams(params, &request, "HostRequest", "host"); err != nil {
			return nil, err
		}
		return p.begin(starting, request.Host, who)
	case MethodHostsStop:
		var request HostStop
		if err := requireParams(params, &request, "HostStop", "host"); err != nil {
			return nil, err
		}
		// Asked first while agents are working there (US4 AS4).
		p.mu.Lock()
		running := p.statuses[request.Host].Running
		p.mu.Unlock()
		if (request.ConfirmRunning == nil || !*request.ConfirmRunning) && len(running) > 0 && p.router.Online(request.Host) {
			name := request.Host
			if h := p.records.Host(request.Host); h != nil {
				name = h.Name
			}
			verb := "are"
			if len(running) == 1 {
				verb = "is"
			}
			f := fail(CodeAgentsWorking, "Stop %s? %s %s working there.", name, andList(running), verb)
			f.Data = rawOf(map[string]any{"running": running})
			return nil, f
		}
		return p.begin(stopping, request.Host, who)
	case MethodProvidersOptions:
		var request providerRequest
		if err := requireParams(params, &request, "ProviderRequest"); err != nil {
			return nil, err
		}
		if request.ID == "" {
			return nil, invalid("Which provider?")
		}
		schema, err := p.providerCall(request.ID, func(c Provider) (any, error) { return c.Options() })
		if err != nil {
			return nil, err
		}
		return ProviderOptions{Schema: schema}, nil
	case MethodProvidersCreate:
		var request ProviderCreate
		if err := requireParams(params, &request, "ProviderCreate", "id", "name"); err != nil {
			return nil, err
		}
		return p.create(request, who, &caller)
	case MethodHostsDelete:
		var request hostRequest
		if err := requireParams(params, &request, "HostRequest", "host"); err != nil {
			return nil, err
		}
		return map[string]any{}, p.deleteWorkspace(request.Host, who, caller)
	case MethodHostsKeep:
		var request KeepRequest
		if err := requireParams(params, &request, "KeepRequest", "host", "method", "params"); err != nil {
			return nil, err
		}
		kept := p.Kept()
		var answer *Failure
		if kept != nil {
			answer = kept.Keep(request.Host, request.Method, request.Params, caller)
		}
		if answer == nil {
			name := "That host"
			if h := p.records.Host(request.Host); h != nil {
				name = h.Name
			}
			return nil, fail(CodeHostOffline, "%s is offline.", name)
		}
		return nil, answer
	case MethodProvidersRuntimes:
		drafts := p.Drafts()
		if drafts == nil {
			return ProviderRuntimes{Runtimes: []ProviderRuntime{}, Why: "This control plane can’t start a writing agent."}, nil
		}
		return drafts.Runtimes(), nil
	case MethodDraftStart:
		drafts := p.Drafts()
		if drafts == nil {
			return nil, fail(CodeNotSupported, "This control plane can’t start a writing agent.")
		}
		var request ProviderDraftStart
		if err := requireParams(params, &request, "ProviderDraftStart", "form", "runtimeID"); err != nil {
			return nil, err
		}
		if request.Form.Name == "" && !strings.Contains(string(params), `"name"`) || !knownKind(request.Form.Kind) {
			return nil, invalid("Those parameters are not a ProviderDraftStart.")
		}
		var existing *ExistingProvider
		if request.Provider != "" {
			p.mu.Lock()
			held, ok := p.providers[request.Provider]
			problem := ""
			if l := p.listed[request.Provider]; l != nil {
				problem = l.problem
			}
			p.mu.Unlock()
			if !ok {
				return nil, invalid("There is no such provider.")
			}
			existing = &ExistingProvider{Record: held.record, Secrets: p.secrets.Values(request.Provider), Problem: problem}
			// Written again from the provider as it is kept: the sheet knows only its name.
			cli := ""
			if request.Form.CLI != nil {
				cli = trimSpaces(*request.Form.CLI)
			}
			if cli == "" {
				cli = cliOf(held.record)
			}
			r := held.record
			request.Form = ProviderAdd{ID: request.Provider, Name: r.Name, Kind: r.Kind, Command: r.Command, Args: r.Args,
				URL: r.URL, Headers: r.Headers, CLI: &cli}
		}
		return drafts.Start(request, caller, existing)
	case MethodDraftCancel:
		var request ProviderDraftRequest
		if err := requireParams(params, &request, "ProviderDraftRequest", "draft"); err != nil {
			return nil, err
		}
		if drafts := p.Drafts(); drafts != nil {
			drafts.Cancel(request.Draft, caller)
		}
		return map[string]any{}, nil
	case MethodDraftAnswer:
		drafts := p.Drafts()
		if drafts == nil {
			return nil, invalid("That draft has ended.")
		}
		var answer ProviderDraftAnswer
		if err := requireParams(params, &answer, "ProviderDraftAnswer", "draft", "question", "yes"); err != nil {
			return nil, err
		}
		return map[string]any{}, drafts.Answer(answer, caller)
	case MethodHostsListKept, MethodHostsDropKept, MethodHostsRetryKept:
		kept := p.Kept()
		if kept == nil {
			return map[string]any{"kept": []any{}}, nil
		}
		return kept.Answer(method, params)
	}
	return nil, methodNotFound(method)
}

// MARK: Providers

// Summaries is WorkspaceProviders.summaries: every provider for the Providers page, by name.
func (p *Providers) Summaries() []ProviderSummary {
	linked := map[string]string{}
	for _, h := range p.records.Hosts() {
		if link := LinkOf(&h); link != nil {
			linked[link.Provider+"/"+link.Workspace] = h.ID
		}
	}
	p.mu.Lock()
	held := make([]heldProvider, 0, len(p.providers))
	for _, h := range p.providers {
		held = append(held, h)
	}
	lists := map[string]listed{}
	for id, l := range p.listed {
		lists[id] = *l
	}
	p.mu.Unlock()
	sort.Slice(held, func(i, j int) bool { return held[i].record.Name < held[j].record.Name })
	out := []ProviderSummary{}
	for _, h := range held {
		r := h.record
		had := p.secrets.Values(r.ID)
		secrets := map[string]bool{}
		for _, name := range r.SecretNames {
			if _, seen := secrets[name]; !seen {
				_, has := had[name]
				secrets[name] = has
			}
		}
		l, ok := lists[r.ID]
		if !ok {
			l = listed{current: true}
		}
		workspaces := []WorkspaceInfo{}
		for _, w := range l.workspaces {
			w.Host = linked[r.ID+"/"+w.ID]
			workspaces = append(workspaces, w)
		}
		caps := r.Capabilities
		if caps == nil {
			caps = []string{}
		}
		s := ProviderSummary{ID: r.ID, Name: r.Name, Kind: r.Kind, Secrets: secrets, Capabilities: caps,
			Contract: r.Contract, Mapped: r.Map != nil, Preset: r.preset(), Workspaces: workspaces, Current: l.current,
			Problem: l.problem}
		if l.listedAt != nil {
			s.ListedAt = refDate(*l.listedAt)
		}
		out = append(out, s)
	}
	return out
}

// save adds or changes a provider: connected, checked and listed before it is kept
// (US2 AS1–2).
func (p *Providers) save(request ProviderAdd, updating bool) (ProviderSummary, error) {
	var id, etag string
	var heldBefore *ProviderRecord
	p.mu.Lock()
	if updating {
		held, ok := p.providers[request.ID]
		if request.ID == "" || !ok {
			p.mu.Unlock()
			return ProviderSummary{}, invalid("There is no such provider.")
		}
		id, etag = request.ID, held.etag
		r := held.record
		heldBefore = &r
	} else {
		id = MakeProviderID(request.Name)
	}
	for _, h := range p.providers {
		if h.record.ID != id && h.record.Name == trimSpaces(request.Name) {
			p.mu.Unlock()
			return ProviderSummary{}, invalid("There is already a provider called %s.", request.Name)
		}
	}
	p.mu.Unlock()
	before := map[string]string{}
	if updating {
		before = p.secrets.Values(id)
	}
	// An update keeps what it leaves out, as it keeps the secrets (#858 US4).
	if heldBefore != nil && request.Kind == heldBefore.Kind {
		if request.Command == nil {
			request.Command = heldBefore.Command
		}
		if request.Args == nil {
			request.Args = heldBefore.Args
		}
		if request.URL == nil {
			request.URL = heldBefore.URL
		}
		if request.Headers == nil {
			request.Headers = heldBefore.Headers
		}
		if request.Kind == KindCommands {
			if request.Commands == nil {
				request.Commands = heldBefore.Commands
			}
		} else if request.Map == nil {
			request.Map = heldBefore.Map
		}
	}
	values := before
	for k, v := range request.Secrets {
		if v != "" {
			values[k] = v
		}
	}
	names := make([]string, 0, len(values))
	for k := range values {
		names = append(names, k)
	}
	sort.Strings(names)
	record := ProviderRecord{ID: id, Name: trimSpaces(request.Name), Kind: request.Kind, Command: request.Command,
		Args: request.Args, URL: request.URL, Headers: request.Headers, SecretNames: names, Contract: 1}
	record.Commands, record.Map = request.Commands, request.Map
	if problem := record.Problem(); problem != "" {
		return ProviderSummary{}, invalid("%s", problem)
	}
	connection, err := p.hooks.Connect(record, values)
	var checked Checked
	if err == nil {
		checked, err = connection.Check()
		if err != nil {
			connection.End()
		}
	}
	if err != nil {
		return ProviderSummary{}, invalid("%s", errorWords(err))
	}
	record.Capabilities = checked.Capabilities
	if record.Capabilities == nil {
		record.Capabilities = []string{}
	}
	record.Contract = checked.Contract
	if record.Contract == 0 {
		record.Contract = 1
	}
	record.WrittenBy = p.writtenBy(request, heldBefore)
	record.Rev = 1
	if heldBefore != nil {
		record.Rev = heldBefore.Rev + 1
	}
	data, err := records.Encode(record)
	if err != nil {
		connection.End()
		return ProviderSummary{}, err
	}
	condition := store.Absent
	if etag != "" {
		condition = store.Matching(etag)
	}
	newTag, err := p.store.Put(context.Background(), ProviderKey(id), data, condition)
	if err == nil {
		err = p.secrets.Set(id, values)
	}
	if err != nil {
		connection.End()
		return ProviderSummary{}, err
	}
	now := time.Now()
	p.mu.Lock()
	p.providers[id] = heldProvider{record, newTag}
	old := p.connections[id]
	p.connections[id] = connection
	p.listed[id] = &listed{workspaces: checked.Workspaces, listedAt: &now, current: true}
	p.mu.Unlock()
	if old != nil {
		old.End()
	}
	verb := "added"
	if updating {
		verb = "changed"
	}
	extra := ""
	if preset := record.preset(); preset != "" {
		extra += ", preset " + preset
	}
	if record.Map != nil {
		extra += ", mapped"
	}
	p.log(fmt.Sprintf("provider: %s %s (%s%s), %d workspaces", verb, id, record.Kind, extra, len(checked.Workspaces)))
	p.changed()
	for _, s := range p.Summaries() {
		if s.ID == id {
			return s, nil
		}
	}
	return ProviderSummary{}, invalid("There is no such provider.")
}

// writtenBy is WorkspaceProviders.writtenBy (#858): an agent, when the request accepts a
// done draft and its map or commands are the draft's; otherwise it stays as it was when
// they are unchanged, and goes when the person changed them.
func (p *Providers) writtenBy(request ProviderAdd, before *ProviderRecord) *WrittenBy {
	given := request.Map
	if request.Kind == KindCommands {
		given = request.Commands
	}
	if drafts := p.Drafts(); request.Draft != "" && drafts != nil {
		if runtime, json, ok := drafts.Result(request.Draft); ok && jsonEqual(json, given) {
			return &WrittenBy{RuntimeID: runtime, At: records.Now()}
		}
	}
	if before == nil {
		return nil
	}
	had := before.Map
	if before.Kind == KindCommands {
		had = before.Commands
	}
	if (had == nil && given == nil) || (had != nil && given != nil && jsonEqual(had, given)) {
		return before.WrittenBy
	}
	return nil
}

// cliOf is WorkspaceProviders.cli(of:): the program a command provider's commands use, the
// first word of its list, or of its first workspace's start (#858 US4).
func cliOf(record ProviderRecord) string {
	line, ok := str(get(record.Commands, "list"))
	if !ok {
		if ws, _ := arr(get(record.Commands, "workspaces")); len(ws) > 0 {
			line = strOr(get(ws[0], "start"))
		}
	}
	for _, word := range strings.Split(line, " ") {
		if word != "" {
			return word
		}
	}
	return ""
}

// remove is a provider going; its hosts stay, unlinked (US2 AS5).
func (p *Providers) remove(id string) error {
	p.mu.Lock()
	held, ok := p.providers[id]
	p.mu.Unlock()
	if !ok {
		return invalid("There is no such provider.")
	}
	yes := true
	held.record.Forgotten = &yes
	held.record.Rev++
	data, err := records.Encode(held.record)
	if err != nil {
		return err
	}
	if _, err := p.store.Put(context.Background(), ProviderKey(id), data, store.Matching(held.etag)); err != nil {
		return err
	}
	p.mu.Lock()
	delete(p.providers, id)
	delete(p.listed, id)
	connection := p.connections[id]
	delete(p.connections, id)
	p.mu.Unlock()
	if connection != nil {
		connection.End()
	}
	p.secrets.Remove(id)
	for _, h := range p.records.Hosts() {
		if link := LinkOf(&h); link != nil && link.Provider == id {
			setLink(&h, nil)
			p.records.SaveHost(context.Background(), h)
		}
	}
	p.log("provider: removed " + id)
	p.changed()
	return nil
}

// Refresh is WorkspaceProviders.refresh: lists one provider, or every one ("" for every);
// a failed list keeps the last, marked not current.
func (p *Providers) Refresh(only string) {
	var ids []string
	if only != "" {
		ids = []string{only}
	} else {
		p.mu.Lock()
		for id := range p.providers {
			ids = append(ids, id)
		}
		p.mu.Unlock()
	}
	type result struct {
		id         string
		workspaces []WorkspaceInfo
		err        error
	}
	results := make(chan result)
	count := 0
	for _, id := range ids {
		connection, err := p.connection(id)
		if err != nil {
			continue
		}
		count++
		go func() {
			workspaces, err := connection.List()
			results <- result{id, workspaces, err}
		}()
	}
	for range count {
		r := <-results
		p.mu.Lock()
		if _, ok := p.providers[r.id]; ok {
			l := p.listed[r.id]
			if l == nil {
				l = &listed{current: true}
			}
			if r.err == nil {
				now := time.Now()
				l = &listed{workspaces: r.workspaces, listedAt: &now, current: true}
			} else {
				l.current = l.listedAt == nil
				l.problem = errorWords(r.err)
			}
			p.listed[r.id] = l
		}
		p.mu.Unlock()
	}
	p.changed()
}

// connection is a provider's connection, made when there is none.
func (p *Providers) connection(id string) (Provider, error) {
	p.mu.Lock()
	held, ok := p.connections[id]
	record, known := p.providers[id]
	p.mu.Unlock()
	if ok {
		return held, nil
	}
	if !known {
		return nil, providerFailure("That provider was removed.")
	}
	made, err := p.hooks.Connect(record.record, p.secrets.Values(id))
	if err != nil {
		var failure *ProviderFailure
		if errors.As(err, &failure) {
			p.mu.Lock()
			l := p.listed[id]
			if l == nil {
				l = &listed{}
			}
			l.current = false
			l.problem = failure.Words
			p.listed[id] = l
			p.mu.Unlock()
		}
		return nil, err
	}
	p.mu.Lock()
	if other, ok := p.connections[id]; ok {
		p.mu.Unlock()
		made.End()
		return other, nil
	}
	p.connections[id] = made
	p.mu.Unlock()
	return made, nil
}

// MARK: Links

func (p *Providers) link(request HostLink) (any, error) {
	p.mu.Lock()
	_, ok := p.providers[request.Provider]
	p.mu.Unlock()
	if !ok {
		return nil, invalid("There is no such provider.")
	}
	// One host per workspace: linking moves the link.
	for _, other := range p.records.Hosts() {
		link := LinkOf(&other)
		if other.ID != request.Host && link != nil && link.Provider == request.Provider && link.Workspace == request.Workspace {
			setLink(&other, nil)
			if err := p.records.SaveHost(context.Background(), other); err != nil {
				return nil, err
			}
		}
	}
	return p.changeLink(request.Host, func(h *records.HostRecord) {
		had := LinkOf(h)
		link := &WorkspaceLink{Provider: request.Provider, Workspace: request.Workspace}
		on := true
		switch {
		case request.StartWhenUsed != nil:
			link.StartWhenUsed = request.StartWhenUsed
		case had != nil && had.StartWhenUsed != nil:
			link.StartWhenUsed = had.StartWhenUsed
		default:
			link.StartWhenUsed = &on
		}
		switch {
		case request.StopWhenIdleMinutes != nil:
			if *request.StopWhenIdleMinutes > 0 {
				link.StopWhenIdleMinutes = request.StopWhenIdleMinutes
			}
		case had == nil:
			minutes := DefaultIdleMinutes
			link.StopWhenIdleMinutes = &minutes
		default:
			link.StopWhenIdleMinutes = had.StopWhenIdleMinutes
		}
		// The host's schedule and the switch are the host's, whatever it is linked to.
		if had != nil {
			link.StartForSchedules = had.StartForSchedules
			link.Schedule = had.Schedule
		}
		setLink(h, link)
	}, func() {
		// Listed again, in the background: the last list can be from before an install
		// woke the workspace (#965).
		go p.Refresh(request.Provider)
	})
}

func (p *Providers) changeLink(host string, change func(*records.HostRecord), after func()) (any, error) {
	record := p.records.Host(host)
	if record == nil {
		return nil, fail(CodeNoSuchHost, "No host is called %s.", host)
	}
	change(record)
	if err := p.records.SaveHost(context.Background(), *record); err != nil {
		return nil, err
	}
	if after != nil {
		after()
	}
	saved := record
	if h := p.records.Host(host); h != nil {
		saved = h
	}
	if link := LinkOf(saved); link != nil {
		p.log(fmt.Sprintf("workspace: %s linked to %s/%s", saved.Name, link.Provider, link.Workspace))
	} else {
		p.log(fmt.Sprintf("workspace: %s unlinked", saved.Name))
	}
	p.changed()
	return p.methods.HostRow(*saved), nil
}

// MARK: Starts and stops

// Keepable is WorkspaceProviders.keepable: the host's name when a prompt or start for it
// is to be kept (FR-020), "" when not. It is linked with start when used on, is not
// online, and its workspace is stopped or starting.
func (p *Providers) Keepable(host string) string {
	record := p.records.Host(host)
	link := LinkOf(record)
	if link == nil || (link.StartWhenUsed != nil && !*link.StartWhenUsed) {
		return ""
	}
	p.mu.Lock()
	_, known := p.providers[link.Provider]
	a := p.activities[host]
	p.mu.Unlock()
	if !known || p.router.Online(host) || (a != nil && a.kind == stopping) {
		return ""
	}
	if shown := p.overlay(*record); shown != nil && (shown.HostState == "stopped" || shown.HostState == "starting") {
		return record.Name
	}
	return ""
}

// StartForUse is WorkspaceProviders.startForUse: starts a host's workspace for a kept
// request, or joins the start under way.
func (p *Providers) StartForUse(host, by string) { p.begin(starting, host, by) }

func (p *Providers) begin(kind activityKind, host, who string) (any, error) {
	record := p.records.Host(host)
	if record == nil {
		return nil, fail(CodeNoSuchHost, "No host is called %s.", host)
	}
	link := LinkOf(record)
	p.mu.Lock()
	known := false
	if link != nil {
		_, known = p.providers[link.Provider]
	}
	if link == nil || !known {
		p.mu.Unlock()
		return nil, fail(CodeNotLinked, "%s isn’t linked to a workspace.", record.Name)
	}
	// One start or stop at a time per workspace (US1 AS4): a second press of the same joins
	// the first; the other is refused, never dropped without a word.
	if under := p.activities[host]; under != nil && under.kind != kind {
		p.mu.Unlock()
		if under.kind == starting {
			return nil, fail(CodeProviderFailed, "%s is starting. Stop it once it has started.", record.Name)
		}
		return nil, fail(CodeProviderFailed, "%s is stopping. Start it once it has stopped.", record.Name)
	}
	fresh := p.activities[host] == nil
	if fresh {
		phase := "stopping"
		if kind == starting {
			phase = "provider"
		}
		p.activities[host] = &activity{kind: kind, phase: phase, since: time.Now()}
		delete(p.problems, host)
		delete(p.stoppedBy, host)
		if t := p.idleTimers[host]; t != nil {
			t.Stop()
			delete(p.idleTimers, host)
		}
	}
	p.mu.Unlock()
	if fresh {
		p.changed()
		go p.run(kind, host, *link, who)
	}
	if h := p.records.Host(host); h != nil {
		record = h
	}
	return p.methods.HostRow(*record), nil
}

func (p *Providers) run(kind activityKind, host string, link WorkspaceLink, who string) {
	began := time.Now()
	name := host
	if h := p.records.Host(host); h != nil {
		name = h.Name
	}
	verb := "stop"
	if kind == starting {
		verb = "start"
	}
	what := fmt.Sprintf("%s (%s/%s)", name, link.Provider, link.Workspace)
	connection, err := p.connection(link.Provider)
	if err == nil {
		if kind == starting {
			_, err = connection.Start(link.Workspace)
		} else {
			_, err = connection.Stop(link.Workspace)
		}
	}
	if err != nil {
		reason := errorWords(err)
		p.log(fmt.Sprintf("workspace: %s %s by %s: failed: %s", verb, what, who, reason))
		if kind == starting {
			p.finish(host, "Couldn’t start "+name+": "+reason)
		} else {
			p.finish(host, "Couldn’t stop "+name+": "+reason)
		}
		return
	}
	p.Refresh(link.Provider)
	if kind == stopping {
		p.log(fmt.Sprintf("workspace: stop %s by %s: ok in %s", what, who, secondsSince(began)))
		// Said on its row and strip until it is started again (US4 AS1).
		p.mu.Lock()
		if minutes, ok := p.idleStopping[host]; ok {
			delete(p.idleStopping, host)
			p.stoppedBy[host] = "Stopped by Agents after " + minuteWords(minutes) + " idle"
		}
		delete(p.statuses, host)
		p.mu.Unlock()
		p.finish(host, "")
		return
	}
	// Started: now its agentsd has to connect (US1 AS2).
	p.setPhase(host, "connecting")
	p.hooks.OpenTunnel(host)
	sshTried := false
	for time.Since(began) < p.timing.GiveUp {
		if p.router.Online(host) {
			p.log(fmt.Sprintf("workspace: start %s by %s: ok in %s", what, who, secondsSince(began)))
			// How long it takes, so a wake-up call starts it early enough (#1004 FR-004).
			took := int(time.Since(began).Seconds())
			p.changeLinkQuietly(host, func(l *WorkspaceLink) { l.MeasuredStartSeconds = &took })
			// Done as it connects, so a Stop pressed the moment it shows online is heard.
			p.finish(host, "")
			p.Refresh(link.Provider)
			return
		}
		if !sshTried && time.Since(began) >= p.timing.SSHAfter {
			if record := p.records.Host(host); record != nil {
				if destination := p.sshDestination(link, host); destination != "" {
					sshTried = true
					p.setPhase(host, "sshStart")
					if err := p.hooks.SSHStart(*record, destination); err != nil {
						// Nothing else will bring it online, so the start ends now, with why (#960).
						reason := errorWords(err)
						p.log(fmt.Sprintf("workspace: ssh start %s: failed: %s", name, reason))
						p.log(fmt.Sprintf("workspace: start %s by %s: failed: ssh start failed", what, who))
						p.finish(host, name+" started, but its agentsd didn’t connect, and starting it over ssh failed. "+reason)
						return
					}
					p.log(fmt.Sprintf("workspace: ssh start %s: ok", name))
				}
			}
		}
		if !p.sleep(p.timing.LookEvery) {
			return
		}
	}
	minutes := durationWords(p.timing.GiveUp)
	var problem string
	if p.sshDestination(link, host) == "" {
		problem = name + " started, but its agentsd didn’t connect in " + minutes +
			", and the provider gives no ssh destination to start it with. Make agentsd start on boot (loginctl enable-linger)."
	} else {
		problem = name + " didn’t connect in " + minutes + "."
	}
	p.log(fmt.Sprintf("workspace: start %s by %s: failed: didn't connect in %s", what, who, minutes))
	p.finish(host, problem)
}

// MARK: Making and deleting (US5)

var hostNamePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9-]{0,62}$`)

// create is WorkspaceProviders.create (FR-040, FR-041): a workspace made with a one-time
// install command and host code for its first boot, so it joins by itself and is linked.
// A provider that cannot run it says so, and the person adds it over ssh.
func (p *Providers) create(request ProviderCreate, who string, caller *Caller) (any, error) {
	p.mu.Lock()
	held, ok := p.providers[request.ID]
	p.mu.Unlock()
	if !ok {
		return nil, invalid("There is no such provider.")
	}
	provider := held.record
	name := strings.TrimSpace(request.Name)
	if !hostNamePattern.MatchString(name) {
		return nil, invalid("A workspace’s name is letters, digits and dashes, and starts with a letter.")
	}
	for _, h := range p.records.Hosts() {
		if h.Name == name {
			return nil, invalid("There is already a host called %s.", name)
		}
	}
	// The install line holds a host code: passed on, never logged.
	command, err := p.hooks.HostCommand()
	if err != nil {
		var f *Failure
		if errors.As(err, &f) {
			return nil, f
		}
		return nil, fail(CodeInternalError, "%s", errorWords(err))
	}
	firstBoot := command + " " + shellQuoted(name)
	began := time.Now()
	options := request.Options
	if options == nil {
		options = map[string]any{}
	}
	var made *WorkspaceInfo
	var runs bool
	_, err = p.providerCall(request.ID, func(c Provider) (any, error) {
		var err error
		made, runs, err = c.Create(name, options, &firstBoot)
		return nil, err
	})
	if err != nil {
		p.log(fmt.Sprintf("workspace: create %s at %s by %s: failed: %s", name, provider.Name, who, errorWords(err)))
		return nil, err
	}
	p.Refresh(request.ID)
	p.mu.Lock()
	var listedNow []WorkspaceInfo
	if l := p.listed[request.ID]; l != nil {
		listedNow = l.workspaces
	}
	p.mu.Unlock()
	var found *WorkspaceInfo
	if made != nil {
		found = made
		for i := range listedNow {
			if listedNow[i].ID == made.ID {
				found = &listedNow[i]
				break
			}
		}
	} else {
		for i := range listedNow {
			if listedNow[i].Name == name || listedNow[i].ID == name {
				found = &listedNow[i]
				break
			}
		}
	}
	if found == nil {
		return nil, fail(CodeProviderFailed, "%s made %s, but doesn’t list it yet. Refresh in a minute.", provider.Name, name)
	}
	joiningWords := ""
	if runs {
		joiningWords = ", joining on first boot"
	}
	p.log(fmt.Sprintf("workspace: create %s (%s/%s) by %s: ok in %s%s", name, request.ID, found.ID, who,
		secondsSince(began), joiningWords))
	if runs {
		var clones []string
		for _, c := range request.Clones {
			if c = trimSpaces(c); c != "" {
				clones = append(clones, c)
			}
		}
		p.mu.Lock()
		p.joining[name] = &joining{provider: request.ID, workspace: found.ID, clones: clones, caller: caller}
		p.mu.Unlock()
		go p.linkWhenJoined(name)
	}
	return ProviderCreated{Workspace: *found, Joining: runs}, nil
}

// linkWhenJoined links a made workspace's host once it has joined, within the start's time.
func (p *Providers) linkWhenJoined(name string) {
	began := time.Now()
	for time.Since(began) < p.timing.GiveUp {
		p.mu.Lock()
		wanted := p.joining[name]
		p.mu.Unlock()
		if wanted == nil {
			return
		}
		for _, h := range p.records.Hosts() {
			if h.Name == name && LinkOf(&h) == nil {
				p.mu.Lock()
				delete(p.joining, name)
				p.mu.Unlock()
				p.link(HostLink{Host: h.ID, Provider: wanted.provider, Workspace: wanted.workspace})
				p.clone(wanted.clones, h.ID, name, wanted.caller)
				return
			}
		}
		if !p.sleep(p.timing.LookEvery) {
			return
		}
	}
	p.mu.Lock()
	_, still := p.joining[name]
	delete(p.joining, name)
	p.mu.Unlock()
	if still {
		p.log(fmt.Sprintf("workspace: %s was made but didn't join in %s", name, durationWords(p.timing.GiveUp)))
	}
}

// clone is WorkspaceProviders.clone (#1122): each project sent to the new host as File ▸
// Clone Project sends it, one after another, as the client that made the workspace. The
// URLs are not logged: one may hold a token.
func (p *Providers) clone(urls []string, host, name string, caller *Caller) {
	client, kind := records.NewUUID(), "mac"
	if caller != nil {
		client, kind = caller.Client, caller.Kind
	}
	for i, url := range urls {
		reply := p.router.DeliverKept(MethodProjectsClone, rawOf(map[string]string{"url": url}), client, kind, host, ClonePatience)
		outcome := "not answered"
		switch {
		case reply != nil && reply.Error != nil:
			// Its code only: the host's words may name the URL.
			outcome = fmt.Sprintf("failed (%d)", reply.Error.Code)
		case reply != nil:
			outcome = "ok"
		}
		p.log(fmt.Sprintf("workspace: %s clone %d of %d: %s", name, i+1, len(urls), outcome))
	}
}

// deleteWorkspace deletes a linked host's workspace, then removes the host as Remove does
// (FR-042).
func (p *Providers) deleteWorkspace(host, who string, caller Caller) error {
	record := p.records.Host(host)
	if record == nil {
		return fail(CodeNoSuchHost, "No host is called %s.", host)
	}
	link := LinkOf(record)
	p.mu.Lock()
	known := false
	if link != nil {
		_, known = p.providers[link.Provider]
	}
	busy := p.activities[host] != nil
	p.mu.Unlock()
	if link == nil || !known {
		return fail(CodeNotLinked, "%s isn’t linked to a workspace.", record.Name)
	}
	if busy {
		return fail(CodeProviderFailed, "%s is starting or stopping. Delete it once that is done.", record.Name)
	}
	what := fmt.Sprintf("%s (%s/%s)", record.Name, link.Provider, link.Workspace)
	if _, err := p.providerCall(link.Provider, func(c Provider) (any, error) { return nil, c.Delete(link.Workspace) }); err != nil {
		p.log(fmt.Sprintf("workspace: delete %s by %s: failed: %s", what, who, errorWords(err)))
		return err
	}
	p.log(fmt.Sprintf("workspace: delete %s by %s: ok", what, who))
	if err := p.methods.RemoveHost(host, caller); err != nil {
		return err
	}
	p.Refresh(link.Provider)
	return nil
}

// providerCall is a provider call, its failure in the provider's words.
func (p *Providers) providerCall(id string, work func(Provider) (any, error)) (any, error) {
	connection, err := p.connection(id)
	var out any
	if err == nil {
		out, err = work(connection)
	}
	var failure *ProviderFailure
	if errors.As(err, &failure) {
		return nil, fail(CodeProviderFailed, "%s", failure.Words)
	}
	return out, err
}

// shellQuoted is WorkspaceProviders.shellQuoted.
func shellQuoted(value string) string { return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'" }

// MARK: Stop when idle (US4)

// Heard is WorkspaceHandling.heard: a host said whether it is idle (host/status).
func (p *Providers) Heard(host string, status HostStatus) {
	p.mu.Lock()
	was, hadStatus := p.statuses[host]
	p.statuses[host] = status
	p.mu.Unlock()
	// Kept on its link, for while it is stopped (#1004 FR-003). A host from before #1004
	// says nothing, and is left as it was (FR-011).
	if schedule := status.Schedule.schedule(); schedule != nil {
		if link := LinkOf(p.records.Host(host)); link != nil && !link.Schedule.equal(schedule) {
			p.changeLinkQuietly(host, func(l *WorkspaceLink) { l.Schedule = schedule })
			p.changed()
		}
	}
	// Busy again cancels the count; still idle leaves it running (US4 AS2).
	p.mu.Lock()
	timer := p.idleTimers[host]
	if !status.Idle && timer != nil {
		timer.Stop()
		delete(p.idleTimers, host)
	}
	p.mu.Unlock()
	if status.Idle && (!hadStatus || !was.Idle || timer == nil) {
		p.countIdle(host)
	}
}

// countIdle starts counting down a linked host's stop when idle, from now, if it is idle,
// online and has one; otherwise it stops counting.
func (p *Providers) countIdle(host string) {
	p.mu.Lock()
	if t := p.idleTimers[host]; t != nil {
		t.Stop()
		delete(p.idleTimers, host)
	}
	idle := p.statuses[host].Idle
	busy := p.activities[host] != nil
	p.mu.Unlock()
	link := LinkOf(p.records.Host(host))
	if !idle || link == nil || link.StopWhenIdleMinutes == nil || *link.StopWhenIdleMinutes <= 0 || busy ||
		!p.router.Online(host) {
		return
	}
	minutes := *link.StopWhenIdleMinutes
	// The timer is made and kept under the lock, and its function reads it under the lock,
	// so a short idle time cannot fire before `timer` is set.
	var timer *time.Timer
	p.mu.Lock()
	timer = time.AfterFunc(p.timing.IdleMinute*time.Duration(minutes), func() {
		p.mu.Lock()
		t := timer
		p.mu.Unlock()
		p.idleFor(host, minutes, t)
	})
	if old := p.idleTimers[host]; old != nil {
		old.Stop()
	}
	p.idleTimers[host] = timer
	p.mu.Unlock()
}

func (p *Providers) idleFor(host string, minutes int, timer *time.Timer) {
	p.mu.Lock()
	if p.idleTimers[host] != timer {
		p.mu.Unlock()
		return
	}
	delete(p.idleTimers, host)
	idle := p.statuses[host].Idle
	busy := p.activities[host] != nil
	p.mu.Unlock()
	// Still idle, still online, and still set to this (US4 AS1).
	link := LinkOf(p.records.Host(host))
	if !idle || busy || !p.router.Online(host) || link == nil || link.StopWhenIdleMinutes == nil ||
		*link.StopWhenIdleMinutes != minutes {
		return
	}
	// Its next scheduled workflow is due within its idle time, or it was started for it: it
	// stays up for the run, and counts again (#1004 FR-005).
	if keptUp(*link, p.timing.IdleMinute*time.Duration(minutes), time.Now()) && link.Schedule != nil && link.Schedule.At != nil {
		workflow := link.Schedule.Workflow
		if workflow == "" {
			workflow = "a workflow"
		}
		p.log(fmt.Sprintf("workspace: %s idle %d min, kept up for %s at %s", host, minutes, workflow,
			link.Schedule.At.UTC().Format(time.RFC3339)))
		p.countIdle(host)
		return
	}
	p.mu.Lock()
	p.idleStopping[host] = minutes
	p.mu.Unlock()
	if _, err := p.begin(stopping, host, fmt.Sprintf("idle (%d min)", minutes)); err != nil {
		p.mu.Lock()
		delete(p.idleStopping, host)
		p.mu.Unlock()
		p.log(fmt.Sprintf("workspace: stop %s by idle (%d min): refused: %s", host, minutes, errorWords(err)))
	}
}

// MARK: Wake-up calls (#1004)

// lead is WorkspaceProviders.lead: how long before a due time a stopped workspace is
// started, its last measured start and 2 minutes, or 5 minutes when none was measured.
func lead(link WorkspaceLink) time.Duration {
	if link.MeasuredStartSeconds != nil {
		return time.Duration(*link.MeasuredStartSeconds+120) * time.Second
	}
	return 300 * time.Second
}

// keptUp is WorkspaceProviders.keptUp: whether its next scheduled workflow keeps it up
// though it is idle (FR-005).
func keptUp(link WorkspaceLink, idleFor time.Duration, now time.Time) bool {
	if link.Schedule == nil || link.Schedule.At == nil || !link.Schedule.At.After(now) {
		return false
	}
	at := *link.Schedule.At
	return at.Sub(now) <= idleFor || sameTime(link.WokeFor, &at)
}

// wakeAt is WorkspaceProviders.wakeAt: when a wake-up call would start it for its next
// scheduled workflow, with the switch on and a due time still to come that it was not
// already started for.
func wakeAt(link WorkspaceLink, now time.Time) *time.Time {
	if (link.StartForSchedules != nil && !*link.StartForSchedules) || link.Schedule == nil || link.Schedule.At == nil ||
		!link.Schedule.At.After(now) || sameTime(link.WokeFor, link.Schedule.At) {
		return nil
	}
	t := link.Schedule.At.Add(-lead(link))
	return &t
}

// wakeUps starts each stopped workspace whose wake-up call is due (FR-004, FR-006).
func (p *Providers) wakeUps(now time.Time) {
	for _, h := range p.records.Hosts() {
		link := LinkOf(&h)
		if link == nil {
			continue
		}
		p.mu.Lock()
		_, known := p.providers[link.Provider]
		busy := p.activities[h.ID] != nil
		p.mu.Unlock()
		wake := wakeAt(*link, now)
		if !known || wake == nil || wake.After(now) || busy {
			continue
		}
		if shown := p.overlay(h); shown == nil || shown.HostState != "stopped" || p.router.Online(h.ID) {
			continue
		}
		at := *link.Schedule.At
		// Marked before the start, so a restart or a reconnect never starts it twice for it.
		p.changeLinkQuietly(h.ID, func(l *WorkspaceLink) { l.WokeFor = &at })
		workflow := link.Schedule.Workflow
		if workflow == "" {
			workflow = "a workflow"
		}
		p.log(fmt.Sprintf("workspace: wake-up call for %s: %s due at %s", h.Name, workflow, at.UTC().Format(time.RFC3339)))
		p.begin(starting, h.ID, "schedule ("+workflow+")")
	}
}

// changeLinkQuietly changes a host's link and saves it, without telling clients.
func (p *Providers) changeLinkQuietly(host string, change func(*WorkspaceLink)) {
	record := p.records.Host(host)
	link := LinkOf(record)
	if link == nil {
		return
	}
	before := LinkOf(record)
	change(link)
	if link.equal(before) {
		return
	}
	setLink(record, link)
	if err := p.records.SaveHost(context.Background(), *record); err != nil {
		p.log(fmt.Sprintf("workspace: couldn't save %s's link: %v", record.Name, err))
	}
}

func (p *Providers) setPhase(host, phase string) {
	p.mu.Lock()
	if a := p.activities[host]; a != nil {
		a.phase = phase
	}
	p.mu.Unlock()
	p.changed()
}

func (p *Providers) finish(host, problem string) {
	p.mu.Lock()
	var kind activityKind
	if a := p.activities[host]; a != nil {
		kind = a.kind
	}
	delete(p.activities, host)
	delete(p.idleStopping, host)
	if problem == "" {
		delete(p.problems, host)
	} else {
		p.problems[host] = problem
	}
	kept := p.kept
	p.mu.Unlock()
	p.changed()
	if kind == starting && problem != "" && kept != nil {
		kept.StartFailed(host, problem)
	}
	// A host says it is idle as it connects, while the start is still under way, and is not
	// counted then: count now, or a host started and left idle is never stopped.
	if kind == starting && problem == "" {
		p.countIdle(host)
	}
}

// sshDestination is where agentsd is started over ssh: the provider's destination, or the
// one the host was installed over (#965).
func (p *Providers) sshDestination(link WorkspaceLink, host string) string {
	if w := p.workspace(link); w != nil && w.SSH != "" {
		return w.SSH
	}
	return p.hooks.InstalledOver(host)
}

func (p *Providers) workspace(link WorkspaceLink) *WorkspaceInfo {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.workspaceLocked(link)
}

func (p *Providers) workspaceLocked(link WorkspaceLink) *WorkspaceInfo {
	l := p.listed[link.Provider]
	if l == nil {
		return nil
	}
	for i := range l.workspaces {
		if l.workspaces[i].ID == link.Workspace {
			w := l.workspaces[i]
			return &w
		}
	}
	return nil
}

// MARK: What clients are told

// changed lays each linked host's workspace over its state, and tells clients the providers.
func (p *Providers) changed() {
	p.publishing.Lock()
	defer p.publishing.Unlock()
	for _, h := range p.records.Hosts() {
		p.router.SetWorkspace(h.ID, p.overlay(h))
	}
	p.router.BroadcastControl(NoticeProvidersChanged, map[string]any{"providers": p.Summaries()})
}

// Workspace is a host's workspace as it is laid over its state now, or nil.
func (p *Providers) Workspace(host string) *HostWorkspace {
	if h := p.records.Host(host); h != nil {
		return p.overlay(*h)
	}
	return nil
}

// overlay is WorkspaceProviders.overlay.
func (p *Providers) overlay(record records.HostRecord) *HostWorkspace {
	link := LinkOf(&record)
	if link == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	provider, ok := p.providers[link.Provider]
	if !ok {
		return nil
	}
	l := p.listed[link.Provider]
	found := p.workspaceLocked(*link)
	state := "unknown"
	if found != nil {
		state = found.State
	}
	a := p.activities[record.ID]
	now := time.Now()
	var hostState string
	switch {
	case a != nil && a.kind == starting:
		hostState = "starting"
	case a != nil:
		hostState = "stopping"
	case state == "stopped" || state == "starting" || state == "stopping":
		hostState = state
	}
	problem := p.problems[record.ID]
	ws := &HostWorkspace{Provider: link.Provider, ProviderName: provider.record.Name, Workspace: link.Workspace,
		WorkspaceName: link.Workspace, WorkspaceState: state, HostState: hostState, Problem: problem,
		// A running one whose start failed can be started again: its agentsd is what is down (#960).
		CanStart:      a == nil && (state != "running" && state != "starting" || state == "running" && problem != ""),
		CanStop:       a == nil && (state == "running" || state == "starting" || state == "unknown"),
		StartWhenUsed: link.StartWhenUsed == nil || *link.StartWhenUsed, StopWhenIdleMinutes: link.StopWhenIdleMinutes,
		Current: l != nil && l.current}
	if found != nil {
		ws.WorkspaceName = found.Name
		ws.Cost = found.Cost
	}
	if a != nil {
		ws.Since = refDate(a.since)
		if a.kind == starting {
			ws.Phase = a.phase
		}
	}
	if hostState == "stopped" {
		ws.StoppedBy = p.stoppedBy[record.ID]
	}
	on := link.StartForSchedules == nil || *link.StartForSchedules
	tells := link.Schedule != nil
	ws.StartForSchedules, ws.TellsSchedule = &on, &tells
	if s := link.Schedule; s != nil && s.At != nil && s.At.After(now) {
		ws.NextWorkflow = s.Workflow
		ws.NextWorkflowAt = refDate(*s.At)
	}
	// Also while it runs, so Stop's confirmation can say when it starts next (FR-010).
	if wake := wakeAt(*link, now); wake != nil {
		ws.WakeAt = refDate(*wake)
	}
	return ws
}

// MARK: Helpers

// SSHDestination is WorkspaceProviders.sshDestination(_:): an ssh destination as a
// provider may give it, alex@127.0.0.1 -p 2222, as one word ssh takes,
// ssh://alex@127.0.0.1:2222.
func SSHDestination(given string) string {
	words := strings.Fields(given)
	if len(words) != 3 || words[1] != "-p" {
		return given
	}
	port, err := strconv.Atoi(words[2])
	if err != nil {
		return given
	}
	return fmt.Sprintf("ssh://%s:%d", words[0], port)
}

// SayHostKeyUnknown is WorkspaceProviders.say for HostProblem.hostKeyUnknown: a host key
// to trust is trusted with ssh itself, as there is no install here to show it. Every other
// problem is said as HostInstall.say says it.
func SayHostKeyUnknown(destination string) string {
	return "Its host key isn’t in your known_hosts. Check and trust it with “ssh " + strings.Join(strings.Fields(destination), " ") +
		"”, then start it again."
}

func secondsSince(t time.Time) string { return fmt.Sprintf("%ds", int(time.Since(t).Seconds())) }

// durationWords is WorkspaceProviders.words(_ duration:).
func durationWords(d time.Duration) string {
	seconds := int(d.Seconds())
	if seconds >= 60 {
		return fmt.Sprintf("%d minutes", seconds/60)
	}
	return fmt.Sprintf("%d seconds", seconds)
}

// minuteWords is WorkspaceProviders.words(minutes:).
func minuteWords(minutes int) string {
	switch {
	case minutes == 60:
		return "1 hour"
	case minutes%60 == 0:
		return fmt.Sprintf("%d hours", minutes/60)
	case minutes == 1:
		return "1 minute"
	}
	return fmt.Sprintf("%d minutes", minutes)
}

// andList is WorkspaceProviders.list: "Claude (fix-login) and Codex (docs)".
func andList(names []string) string {
	if len(names) <= 1 {
		if len(names) == 1 {
			return names[0]
		}
		return ""
	}
	return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
}

// errorWords is ProviderDrafts.words: a provider's failure, a refusal's message, or the error.
func errorWords(err error) string {
	var failure *ProviderFailure
	if errors.As(err, &failure) {
		return failure.Words
	}
	var refused *Failure
	if errors.As(err, &refused) {
		return refused.Message
	}
	return err.Error()
}

// trimSpaces is trimmingCharacters(in: .whitespaces): spaces and tabs, not new lines.
func trimSpaces(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) })
}
