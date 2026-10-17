package controlplane

import (
	"context"
	"encoding/json"
	"os"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/web"
)

// Methods is ControlMethods: the methods the control plane answers itself (058,
// contracts/control-api.md), and what it does with a host's channel 0.
type Methods struct {
	s       *Service
	records *records.Records
	router  *Router

	mu sync.Mutex
	// The web remote's listener as it stands (071 R3), set as it binds.
	web *web.Status
	// A host's git waiting on a person's answer, by host and git server (#1122).
	gitAsks map[string]map[string]*gitAskWaiting
	// Frozen for a handover (R16): records are not to change until it is done.
	frozen bool
	// How long a git command waits for a person, and the lender to read its access.
	gitAskPatience  time.Duration
	gitFillPatience time.Duration
}

type gitAskWaiting struct {
	from    string
	waiting []chan bool
}

func newMethods(s *Service) *Methods {
	return &Methods{s: s, records: s.records, router: s.router, gitAsks: map[string]map[string]*gitAskWaiting{},
		gitAskPatience: 120 * time.Second, gitFillPatience: 30 * time.Second}
}

// own is ControlMethods.own: the methods with no host named that are the control
// plane's. Workspace methods join them once providers are ported.
var own = map[string]bool{
	"daemon/ping": true, "control/status": true, "hosts/list": true,
	"hosts/startEnroll": true, "hosts/install": true, "hosts/checkAgain": true,
	"hosts/update": true, "hosts/remove": true, "hosts/setRelay": true,
	"hosts/lendSignIn": true, "hosts/lendGit": true, "hosts/detect": true,
	"hosts/sshHosts": true, "control/setProjectDetection": true, "clients/list": true,
	"clients/startPairing": true, "clients/stopPairing": true,
	"clients/setGrant": true, "clients/forget": true, "clients/connections": true,
	"clients/forgetSelf": true,
	"devices/list":       true, "devices/startPairing": true, "devices/stopPairing": true,
	"devices/forget": true, "hosts/lastHeard": true,
}

// Handles says whether a bare method is the control plane's. A bare daemon/ping from
// today's Remote is the home host's to answer: that is how the Remote knows its Mac is
// there.
func (m *Methods) Handles(method string) bool {
	return method != "daemon/ping" && (own[method] || workspaceMethods[method])
}

func (m *Methods) setFrozen(frozen bool) {
	m.mu.Lock()
	m.frozen = frozen
	m.mu.Unlock()
}

// writes is ControlMethods.writes: what changes records, refused while frozen.
var writes = map[string]bool{
	"hosts/startEnroll": true, "hosts/install": true, "hosts/update": true, "hosts/remove": true,
	"hosts/setRelay": true, "hosts/lendSignIn": true, "hosts/lendGit": true, "hosts/detect": true,
	"control/setProjectDetection": true, "clients/startPairing": true, "clients/forget": true,
	"devices/startPairing": true, "devices/forget": true,
}

