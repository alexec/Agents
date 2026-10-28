package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/apns"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/web"
	"github.com/alexec/agents/Go/wire"
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
	// The audit (#996) is told each call the router passes on or answers here.
	s.startAudit()
	return &Methods{s: s, records: s.records, router: s.router, gitAsks: map[string]map[string]*gitAskWaiting{},
		gitAskPatience: 120 * time.Second, gitFillPatience: 30 * time.Second}
}

// own is ControlMethods.own: the methods with no host named that are the control
// plane's. Workspace methods join them once providers are ported. One a line, sorted, so
// two features that each add one touch different lines (#2020).
var own = methodSet(
	"audit/export",
	"audit/list",
	"audit/setSinks",
	"audit/sinks",
	"bots/make",
	"bots/setCaps",
	"bots/stopRun",
	"clients/connections",
	"clients/forget",
	"clients/forgetSelf",
	"clients/list",
	"clients/setActivityToken",
	"clients/setGrant",
	"clients/setPushToken",
	"clients/startPairing",
	"clients/stopPairing",
	"control/rotate",
	"control/setAuditDays",
	"control/setFolderDetection",
	"control/status",
	"daemon/ping",
	"devices/forget",
	"devices/list",
	"devices/startPairing",
	"devices/stopPairing",
	"governance/approvals",
	"governance/decide",
	"governance/request",
	"governance/requests",
	"governance/revoke",
	"governance/usage",
	"groups/list",
	"groups/remove",
	"groups/set",
	"groups/setRole",
	"hosts/approveJoin",
	"hosts/checkAgain",
	"hosts/denyJoin",
	"hosts/detect",
	"hosts/install",
	"hosts/joinRequests",
	"hosts/lastHeard",
	"hosts/lendGit",
	"hosts/lendSignIn",
	"hosts/list",
	"hosts/remove",
	"hosts/setRelay",
	"hosts/sshHosts",
	"hosts/startEnroll",
	"hosts/update",
	"links/approve",
	"links/deny",
	"links/list",
	"links/remove",
	"links/requests",
	"orgRoutes/check",
	"orgRoutes/list",
	"orgRoutes/mine",
	"orgRoutes/remove",
	"orgRoutes/replaceKey",
	"orgRoutes/set",
	"people/invite",
	"people/list",
	"people/remove",
	"people/removePreview",
	"people/removeRequests",
	"people/setRole",
	"policy/get",
	"policy/mine",
	"policy/raise",
	"policy/set",
	"policy/stopAll",
	"projects/list",
	"projects/remove",
	"projects/set",
	"projects/setSlot",
	"providers/setGroup",
	"readApi/list",
	"readApi/make",
	"readApi/revoke",
	"reports/export",
	"reports/usage",
	"scim/set",
	"scim/tokens/list",
	"scim/tokens/make",
	"scim/tokens/revoke",
	"signIn/addToMe",
	"signIn/approve",
	"signIn/configure",
	"signIn/deny",
	"signIn/discover",
	"signIn/domains/check",
	"signIn/domains/claim",
	"signIn/domains/list",
	"signIn/domains/preview",
	"signIn/domains/remove",
	"signIn/domains/set",
	"signIn/orgProviders/check",
	"signIn/orgProviders/list",
	"signIn/orgProviders/remove",
	"signIn/orgProviders/set",
	"signIn/orgStart",
	"signIn/pair",
	"signIn/providers",
	"signIn/removeFromMe",
	"signIn/requests",
	"signIn/ticket",
	"user/removeSecret",
	"user/secretNames",
	"user/setAgentConfigFile",
	"user/setSecret",
	"user/setSettings",
	"user/settings",
)

// Handles says whether a bare method is the control plane's. A bare daemon/ping from
// today's Remote is the home host's to answer: that is how the Remote knows its Mac is
// there.
func (m *Methods) Handles(method string) bool {
	return method != "daemon/ping" && (own[method] || workspaceMethods[method] || consoleMethods[method] || scopeMethods[method])
}

// methodSet is a list of methods as a set: a list, not a map literal, so that gofmt does
// not align it (#2020).
func methodSet(methods ...string) map[string]bool {
	out := make(map[string]bool, len(methods))
	for _, method := range methods {
		out[method] = true
	}
	return out
}

func (m *Methods) setFrozen(frozen bool) {
	m.mu.Lock()
	m.frozen = frozen
	m.mu.Unlock()
}