func (m *Methods) Handle(method string, params json.RawMessage, from Caller) (any, error) {
	ctx := context.Background()
	m.mu.Lock()
	frozen := m.frozen
	m.mu.Unlock()
	readsOnly := method == "providers/list" || method == "providers/refresh" || method == "hosts/listKept"
	if frozen && (writes[method] || workspaceMethods[method] && !readsOnly) {
		return nil, fail(storeUnavailable, "The control plane is moving to another machine. Nothing was changed; try again in a minute.")
	}
	switch method {
	case "daemon/ping":
		return map[string]any{}, nil
	case "control/status":
		return m.status(from), nil
	case "hosts/list":
		return m.hostList(), nil
	case "clients/list", "devices/list":
		out := []clientWire{}
		for _, c := range m.records.Clients() {
			out = append(out, clientOnWire(c))
		}
		return out, nil
	case "clients/connections":
		// The relaying host by name; with more than one, the first, as a relayed session
		// does not say which carried it.
		var relay *string
		for _, h := range m.records.Hosts() {
			if h.Relay != nil && *h.Relay {
				name := h.Name
				relay = &name
				break
			}
		}
		out := []clientConnection{}
		for client, relayed := range m.router.Connections() {
			c := clientConnection{Client: client, Relayed: relayed}
			if relayed {
				c.Through = relay
			}
			out = append(out, c)
		}
		sort.Slice(out, func(i, j int) bool { return out[i].Client < out[j].Client })
		return out, nil
	case "clients/startPairing":
		// A grant an older window still sends is let go: every client may do everything
		// (#111).
		var p struct {
			Kind string `json:"kind"`
		}
		json.Unmarshal(params, &p)
		return m.s.codes.Issue(ctx, false, p.Kind == records.KindBrowser, controllink.CodeLifetime)
	case "devices/startPairing":
		return m.s.codes.Issue(ctx, false, false, controllink.CodeLifetime)
	case "clients/stopPairing", "devices/stopPairing":
		return map[string]any{}, nil
	case "clients/setGrant":
		// An older window's grant picker, refused in words: there is nothing left to set.
		return nil, fail(notSupported, "Every paired client may do everything now, so there is no grant to change. Update this window to lose the choice.")
	case "clients/forget", "devices/forget":
		var p struct {
			Client string `json:"client"`
			ID     string `json:"id"`
		}
		json.Unmarshal(params, &p)
		id := p.Client
		if !controllink.IsUUID(id) {
			id = p.ID
		}
		if !controllink.IsUUID(id) {
			return nil, fail(invalidParams, "Which client?")
		}
		if err := m.forget(ctx, strings.ToUpper(id), 0); err != nil {
			return nil, err
		}
		m.s.announce("clientForgotten", strings.ToUpper(id), from.Client)
		return map[string]any{}, nil
	case "clients/forgetSelf":
		// Only itself. The reply goes before the sockets close, so the caller hears it.
		if err := m.forget(ctx, from.Client, 200*time.Millisecond); err != nil {
			return nil, err
		}
		m.s.announce("clientForgotten", from.Client, from.Client)
		return map[string]any{}, nil
	case "hosts/startEnroll":
		return m.s.codes.Issue(ctx, true, false, controllink.CodeLifetime)
	case "hosts/install":
		return m.s.installer.Install(ctx, params)
	case "hosts/detect":
		return m.s.installer.Detect(ctx)
	case "hosts/sshHosts":
		var p struct {
			Destination string `json:"destination"`
		}
		json.Unmarshal(params, &p)
		return m.s.installer.SSHHosts(ctx, strings.TrimSpace(p.Destination))
	case "hosts/update":
		request, err := require[hostRequest](params, "HostRequest")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, m.s.installer.Update(ctx, request.Host)
	case "hosts/checkAgain":
		request, err := require[hostRequest](params, "HostRequest")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, m.s.installer.CheckAgain(ctx, request.Host)
	case "control/setProjectDetection":
		request, err := require[projectDetection](params, "ProjectDetection")
		if err != nil {
			return nil, err
		}
		paths := []string{}
		for _, p := range request.Paths {
			if p = strings.TrimSpace(p); p != "" {
				paths = append(paths, p)
			}
		}
		request.Paths = paths
		raw, _ := json.Marshal(request)
		if _, err := m.records.ChangeSettings(ctx, func(s *records.Settings) { s.ProjectDetection = raw }); err != nil {
			return nil, err
		}
		return request, nil
	case "hosts/lendSignIn":
		request, err := require[lendSignIn](params, "LendSignIn")
		if err != nil {
			return nil, err
		}
		record := m.records.Host(request.Host)
		if record == nil || m.records.Host(request.From) == nil {
			return nil, fail(noSuchHost, "No such host.")
		}
		lends := map[string]string{}
		for k, v := range record.SignInFrom {
			lends[k] = v
		}
		if request.Allowed {
			lends[request.Runtime] = request.From
		} else {
			delete(lends, request.Runtime)
		}
		record.SignInFrom = lends
		if len(lends) == 0 {
			record.SignInFrom = nil
		}
		if err := m.records.SaveHost(ctx, *record); err != nil {
			return nil, err
		}
		m.s.announce("hostEnrolled", request.Host, from.Client)
		return map[string]any{}, nil
	case "hosts/lendGit":
		request, err := require[lendGit](params, "LendGit")
		if err != nil {
			return nil, err
		}
		if err := m.lendGit(ctx, request); err != nil {
			return nil, err
		}
		m.s.announce("hostEnrolled", request.Host, from.Client)
		return map[string]any{}, nil
	case "hosts/setRelay":
		request, err := require[hostRelayRequest](params, "HostRelayRequest")
		if err != nil {
			return nil, err
		}
		if err := m.setRelay(ctx, request); err != nil {
			return nil, err
		}
		m.s.announce("hostEnrolled", request.Host, from.Client)
		return map[string]any{}, nil
	case "hosts/remove":
		request, err := require[hostRequest](params, "HostRequest")
		if err != nil {
			return nil, err
		}
		gone, err := m.records.RemoveHost(ctx, request.Host)
		if err != nil {
			return nil, err
		}
		if !gone {
			return nil, fail(noSuchHost, "No host is called %s.", request.Host)
		}
		m.router.ForgetHost(request.Host)
		m.s.copies.forget(request.Host)
		if m.s.providers != nil && m.s.providers.Kept() != nil {
			m.s.providers.Kept().Forget(request.Host)
		}
		m.s.announce("hostRemoved", request.Host, from.Client)
		m.s.log("host " + request.Host + " removed")
		return map[string]any{}, nil
	case "hosts/lastHeard":
		request, err := require[hostRequest](params, "HostRequest")
		if err != nil {
			return nil, err
		}
		if m.records.Host(request.Host) == nil {
			return nil, fail(noSuchHost, "No host is called %s.", request.Host)
		}
		return m.s.copies.lastHeard(request.Host), nil
	}
	if workspaceMethods[method] {
		if m.s.providers == nil {
			return nil, fail(providersNeedOneCopy, "Workspace providers need a control plane with one copy, for now.")
		}
		return m.s.providers.Answer(method, params, providersCaller(from))
	}
	return nil, notFound(method)
}

// workspaceMethods is DaemonAPI.Method.workspaceMethods: workspace providers (#691).
var workspaceMethods = providers.WorkspaceMethods

func (m *Methods) status(from Caller) controlStatus {
	settings := m.records.Settings()
	if settings == nil {
		settings = &records.Settings{Name: m.s.cfg.Name, MachineID: m.s.cfg.MachineID}
	}
	started := RefDate(m.s.started)
	port := m.s.cfg.Port
	status := controlStatus{Name: settings.Name, Version: m.s.cfg.Version, HomeHost: settings.HomeHost,
		MachineID: settings.MachineID, StartedAt: &started, Port: &port, You: from.Client}
	m.mu.Lock()
	status.Web = m.web
	m.mu.Unlock()
	status.ThisMacHost = m.s.thisMacHost()
	if m.s.tunnels != nil {
		for _, unjoined := range m.s.tunnels.Unjoined() {
			raw, _ := json.Marshal(unjoined)
			status.UnjoinedTunnels = append(status.UnjoinedTunnels, raw)
		}
	}
	status.ProjectDetection = settings.ProjectDetection
	if len(status.ProjectDetection) == 0 {
		status.ProjectDetection, _ = json.Marshal(standardDetection)
	}
	away := false
	status.AwayFromHome = &away
	for _, h := range m.records.Hosts() {
		// A relay host is what takes devices out of the house (T096).
		if h.Relay != nil && *h.Relay {
			status.RelayKey = h.PublicKey
			status.AwayFromHome = &[]bool{true}[0]
			break
		}
	}
	return status
}

// SetWeb says how the web remote's listener stands, for control/status.
func (m *Methods) SetWeb(status *web.Status) {
	m.mu.Lock()
	m.web = status
	m.mu.Unlock()
}

func (m *Methods) hostList() []controlHost {
	out := []controlHost{}
	for _, h := range m.records.Hosts() {
		out = append(out, m.hostRow(h))
	}
	return out
}