// writes is ControlMethods.writes: what changes records, refused while frozen. One a
// line, sorted (#2020).
var writes = methodSet(
	"audit/setSinks",
	"bots/make",
	"bots/setCaps",
	"clients/forget",
	"clients/setActivityToken",
	"clients/setPushToken",
	"clients/startPairing",
	"control/rotate",
	"control/setAuditDays",
	"control/setFolderDetection",
	"devices/forget",
	"devices/startPairing",
	"governance/decide",
	"governance/request",
	"governance/revoke",
	"groups/remove",
	"groups/set",
	"groups/setRole",
	"hosts/approveJoin",
	"hosts/denyJoin",
	"hosts/detect",
	"hosts/install",
	"hosts/lendGit",
	"hosts/lendSignIn",
	"hosts/remove",
	"hosts/setRelay",
	"hosts/startEnroll",
	"hosts/update",
	"links/approve",
	"links/deny",
	"links/remove",
	"orgRoutes/remove",
	"orgRoutes/replaceKey",
	"orgRoutes/set",
	"people/invite",
	"people/remove",
	"people/setRole",
	"policy/raise",
	"policy/set",
	"policy/stopAll",
	"projects/remove",
	"projects/set",
	"projects/setSlot",
	"providers/setGroup",
	"readApi/make",
	"readApi/revoke",
	"reports/setPolicy",
	"scim/set",
	"scim/tokens/make",
	"scim/tokens/revoke",
	"signIn/addToMe",
	"signIn/approve",
	"signIn/configure",
	"signIn/deny",
	"signIn/domains/check",
	"signIn/domains/claim",
	"signIn/domains/remove",
	"signIn/domains/set",
	"signIn/orgProviders/remove",
	"signIn/orgProviders/set",
	"signIn/orgStart",
	"signIn/removeFromMe",
	"signIn/ticket",
	"user/removeSecret",
	"user/setAgentConfigFile",
	"user/setSecret",
	"user/setSettings",
)