// hostRow is one hosts/list row, as it stands now.
func (m *Methods) hostRow(h records.HostRecord) controlHost {
	state, _ := m.router.Described(h.ID)["state"].(string)
	row := controlHost{ID: h.ID, Name: h.Name, Platform: h.Platform, Version: h.Version, State: state,
		Reach: "dialOut", MachineID: h.MachineID, Relay: h.Relay, SignInFrom: h.SignInFrom, GitFrom: h.GitFrom}
	if impl, ok := h.Extra["implementation"]; ok {
		json.Unmarshal(impl, &row.Implementation)
	}
	m.mu.Lock()
	for server, ask := range m.gitAsks[h.ID] {
		row.GitAsks = append(row.GitAsks, gitAsk{Server: server, From: ask.from})
	}
	m.mu.Unlock()
	sort.Slice(row.GitAsks, func(i, j int) bool { return row.GitAsks[i].Server < row.GitAsks[j].Server })
	if ws := m.router.Workspace(h.ID); ws != nil {
		row.Workspace, _ = json.Marshal(ws)
	}
	if m.s.tunnels != nil {
		if tunnel := m.s.tunnels.State(h.ID); tunnel != nil {
			row.Tunnel, _ = json.Marshal(tunnel)
		}
	}
	return row
}

// forget writes a client's tombstone, then ends its sessions and tells every window.
func (m *Methods) forget(ctx context.Context, id string, after time.Duration) error {
	if err := m.records.ForgetClient(ctx, id); err != nil {
		return err
	}
	go func() {
		time.Sleep(after)
		m.router.ForgetClient(id)
		m.router.BroadcastControl("control/clientChanged", map[string]any{"client": id, "removed": true})
		m.s.tellRelayDevices()
	}()
	return nil
}

// Admit is ControlMethods.admit: a client that has paired, or connected again. lastSeen
// is written at most hourly (R4): a connect is not a write. Only a client that is new
// or renamed is said (#172); the router says a connect as the client's link changing.
func (m *Methods) Admit(ctx context.Context, client records.ClientRecord) error {
	said, err := m.admitOnce(ctx, client)
	if err != nil {
		if err := m.records.Load(ctx); err != nil {
			return err
		}
		if said, err = m.admitOnce(ctx, client); err != nil {
			return err
		}
	}
	if said {
		m.router.BroadcastControl("control/clientChanged", map[string]any{"client": client.ID})
		go m.s.tellRelayDevices()
	}
	return nil
}

func (m *Methods) admitOnce(ctx context.Context, client records.ClientRecord) (bool, error) {
	if known := m.records.Client(client.ID); known != nil {
		stale := known.LastSeen == nil || time.Since(known.LastSeen.Time) > time.Hour
		renamed := known.Name != client.Name
		if !stale && !renamed {
			return false, nil
		}
		now := records.Now()
		known.LastSeen = &now
		known.Name = client.Name
		return renamed, m.records.UpdateClient(ctx, *known)
	}
	if client.LastSeen == nil {
		now := records.Now()
		client.LastSeen = &now
	}
	return true, m.records.SaveClient(ctx, client)
}

// NoteEpoch is what a member said it holds of the endpoints (R16), written only when
// it changes. A conflict is let go: the next connection says it again.
func (m *Methods) NoteEpoch(ctx context.Context, id controllink.Identity, epoch int) {
	switch id.Kind {
	case 'c':
		if c := m.records.Client(id.ID); c != nil && (c.KnownEpoch == nil || *c.KnownEpoch != epoch) {
			c.KnownEpoch = &epoch
			m.records.UpdateClient(ctx, *c)
		}
	case 'h':
		if h := m.records.Host(id.ID); h != nil && (h.KnownEpoch == nil || *h.KnownEpoch != epoch) {
			h.KnownEpoch = &epoch
			m.records.SaveHost(ctx, *h)
		}
	}
}

// setRelay is hosts/setRelay or relay/switch (#824): a relay switched on or off, keeping
// its enrolment.
func (m *Methods) setRelay(ctx context.Context, request hostRelayRequest) error {
	record := m.records.Host(request.Host)
	if record == nil {
		return fail(noSuchHost, "No host is called %s.", request.Host)
	}
	// Only agents-relay carries devices; a host that runs agents cannot start to.
	if record.Relay == nil {
		return fail(invalidParams, "%s does not relay.", record.Name)
	}
	if *record.Relay == request.Relay {
		return nil
	}
	record.Relay = &request.Relay
	if err := m.records.SaveHost(ctx, *record); err != nil {
		return err
	}
	m.router.SetRelay(request.Host, record.Relay)
	m.s.tellRelayDevices()
	return nil
}

func (m *Methods) HostSaid(host, method string, params json.RawMessage) (any, error) {
	ctx := context.Background()
	switch method {
	case "control/ping":
		return map[string]any{}, nil
	case "host/hello":
		hello, err := require[hostHello](params, "HostHello")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, m.hello(ctx, host, hello)
	case "projects/detected":
		// Once: from now on its projects are the person's to add and remove (#429).
		if record := m.records.Host(host); record != nil && record.DetectProjects != nil && *record.DetectProjects {
			record.DetectProjects = nil
			if err := m.records.SaveHost(ctx, *record); err != nil {
				return nil, err
			}
		}
		return map[string]any{}, nil
	case "relay/switch":
		// A relay host on or off by its own word (#824): only its own record.
		request, err := require[struct {
			Relay bool `json:"relay"`
		}](params, "RelaySwitch")
		if err != nil {
			return nil, err
		}
		if err := m.setRelay(ctx, hostRelayRequest{Host: host, Relay: request.Relay}); err != nil {
			return nil, err
		}
		m.s.announce("hostEnrolled", host, host)
		return map[string]any{}, nil
	case "attention/need":
		m.s.heard(params)
		return map[string]any{}, nil
	case "host/workspaces", "host/providerDraft", "host/status":
		if m.s.providers == nil {
			if method == "host/status" {
				return map[string]any{}, nil
			}
			return nil, fail(providersNeedOneCopy, "Workspace providers need a control plane with one copy, for now.")
		}
		return m.s.providers.HostSaid(host, method, params)
	case "git/credential":
		request, err := require[gitCredentialRequest](params, "GitCredentialRequest")
		if err != nil {
			return nil, err
		}
		return m.gitCredential(ctx, host, request)
	case "tunnel/open":
		// Only to a lender a person said yes to, for that runtime (T091).
		request, err := require[tunnelOpen](params, "TunnelOpen")
		if err != nil {
			return nil, err
		}
		if record := m.records.Host(host); record == nil || record.SignInFrom[request.Runtime] == "" {
			m.records.Load(ctx)
		}
		record := m.records.Host(host)
		if record == nil || record.SignInFrom[request.Runtime] == "" {
			return nil, fail(notPermitted, "No host lends this host its %s sign-in.", request.Runtime)
		}
		if !m.router.OpenTunnel(host, record.SignInFrom[request.Runtime], request.Runtime, request.Ref) {
			return nil, fail(hostOffline, "The host that lends this sign-in is offline.")
		}
		return map[string]any{}, nil
	}
	return nil, notFound(method)
}

// hello is host/hello: what the host says it is now, written only when it changed
// something, and the home host settled.
func (m *Methods) hello(ctx context.Context, host string, hello hostHello) error {
	known := m.records.Host(host)
	record := records.HostRecord{ID: host, Name: host}
	if hello.Name != nil {
		record.Name = *hello.Name
	}
	if known != nil {
		record = *known
	}
	record.Version = hello.Version
	record.Platform = hello.Platform
	mid := hello.MachineID
	record.MachineID = &mid
	if hello.Name != nil {
		record.Name = *hello.Name
	}
	// Which language the host is written in (#1134), kept beside the record's own fields
	// so a Swift copy keeps it too.
	if hello.Implementation != "" {
		impl, _ := json.Marshal(hello.Implementation)
		extra := records.Extra{}
		for k, v := range record.Extra {
			extra[k] = v
		}
		extra["implementation"] = impl
		record.Extra = extra
	} else if _, had := record.Extra["implementation"]; had {
		extra := records.Extra{}
		for k, v := range record.Extra {
			if k != "implementation" {
				extra[k] = v
			}
		}
		record.Extra = extra
	}
	// Whether a host relays is settled when it enrols and changed only by a person
	// (hosts/setRelay). A host's own hello never makes it a relay (T102).
	changed := known == nil || !sameHost(*known, record)
	if changed {
		if err := m.records.SaveHost(ctx, record); err != nil {
			return err
		}
	}
	// The home host is where a device's plain connection goes: the host on the control
	// plane's own machine, or, on a control plane with none, the first host to join until
	// one on its machine does.
	if hello.Relay == nil || !*hello.Relay {
		settings := m.records.Settings()
		if settings != nil {
			onThisMachine := hello.MachineID == settings.MachineID
			homeIsHere := false
			if settings.HomeHost != nil {
				if h := m.records.Host(*settings.HomeHost); h != nil && h.MachineID != nil && *h.MachineID == settings.MachineID {
					homeIsHere = true
				}
			}
			if settings.HomeHost == nil || (onThisMachine && *settings.HomeHost != host && !homeIsHere) {
				if _, err := m.records.ChangeSettings(ctx, func(s *records.Settings) { s.HomeHost = &host }); err != nil {
					return err
				}
				m.router.SetHomeHost(host)
				changed = true
			}
		}
	}
	if changed {
		m.router.BroadcastControl("control/hostChanged", m.router.Described(host))
	}
	if record.Relay != nil && *record.Relay {
		m.s.tellRelayDevices()
	}
	// A host marked before #656 to add the projects it found: the mark goes, unsaid.
	if r := m.records.Host(host); r != nil && r.DetectProjects != nil && *r.DetectProjects {
		r.DetectProjects = nil
		m.records.SaveHost(ctx, *r)
	}
	return nil
}