func (m *Methods) Handle(method string, params json.RawMessage, from Caller) (any, error) {
	ctx := context.Background()
	m.mu.Lock()
	frozen := m.frozen
	m.mu.Unlock()
	readsOnly := method == "providers/list" || method == "providers/refresh" || method == "hosts/listKept"
	if frozen && (writes[method] || workspaceMethods[method] && !readsOnly) {
		return nil, fail(storeUnavailable, "The control plane is moving to another machine. Nothing was changed; try again in a minute.")
	}
	if m.s.cfg.Hosted && overSSH[method] {
		return nil, noSSHHere
	}
	// Another user's machine is not there (#994, FR-018); bots/stopRun names a bot's, an
	// admin's to stop (#1761), and console/stopAgent anyone's, an admin's to stop (#2019, M9).
	if method != "bots/stopRun" && method != "console/stopAgent" {
		if err := m.refuseOthersHosts(params, from); err != nil {
			return nil, err
		}
	}
	if ownersSSH[method] && m.callerPerson(from) != m.s.localOwner() {
		return nil, notOwnersSSH
	}
	// What a code makes is the caller's person's (FR-017).
	ctx = withCodeOwner(ctx, m.callerPerson(from))
	if consoleMethods[method] {
		return m.consoleMethod(ctx, method, params, from)
	}
	if scopeMethods[method] {
		return m.reportMethod(ctx, method, params, from)
	}
	switch method {
	case "daemon/ping":
		return map[string]any{}, nil
	case "control/status":
		return m.status(from), nil
	case "hosts/list":
		return m.hostList(from), nil
	case "clients/list", "devices/list":
		// The caller's person's own clients (#994).
		out := []wire.ClientRecord{}
		for _, c := range m.records.Clients() {
			if m.s.PersonOf(c.ID) == m.callerPerson(from) {
				out = append(out, clientOnWire(c))
			}
		}
		return out, nil
	case "people/list", "people/invite", "people/setRole", "people/remove", "people/removePreview", "people/removeRequests":
		return m.peopleMethod(ctx, method, params, from)
	case "groups/list", "groups/set", "groups/remove", "groups/setRole", "providers/setGroup":
		return m.groupsMethod(ctx, method, params, from)
	case "projects/list", "projects/set", "projects/remove", "projects/setSlot":
		return m.projectsMethod(ctx, method, params, from)
	case "scim/set", "scim/tokens/list", "scim/tokens/make", "scim/tokens/revoke":
		return m.scimMethod(ctx, method, params, from)
	case "bots/make", "bots/setCaps", "bots/stopRun":
		return m.botsMethod(ctx, method, params, from)
	case "policy/get", "policy/mine", "policy/set", "policy/stopAll", "policy/raise":
		return m.policyMethod(ctx, method, params, from)
	case "orgRoutes/mine", "orgRoutes/list", "orgRoutes/set", "orgRoutes/replaceKey", "orgRoutes/check", "orgRoutes/remove":
		return m.orgRoutesMethod(ctx, method, params, from)
	case "links/list", "links/requests", "links/approve", "links/deny", "links/remove":
		return m.linksMethod(ctx, method, params, from)
	case "signIn/providers", "signIn/pair", "signIn/addToMe", "signIn/removeFromMe", "signIn/configure",
		"signIn/requests", "signIn/approve", "signIn/deny", "signIn/discover", "signIn/orgStart", "signIn/ticket",
		"signIn/orgProviders/check", "signIn/orgProviders/list", "signIn/orgProviders/remove", "signIn/orgProviders/set",
		"signIn/domains/check", "signIn/domains/claim", "signIn/domains/list", "signIn/domains/preview",
		"signIn/domains/remove", "signIn/domains/set":
		return m.signInMethod(ctx, method, params, from)
	case "reports/usage", "reports/export":
		return m.reportMethod(ctx, method, params, from)
	case "user/settings", "user/setAgentConfigFile", "user/setSettings", "user/setSecret", "user/removeSecret", "user/secretNames":
		return m.userMethod(ctx, method, params, from)
	case "hosts/joinRequests":
		return m.s.joins.list(ctx, m.callerPerson(from))
	case "hosts/approveJoin", "hosts/denyJoin":
		request, err := require[wire.JoinRequestDecide](params, "JoinRequestDecide")
		if err != nil {
			return nil, err
		}
		approved, err := m.s.joins.decide(ctx, request.Request, m.callerPerson(from), method == "hosts/approveJoin")
		if err != nil || approved == nil {
			return map[string]any{}, err
		}
		return approved, nil
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
		out := []wire.ClientConnection{}
		for client, relayed := range m.router.Connections() {
			if m.s.PersonOf(client) != m.callerPerson(from) {
				continue
			}
			c := wire.ClientConnection{Client: wire.UUID(client), Relayed: relayed}
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
		var p wire.ClientPairingRequest
		json.Unmarshal(params, &p)
		return m.s.codes.Issue(ctx, false, deref(p.Kind) == records.KindBrowser, controllink.CodeLifetime)
	case "devices/startPairing":
		return m.s.codes.Issue(ctx, false, false, controllink.CodeLifetime)
	case "clients/stopPairing", "devices/stopPairing":
		return map[string]any{}, nil
	case "clients/setGrant":
		// An older window's grant picker, refused in words: there is nothing left to set.
		return nil, fail(notSupported, "Every paired client may do everything now, so there is no grant to change. Update this window to lose the choice.")
	case "clients/forget", "devices/forget":
		// clients/forget says the client; devices/forget, from an older Remote, its id.
		var client wire.ClientRequest
		var device wire.DeviceForget
		json.Unmarshal(params, &client)
		json.Unmarshal(params, &device)
		id := string(client.Client)
		if !controllink.IsUUID(id) {
			id = string(device.ID)
		}
		if !controllink.IsUUID(id) {
			return nil, fail(invalidParams, "Which client?")
		}
		// Only the person's own; an admin removes another's with the person (#994).
		if m.records.Client(id) != nil && m.s.PersonOf(id) != m.callerPerson(from) {
			return nil, fail(invalidParams, "There is no such client.")
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
	case "clients/setPushToken":
		request, err := require[wire.PushToken](params, "PushToken")
		if err != nil {
			return nil, err
		}
		if err := m.setPushToken(ctx, from.Client, request); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	case "clients/setActivityToken":
		request, err := require[wire.ActivityToken](params, "ActivityToken")
		if err != nil {
			return nil, err
		}
		if err := m.setActivityToken(ctx, from.Client, request); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	case "hosts/startEnroll":
		// With as, a machine for a bot, which an admin enrols (#1761, FR-030).
		var enroll wire.MachineEnroll
		json.Unmarshal(params, &enroll)
		if bot := deref(enroll.As); bot != "" {
			if !m.s.isAdmin(m.callerPerson(from)) {
				return nil, fail(notPermitted, "Only an admin can add a machine for a bot.")
			}
			if !m.s.isBot(bot) {
				return nil, fail(invalidParams, "There is no such bot.")
			}
			ctx = withCodeOwner(ctx, bot)
		}
		return m.s.codes.Issue(ctx, true, false, controllink.CodeLifetime)
	case "hosts/install":
		return m.s.installer.Install(ctx, params)
	case "hosts/detect":
		return m.s.installer.Detect(ctx)
	case "hosts/sshHosts":
		var p wire.SSHHostsRequest
		json.Unmarshal(params, &p)
		return m.s.installer.SSHHosts(ctx, strings.TrimSpace(deref(p.Destination)))
	case "hosts/update":
		request, err := require[wire.MachineUpdate](params, "MachineUpdate")
		if err != nil {
			return nil, err
		}
		h := m.s.records.Host(string(request.Host))
		if h == nil {
			return nil, &RPCError{Code: wire.FailureNoSuchHost, Message: "There is no such host."}
		}
		return m.s.installer.Update(ctx, request, h.Name)
	case "hosts/checkAgain":
		request, err := require[wire.MachineRequest](params, "MachineRequest")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, m.s.installer.CheckAgain(ctx, string(request.Host))
	case "audit/list", "audit/export", "control/setAuditDays":
		return m.auditMethod(ctx, method, params, from)
	case "audit/sinks", "audit/setSinks":
		return m.auditSinksMethod(ctx, method, params, from)
	case "governance/usage", "governance/request", "governance/requests", "governance/decide", "governance/approvals", "governance/revoke":
		return m.governanceMethod(ctx, method, params, from)
	case "readApi/list", "readApi/make", "readApi/revoke":
		return m.readAPIMethod(ctx, method, params, from)
	case "control/rotate":
		return wire.Empty{}, m.s.rotate(ctx, from)
	case "control/setFolderDetection":
		request, err := require[wire.FolderDetection](params, "FolderDetection")
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
		if _, err := m.records.ChangeSettings(ctx, func(s *records.Settings) { s.FolderDetection = raw }); err != nil {
			return nil, err
		}
		return request, nil
	case "hosts/lendSignIn":
		request, err := require[wire.LendSignIn](params, "LendSignIn")
		if err != nil {
			return nil, err
		}
		record := m.records.Host(string(request.Host))
		if record == nil || m.records.Host(string(request.From)) == nil || !m.sameUser(record.ID, string(request.From)) {
			return nil, fail(noSuchHost, "No such host.")
		}
		lends := map[string]string{}
		for k, v := range record.SignInFrom {
			lends[k] = v
		}
		if request.Allowed {
			lends[request.Runtime] = string(request.From)
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
		m.s.announce("hostEnrolled", string(request.Host), from.Client)
		return map[string]any{}, nil
	case "hosts/lendGit":
		request, err := require[wire.LendGit](params, "LendGit")
		if err != nil {
			return nil, err
		}
		if err := m.lendGit(ctx, request); err != nil {
			return nil, err
		}
		m.s.announce("hostEnrolled", string(request.Host), from.Client)
		return map[string]any{}, nil
	case "hosts/setRelay":
		request, err := require[wire.MachineRelayRequest](params, "MachineRelayRequest")
		if err != nil {
			return nil, err
		}
		if err := m.setRelay(ctx, request); err != nil {
			return nil, err
		}
		m.s.announce("hostEnrolled", string(request.Host), from.Client)
		return map[string]any{}, nil
	case "hosts/remove":
		request, err := require[wire.MachineRequest](params, "MachineRequest")
		if err != nil {
			return nil, err
		}
		host := string(request.Host)
		gone, err := m.removeHost(ctx, host, from)
		if err != nil {
			return nil, err
		}
		if !gone {
			return nil, fail(noSuchHost, "No machine is called %s.", host)
		}
		return map[string]any{}, nil
	case "hosts/lastHeard":
		request, err := require[wire.MachineRequest](params, "MachineRequest")
		if err != nil {
			return nil, err
		}
		host := string(request.Host)
		if m.records.Host(host) == nil {
			return nil, fail(noSuchHost, "No machine is called %s.", host)
		}
		return m.s.copies.lastHeard(host), nil
	}
	if workspaceMethods[method] {
		if m.s.providers == nil {
			return nil, fail(providersNeedOneCopy, "Machine providers need a control plane with one copy, for now.")
		}
		return m.s.providers.Answer(method, params, providersCaller(from))
	}
	return nil, notFound(method)
}

// workspaceMethods is DaemonAPI.Method.workspaceMethods: machine providers (#691).
var workspaceMethods = providers.WorkspaceMethods

func (m *Methods) status(from Caller) wire.ControlStatus {
	settings := m.records.Settings()
	if settings == nil {
		settings = &records.Settings{Name: m.s.cfg.Name, MachineID: m.s.cfg.MachineID}
	}
	status := wire.ControlStatus{Name: settings.Name, Version: m.s.cfg.Version, HomeHost: (*wire.MachineRef)(settings.HomeHost),
		MachineID: settings.MachineID, StartedAt: new(dateOf(m.s.started)), Port: new(int64(m.s.cfg.Port)),
		You: optional(wire.UUID(from.Client)), Person: m.me(from)}
	if command := m.s.joinCommand(m.callerPerson(from)); command != "" {
		status.JoinCommand = &command
	}
	m.mu.Lock()
	status.Web = m.web
	m.mu.Unlock()
	if m.s.page != nil {
		status.PublicWeb = new(m.s.page.Address())
		if views := m.s.page.ViewsOrigin(); views != "" {
			status.PublicViews = new(views)
		}
	}
	status.ThisMacHost = m.s.thisMacHost()
	if m.s.tunnels != nil {
		status.UnjoinedTunnels = m.s.tunnels.Unjoined()
		if len(status.UnjoinedTunnels) == 0 {
			status.UnjoinedTunnels = nil
		}
	}
	// As control.json has it, read as Swift's ControlStatus reads it; the standard where
	// it has none.
	detection := standardDetection
	if len(settings.FolderDetection) > 0 {
		var kept wire.FolderDetection
		if json.Unmarshal(settings.FolderDetection, &kept) == nil {
			detection = kept
		}
	}
	status.FolderDetection = &detection
	needed := requiredNow(m.router.Team())
	status.Capabilities, status.Required = capabilities(), &needed
	away := false
	status.AwayFromHome = &away
	for _, h := range m.records.Hosts() {
		// A relay host is what takes devices out of the house (T096): the person's own.
		if h.Relay != nil && *h.Relay && m.owns(from, h.ID) {
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

// hostList is the caller's own machines (#994): another's are in People, by name and
// state only.
func (m *Methods) hostList(from Caller) []wire.ControlMachine {
	out := []wire.ControlMachine{}
	for _, h := range m.records.Hosts() {
		if m.owns(from, h.ID) {
			out = append(out, m.hostRow(h))
		}
	}
	return out
}

// removeHost takes a machine off the control plane: hosts/remove, or with its person.
func (m *Methods) removeHost(ctx context.Context, host string, from Caller) (bool, error) {
	owner, name := m.s.ownerOf(host), host
	var held []wire.OrgRouteVersion
	if h := m.records.Host(host); h != nil {
		if h.Name != "" {
			name = h.Name
		}
		held = appliedOrgRoutes(*h)
	}
	gone, err := m.records.RemoveHost(ctx, host)
	if err != nil || !gone {
		return gone, err
	}
	// No more secrets go to it, and its person hears which it had (FR-026); its person
	// and the admins hear which org routes it held (#999).
	defer m.s.machineLeft(host, owner, name)
	defer m.s.orgRoutesLeft(host, owner, name, held)
	m.router.ForgetHost(host)
	m.s.copies.forget(host)
	// What it said it had from a catalogue (#2019, M5).
	_ = m.s.cfg.Store.Delete(ctx, governanceHostKey(host))
	if m.s.providers != nil && m.s.providers.Kept() != nil {
		m.s.providers.Kept().Forget(host)
	}
	m.s.announce("hostRemoved", host, from.Client)
	m.s.log("host " + host + " removed")
	return true, nil
}

// hostRow is one hosts/list row, as it stands now.
func (m *Methods) hostRow(h records.MachineRecord) wire.ControlMachine {
	state, _ := m.router.Described(h.ID)["state"].(string)
	row := wire.ControlMachine{ID: wire.MachineRef(h.ID), Name: h.Name, Platform: h.Platform, Version: h.Version, State: state,
		Reach: "dialOut", MachineID: h.MachineID, Relay: h.Relay, SignInFrom: hostIDs(m.sameUsers(h.ID, h.SignInFrom)),
		GitFrom: hostIDs(m.sameUsers(h.ID, h.GitFrom)),
		Owner:   optional(m.s.ownerOf(h.ID))}
	if raw, ok := h.Extra["implementation"]; ok {
		var impl string
		json.Unmarshal(raw, &impl)
		row.Implementation = optional(impl)
	}
	if list := hostCapabilities(h); list != nil {
		row.Capabilities, row.Missing = list, wire.Missing(list, requiredNow(m.router.Team()).Host)
	} else if m.router.Team() {
		row.Missing = []string{wire.CapHostTeam1}
	}
	m.mu.Lock()
	for server, ask := range m.gitAsks[h.ID] {
		row.GitAsks = append(row.GitAsks, wire.GitAsk{Server: server, From: wire.MachineRef(ask.from)})
	}
	m.mu.Unlock()
	sort.Slice(row.GitAsks, func(i, j int) bool { return row.GitAsks[i].Server < row.GitAsks[j].Server })
	row.Workspace = m.router.Workspace(h.ID)
	if m.s.tunnels != nil {
		row.Tunnel = m.s.tunnels.State(h.ID)
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
		m.s.tellHostClients()
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
		go m.s.tellHostClients()
	}
	return nil
}

func (m *Methods) admitOnce(ctx context.Context, client records.ClientRecord) (bool, error) {
	if m.records.Client(client.ID) != nil {
		renamed := false
		err := m.records.ChangeClient(ctx, client.ID, func(known *records.ClientRecord) bool {
			// Paired again after its key expired (#997): the new pairing's key and life.
			if client.Expires != nil && keyExpired(known.Expires, time.Now()) {
				known.PublicKey, known.Paired, known.Expires, known.Owner = client.PublicKey, client.Paired, client.Expires, client.Owner
				known.Name = client.Name
				renamed = true
				return true
			}
			stale := known.LastSeen == nil || time.Since(known.LastSeen.Time) > time.Hour
			renamed = known.Name != client.Name
			if !stale && !renamed {
				return false
			}
			now := records.Now()
			known.LastSeen = &now
			known.Name = client.Name
			return true
		})
		return renamed, err
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
		m.records.ChangeClient(ctx, id.ID, func(c *records.ClientRecord) bool {
			if c.KnownEpoch != nil && *c.KnownEpoch == epoch {
				return false
			}
			c.KnownEpoch = &epoch
			return true
		})
	case 'h':
		m.records.ChangeHost(ctx, id.ID, func(h *records.MachineRecord) bool {
			if h.KnownEpoch != nil && *h.KnownEpoch == epoch {
				return false
			}
			h.KnownEpoch = &epoch
			return true
		})
	}
}

// setPushToken is clients/setPushToken (#1460): a device's own APNs token, kept in its
// own record. Only the device itself sets it, over its own session: there is no client
// to name. A window or a browser has nothing to push to.
func (m *Methods) setPushToken(ctx context.Context, client string, request wire.PushToken) error {
	var token *records.PushToken
	if request.Token != nil && *request.Token != "" {
		hex := strings.ToLower(*request.Token)
		if !apns.ValidToken(hex) {
			return fail(invalidParams, "That is not a push token.")
		}
		if request.Environment != wire.PushEnvironmentDevelopment && request.Environment != wire.PushEnvironmentProduction {
			return fail(invalidParams, "A push token is from development or production.")
		}
		token = &records.PushToken{Token: hex, Environment: string(request.Environment)}
	}
	for try := 0; ; try++ {
		record := m.records.Client(client)
		if record == nil {
			return fail(invalidParams, "This client is not paired.")
		}
		if !record.IsDevice() {
			return fail(notSupported, "Only an iPhone or an iPad gets pushes.")
		}
		if samePushToken(record.PushToken, token) {
			return nil
		}
		err := m.records.ChangeClient(ctx, client, func(c *records.ClientRecord) bool {
			c.PushToken = token
			return true
		})
		var conflict *store.ConflictError
		if !errors.As(err, &conflict) || try > 0 {
			return err
		}
		// Another copy wrote it first: read it again and try once more.
		if err := m.records.Load(ctx); err != nil {
			return err
		}
	}
}

// setActivityToken is clients/setActivityToken (#1744): the push token of one session's
// Live Activity on the device, kept in its own record beside its APNs token, as only it
// may set. A new token for the session takes the old one's place; no token takes it away.
// Those older than an activity lives, and the oldest past MostActivityTokens, go.
func (m *Methods) setActivityToken(ctx context.Context, client string, request wire.ActivityToken) error {
	agent := strings.ToUpper(string(request.AgentID))
	if !records.IsUUID(agent) {
		return fail(invalidParams, "That is not a session.")
	}
	var token *records.ActivityToken
	if request.Token != nil && *request.Token != "" {
		hex := strings.ToLower(*request.Token)
		if !apns.ValidToken(hex) {
			return fail(invalidParams, "That is not a push token.")
		}
		if request.Environment != wire.PushEnvironmentDevelopment && request.Environment != wire.PushEnvironmentProduction {
			return fail(invalidParams, "A push token is from development or production.")
		}
		token = &records.ActivityToken{Agent: agent, Token: hex, Environment: string(request.Environment),
			StartedAt: request.StartedAt, SetAt: records.Now()}
	}
	for try := 0; ; try++ {
		record := m.records.Client(client)
		if record == nil {
			return fail(invalidParams, "This client is not paired.")
		}
		if !record.IsDevice() {
			return fail(notSupported, "Only an iPhone or an iPad shows Live Activities.")
		}
		next := withActivityToken(record.ActivityTokens, agent, token, time.Now())
		if slices.Equal(next, record.ActivityTokens) {
			return nil
		}
		err := m.records.ChangeClient(ctx, client, func(c *records.ClientRecord) bool {
			c.ActivityTokens = withActivityToken(c.ActivityTokens, agent, token, time.Now())
			return true
		})
		var conflict *store.ConflictError
		if !errors.As(err, &conflict) || try > 0 {
			return err
		}
		if err := m.records.Load(ctx); err != nil {
			return err
		}
	}
}

// activityLife is the longest a Live Activity shows: eight hours, and four more ended.
const activityLife = 12 * time.Hour

// withActivityToken is the list with the session's token put last (or taken out when
// nil), and the old and the extra ones dropped.
func withActivityToken(list []records.ActivityToken, agent string, token *records.ActivityToken, now time.Time) []records.ActivityToken {
	var out []records.ActivityToken
	for _, t := range list {
		if t.Agent != agent && now.Sub(t.SetAt.Time) < activityLife {
			out = append(out, t)
		}
	}
	if token != nil {
		// The same token for the same session is not news: it keeps its first SetAt.
		for _, t := range list {
			if t.Agent == agent && t.Token == token.Token && t.Environment == token.Environment && t.StartedAt == token.StartedAt {
				token = &t
			}
		}
		out = append(out, *token)
	}
	if len(out) > records.MostActivityTokens {
		out = out[len(out)-records.MostActivityTokens:]
	}
	return out
}

func samePushToken(a, b *records.PushToken) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// setRelay is hosts/setRelay or relay/switch (#824): a relay switched on or off, keeping
// its enrolment.
func (m *Methods) setRelay(ctx context.Context, request wire.MachineRelayRequest) error {
	host := string(request.Host)
	record := m.records.Host(host)
	if record == nil {
		return fail(noSuchHost, "No machine is called %s.", host)
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
	m.router.SetRelay(host, record.Relay)
	m.s.tellRelayDevices()
	return nil
}

// startsWork is what a machine says that starts work or uses its person's access, refused
// while its person is suspended (D13). What it says to stop their work still goes. One a
// line, sorted (#2020).
var startsWork = methodSet(
	"backups/commit",
	"backups/upload",
	"git/credential",
	"links/check",
	"tunnel/open",
	"workflows/claimRun",
	"workflows/trigger",
)

func (m *Methods) HostSaid(host, method string, params json.RawMessage) (any, error) {
	ctx := context.Background()
	if startsWork[method] && m.s.suspended(m.s.ownerOf(host)) {
		return nil, fail(personSuspended, "This machine's person was suspended by their organisation.")
	}
	switch method {
	case "control/ping":
		return map[string]any{}, nil
	case "user/setAgentConfigFile":
		return nil, agentConfigFileRefused()
	case "host/hello":
		hello, err := require[wire.MachineHello](params, "MachineHello")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, m.hello(ctx, host, hello)
	case "folders/detected":
		// Once: from now on its folders are the person's to add and remove (#429).
		if record := m.records.Host(host); record != nil && record.DetectFolders != nil && *record.DetectFolders {
			record.DetectFolders = nil
			if err := m.records.SaveHost(ctx, *record); err != nil {
				return nil, err
			}
		}
		return map[string]any{}, nil
	case "relay/switch":
		// A relay host on or off by its own word (#824): only its own record.
		request, err := require[wire.RelaySwitch](params, "RelaySwitch")
		if err != nil {
			return nil, err
		}
		if err := m.setRelay(ctx, wire.MachineRelayRequest{Host: wire.MachineRef(host), Relay: request.Relay}); err != nil {
			return nil, err
		}
		m.s.announce("hostEnrolled", host, host)
		return map[string]any{}, nil
	case "attention/need":
		m.s.heard(host, params)
		return map[string]any{}, nil
	case "host/policyApplied":
		applied, err := require[wire.PolicyApplied](params, "PolicyApplied")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, m.s.policyApplied(ctx, host, applied)
	case "host/orgRoutesApplied":
		applied, err := require[wire.OrgRoutesApplied](params, "OrgRoutesApplied")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, m.s.orgRoutesApplied(ctx, host, applied)
	case "host/orgRoutesAgain":
		m.s.orgRoutesAgain(host)
		return map[string]any{}, nil
	case "attention/turn":
		turn, err := require[wire.AttentionTurn](params, "AttentionTurn")
		if err != nil {
			return nil, err
		}
		m.s.turnMoved(turn)
		return map[string]any{}, nil
	case "governance/report":
		report, err := require[wire.MachineCatalog](params, "MachineCatalog")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, m.s.keepGovernanceReport(ctx, host, report, time.Now())
	case "projects/joined":
		joined, err := require[wire.ProjectsJoined](params, "ProjectsJoined")
		if err != nil {
			return nil, err
		}
		return m.s.keepJoined(ctx, host, joined)
	case "usage/rollup":
		rollup, err := require[wire.UsageRollup](params, "UsageRollup")
		if err != nil {
			return nil, err
		}
		if err := m.s.keepRollup(ctx, host, rollup, time.Now()); err != nil {
			return nil, err
		}
		// A bot's spend against its caps (#1761, FR-033).
		if owner := m.s.ownerOf(host); m.s.isBot(owner) {
			go m.s.checkCaps(owner)
		}
		return map[string]any{}, nil
	case "workflows/claimRun":
		claim, err := require[wire.WorkflowClaim](params, "WorkflowClaim")
		if err != nil {
			return nil, err
		}
		return m.s.claimRun(ctx, host, claim, time.Now())
	case "workflows/trigger":
		// A team event, sent once by the control plane (#2011, FR-035).
		trigger, err := require[wire.TeamTrigger](params, "TeamTrigger")
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(trigger.Workflow) == "" || strings.TrimSpace(trigger.Trigger) == "" {
			return nil, fail(invalidParams, "Say the workflow and the trigger.")
		}
		return m.s.teamTrigger(ctx, host, trigger, time.Now())
	case "links/check":
		// May a channel message start work (#1762, FR-037)?
		sender, err := require[wire.ChannelSender](params, "ChannelSender")
		if err != nil {
			return nil, err
		}
		return m.s.links.check(ctx, sender)
	case "host/machines", "host/providerDraft", "host/status":
		if m.s.providers == nil {
			if method == "host/status" {
				return map[string]any{}, nil
			}
			return nil, fail(providersNeedOneCopy, "Machine providers need a control plane with one copy, for now.")
		}
		return m.s.providers.HostSaid(host, method, params)
	case "backups/stored", "backups/upload", "backups/commit", "backups/download":
		m.mu.Lock()
		frozen := m.frozen
		m.mu.Unlock()
		if frozen && (method == "backups/upload" || method == "backups/commit") {
			return nil, fail(storeUnavailable, "The control plane is moving to another machine. Back up again in a minute.")
		}
		return m.s.backups.said(method, host, params)
	case "git/credential":
		request, err := require[wire.GitCredentialRequest](params, "GitCredentialRequest")
		if err != nil {
			return nil, err
		}
		return m.gitCredential(ctx, host, request)
	case "tunnel/open":
		// Only to a lender a person said yes to, for that runtime (T091).
		request, err := require[wire.TunnelOpen](params, "TunnelOpen")
		if err != nil {
			return nil, err
		}
		if record := m.records.Host(host); record == nil || record.SignInFrom[request.Runtime] == "" {
			m.records.Load(ctx)
		}
		record := m.records.Host(host)
		if record == nil || record.SignInFrom[request.Runtime] == "" || !m.sameUser(host, record.SignInFrom[request.Runtime]) {
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
func (m *Methods) hello(ctx context.Context, host string, hello wire.MachineHello) error {
	known := m.records.Host(host)
	said := func(record *records.MachineRecord) {
		record.Version = hello.Version
		record.Platform = hello.Platform
		mid := hello.MachineID
		record.MachineID = &mid
		if hello.Name != nil {
			record.Name = *hello.Name
		}
		// Which language the host is written in (#1134), kept beside the record's own fields
		// so a Swift copy keeps it too.
		if deref(hello.Implementation) != "" {
			impl, _ := json.Marshal(*hello.Implementation)
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
		*record = withCapabilities(*record, hello.Capabilities)
	}
	// Whether a host relays is settled when it enrols and changed only by a person
	// (hosts/setRelay). A host's own hello never makes it a relay (T102).
	changed := known == nil
	if known == nil {
		record := records.MachineRecord{ID: host, Name: host}
		said(&record)
		if err := m.records.SaveHost(ctx, record); err != nil {
			return err
		}
	} else {
		// Changed on the record as it is when written: a connect noting its epoch at the
		// same moment is kept (#1763).
		err := m.records.ChangeHost(ctx, host, func(record *records.MachineRecord) bool {
			before := *record
			said(record)
			changed = !sameHost(before, *record)
			return changed
		})
		if err != nil {
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
	// A suspended person's machine that cannot stop their work is refused (#1002, FR-018).
	if err := m.s.refuseSuspendedHost(host, hello.Capabilities); err != nil {
		return err
	}
	m.noteCapabilities(host, hello.Capabilities, hello.Version)
	if changed {
		m.router.BroadcastHost(host, "control/hostChanged", m.router.Described(host))
	}
	if r := m.records.Host(host); r != nil && r.Relay != nil && *r.Relay {
		m.s.tellRelayDevices()
	} else {
		m.s.tellHostClients(host)
	}
	// Whether its person is suspended, before anything they set (#1002, FR-018).
	m.s.sendUserSuspended(host)
	// Its person's settings and secrets, at every join (#1760, FR-024).
	go m.s.sendUserSettings(host, true)
	// The organisation's policy, or none, at every join (#998, FR-006).
	go m.s.sendPolicy(host, true)
	// The organisation's routes it may use, or none, at every join (#999, FR-005).
	go m.s.sendOrgRoutes(host, true)
	// The release it names, for a Mac's Agents Host to update itself to (#2178).
	go m.s.sendRelease(host)
	// Its user, their kind and labels (#1761); a bot's cap is weighed again.
	go func() {
		m.s.sendHostUser(host)
		if owner := m.s.ownerOf(host); m.s.isBot(owner) {
			m.s.checkCaps(owner)
			// What waited for a bot's machine (#2011, FR-034).
			m.s.botMachineJoined(host)
		}
	}()
	// A host marked before #656 to add the folders it found: the mark goes, unsaid.
	m.records.ChangeHost(ctx, host, func(r *records.MachineRecord) bool {
		if r.DetectFolders == nil || !*r.DetectFolders {
			return false
		}
		r.DetectFolders = nil
		return true
	})
	return nil
}

func sameHost(a, b records.MachineRecord) bool {
	x, _ := records.Encode(a)
	y, _ := records.Encode(b)
	return string(x) == string(y)
}

// MARK: Git access lent between hosts (#1122)

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

// sameUser says two machines belong to the same user: only such a pair lends a sign-in or
// git access (FR-021).
func (m *Methods) sameUser(a, b string) bool { return m.s.ownerOf(a) == m.s.ownerOf(b) }

// sameUsers is a host's lends of only its own user's machines: one made before the team
// tier by another user's machine is not shown, nor used (FR-021).
func (m *Methods) sameUsers(host string, lends map[string]string) map[string]string {
	if lends == nil {
		return nil
	}
	out := map[string]string{}
	for k, lender := range lends {
		if m.sameUser(host, lender) {
			out[k] = lender
		}
	}
	return out
}

// lendGit is hosts/lendGit: kept for a yes, taken back for a no; either ends a waiting ask.
func (m *Methods) lendGit(ctx context.Context, request wire.LendGit) error {
	if !isGitServer(request.Server) {
		return fail(invalidParams, "That is not a git server.")
	}
	host := string(request.Host)
	record := m.records.Host(host)
	if record == nil || m.records.Host(string(request.From)) == nil || !m.sameUser(host, string(request.From)) {
		return fail(noSuchHost, "No such host.")
	}
	lends := map[string]string{}
	for k, v := range record.GitFrom {
		lends[k] = v
	}
	if request.Allowed {
		lends[request.Server] = string(request.From)
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
	asked := m.gitAsks[host][request.Server]
	delete(m.gitAsks[host], request.Server)
	m.mu.Unlock()
	if asked != nil {
		for _, w := range asked.waiting {
			w <- request.Allowed
		}
	}
	m.sayHostChanged(host)
	return nil
}

// gitCredential is git/credential from a host's git: the lent credential, asked of the
// lender only for a lend a person allowed. With none yet, every client is asked, and the
// command waits for the answer. It fails at once while the lender is not connected.
func (m *Methods) gitCredential(ctx context.Context, host string, request wire.GitCredentialRequest) (json.RawMessage, error) {
	if request.Protocol != "https" || !isGitServer(request.Host) {
		return nil, fail(invalidParams, "Only https git access is lent.")
	}
	server := request.Host
	record := m.records.Host(host)
	if record == nil {
		return nil, fail(noSuchHost, "No such host.")
	}
	lender := record.GitFrom[server]
	if lender != "" && !m.sameUser(host, lender) {
		// Lent before the team tier by another user's machine: never theirs to use (FR-021).
		lender = ""
	}
	if lender == "" {
		mac := m.gitLender(host)
		if mac == "" {
			return nil, fail(hostOffline, "No Mac is connected to lend its git access for %s; it is lent only while that Mac is connected.", server)
		}
		if !m.askToLendGit(host, mac, server) {
			return nil, fail(notPermitted, "%s may not use the git access of %s for %s.", record.Name, m.name(mac), server)
		}
		if r := m.records.Host(host); r != nil && m.sameUser(host, r.GitFrom[server]) {
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
		var credential wire.GitCredential
		if json.Unmarshal(answer.Result, &credential) == nil && credential.Password != "" {
			return answer.Result, nil
		}
	}
	return nil, fail(notPermitted, "%s has no git access to %s.", lenderName, server)
}

// gitLender is the Mac whose git access a host would use: the home host if it is a Mac,
// else the first connected Mac. Never the host itself, never a relay, and only a Mac of
// the host's own user (FR-021).
func (m *Methods) gitLender(host string) string {
	var macs []string
	for _, r := range m.records.Hosts() {
		if r.ID == host || r.Relay != nil || !strings.HasPrefix(r.Platform, "macOS") || !m.sameUser(host, r.ID) {
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
		m.router.BroadcastHost(host, "control/hostChanged", m.router.Described(host))
	}
}

// readJoinFile is HostJoinFile.read: how this Mac's host's join stands, from its root's
// control-join.json, while the process that wrote it lives.
func readJoinFile(file string) *MachineJoinStatus {
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
	return &MachineJoinStatus{Member: read.Status.Member, Connected: read.Status.Connected, Problem: read.Status.Problem,
		At: dateOf(read.Status.At)}
}