func sameHost(a, b records.HostRecord) bool {
	x, _ := records.Encode(a)
	y, _ := records.Encode(b)
	return string(x) == string(y)
}

// MARK: Git access lent between hosts (#1122)

type gitCredentialRequest struct {
	Protocol string `json:"protocol"`
	Host     string `json:"host"`
	Path     string `json:"path,omitempty"`
}

// isGitServer is GitCredentialRequest.isServer: a host name, and nothing else.
func isGitServer(s string) bool {
	if s == "" || len(s) > 253 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == ':') {
			return false
		}
	}
	return true
}

// lendGit is hosts/lendGit: kept for a yes, taken back for a no; either ends a waiting ask.
func (m *Methods) lendGit(ctx context.Context, request lendGit) error {
	if !isGitServer(request.Server) {
		return fail(invalidParams, "That is not a git server.")
	}
	record := m.records.Host(request.Host)
	if record == nil || m.records.Host(request.From) == nil {
		return fail(noSuchHost, "No such host.")
	}
	lends := map[string]string{}
	for k, v := range record.GitFrom {
		lends[k] = v
	}
	if request.Allowed {
		lends[request.Server] = request.From
	} else {
		delete(lends, request.Server)
	}
	before := *record
	record.GitFrom = lends
	if len(lends) == 0 {
		record.GitFrom = nil
	}
	if !sameHost(before, *record) {
		if err := m.records.SaveHost(ctx, *record); err != nil {
			return err
		}
	}
	m.mu.Lock()
	asked := m.gitAsks[request.Host][request.Server]
	delete(m.gitAsks[request.Host], request.Server)
	m.mu.Unlock()
	if asked != nil {
		for _, w := range asked.waiting {
			w <- request.Allowed
		}
	}
	m.sayHostChanged(request.Host)
	return nil
}

// gitCredential is git/credential from a host's git: the lent credential, asked of the
// lender only for a lend a person allowed. With none yet, every client is asked, and the
// command waits for the answer. It fails at once while the lender is not connected.
func (m *Methods) gitCredential(ctx context.Context, host string, request gitCredentialRequest) (json.RawMessage, error) {
	if request.Protocol != "https" || !isGitServer(request.Host) {
		return nil, fail(invalidParams, "Only https git access is lent.")
	}
	server := request.Host
	record := m.records.Host(host)
	if record == nil {
		return nil, fail(noSuchHost, "No such host.")
	}
	lender := record.GitFrom[server]
	if lender == "" {
		mac := m.gitLender(host)
		if mac == "" {
			return nil, fail(hostOffline, "No Mac is connected to lend its git access for %s; it is lent only while that Mac is connected.", server)
		}
		if !m.askToLendGit(host, mac, server) {
			return nil, fail(notPermitted, "%s may not use the git access of %s for %s.", record.Name, m.name(mac), server)
		}
		if r := m.records.Host(host); r != nil {
			lender = r.GitFrom[server]
		}
	}
	if lender == "" {
		return nil, fail(notPermitted, "%s may not use any git access for %s.", record.Name, server)
	}
	lenderName := m.name(lender)
	if s, ok := m.router.State(lender); !ok || !s.online() {
		return nil, fail(hostOffline, "%s is not connected; its git access is lent only while it is connected.", lenderName)
	}
	answer := m.router.Ask(lender, "git/fill", request, m.gitFillPatience)
	if answer == nil {
		return nil, fail(hostOffline, "%s did not answer for its git access to %s.", lenderName, server)
	}
	if len(answer.Result) > 0 {
		var credential struct {
			Username string `json:"username"`
			Password string `json:"password"`
		}
		if json.Unmarshal(answer.Result, &credential) == nil && credential.Password != "" {
			return answer.Result, nil
		}
	}
	return nil, fail(notPermitted, "%s has no git access to %s.", lenderName, server)
}

// gitLender is the Mac whose git access a host would use: the home host if it is a Mac,
// else the first connected Mac. Never the host itself, and never a relay.
func (m *Methods) gitLender(host string) string {
	var macs []string
	for _, r := range m.records.Hosts() {
		if r.ID == host || r.Relay != nil || !strings.HasPrefix(r.Platform, "macOS") {
			continue
		}
		if s, ok := m.router.State(r.ID); ok && s.online() {
			macs = append(macs, r.ID)
		}
	}
	if settings := m.records.Settings(); settings != nil && settings.HomeHost != nil {
		for _, mac := range macs {
			if mac == *settings.HomeHost {
				return mac
			}
		}
	}
	sort.Strings(macs)
	if len(macs) == 0 {
		return ""
	}
	return macs[0]
}

// askToLendGit asks every client, through the host's row; true once a person allows it.
func (m *Methods) askToLendGit(host, from, server string) bool {
	answer := make(chan bool, 1)
	m.mu.Lock()
	if m.gitAsks[host] == nil {
		m.gitAsks[host] = map[string]*gitAskWaiting{}
	}
	ask := m.gitAsks[host][server]
	first := ask == nil
	if first {
		ask = &gitAskWaiting{from: from}
		m.gitAsks[host][server] = ask
	}
	ask.waiting = append(ask.waiting, answer)
	patience := m.gitAskPatience
	m.mu.Unlock()
	if first {
		m.sayHostChanged(host)
	}
	select {
	case allowed := <-answer:
		return allowed
	case <-time.After(patience):
		m.mu.Lock()
		gone := m.gitAsks[host][server]
		delete(m.gitAsks[host], server)
		m.mu.Unlock()
		if gone != nil {
			for _, w := range gone.waiting {
				select {
				case w <- false:
				default:
				}
			}
			m.sayHostChanged(host)
		}
		select {
		case allowed := <-answer:
			return allowed
		default:
			return false
		}
	}
}

func (m *Methods) name(host string) string {
	if r := m.records.Host(host); r != nil {
		return r.Name
	}
	return host
}

// sayHostChanged tells every client to list the host's row again.
func (m *Methods) sayHostChanged(host string) {
	if _, ok := m.router.State(host); ok {
		m.router.BroadcastControl("control/hostChanged", m.router.Described(host))
	}
}

// readJoinFile is HostJoinFile.read: how this Mac's host's join stands, from its root's
// control-join.json, while the process that wrote it lives.
func readJoinFile(file string) *HostJoinStatus {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil
	}
	var read struct {
		PID    int `json:"pid"`
		Status struct {
			Member    bool      `json:"member"`
			Connected bool      `json:"connected"`
			Problem   *string   `json:"problem"`
			At        time.Time `json:"at"`
		} `json:"status"`
	}
	if json.Unmarshal(data, &read) != nil {
		return nil
	}
	if err := syscall.Kill(read.PID, 0); err != nil && err != syscall.EPERM {
		return nil
	}
	return &HostJoinStatus{Member: read.Status.Member, Connected: read.Status.Connected, Problem: read.Status.Problem,
		At: RefDate(read.Status.At)}
}
