// Package providers is machine providers on the control plane (#691, #858): MCP servers
// that start and stop the machines hosts run on, the prompts kept for a stopped one, and
// Write It for Me. It ports ControlPlaneKit/Providers and the wire types in
// AgentsKitCore/Control (Workspaces.swift, WorkspaceTools.swift, KeptWire.swift,
// ProviderDraftAPI.swift).
//
// Records stay where Swift keeps them: providers at v1/providers/<id>.json, kept requests at
// v1/kept/<host>/<seq>.json, a host's link in its own record, and secrets in
// provider-secrets.json in the control plane's home. Either language reads what the other
// wrote.
package providers

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Error codes: JSONRPCError's and DaemonAPI.Failure's.
const (
	CodeInvalidParams        = -32602
	CodeMethodNotFound       = -32601
	CodeInternalError        = -32603
	CodeNotSupported         = -32009
	CodeNotPermitted         = -32045
	CodeProvidersNeedOneCopy = -32064
	CodeNotLinked            = -32065
	CodeProviderFailed       = -32066
	CodeKept                 = -32067
	CodeAgentsWorking        = -32068
	CodeHostOffline          = -32090
	CodeNoSuchHost           = -32091
	CodeStoreUnavailable     = -32094
)

// Failure is JSONRPCError: what a client is told, with Swift's code and words.
type Failure struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (f *Failure) Error() string { return f.Message }

func fail(code int, format string, args ...any) *Failure {
	return &Failure{Code: code, Message: fmt.Sprintf(format, args...)}
}

func invalid(format string, args ...any) *Failure { return fail(CodeInvalidParams, format, args...) }

// methodNotFound is JSONRPCError.methodNotFound.
func methodNotFound(method string) *Failure {
	data, _ := json.Marshal(map[string]string{"method": method})
	return &Failure{Code: CodeMethodNotFound, Message: "Method not found", Data: data}
}

// ProviderFailure is ProviderFailure: a provider's failure, in words for the strip and the
// Providers page.
type ProviderFailure struct{ Words string }

func (f *ProviderFailure) Error() string { return f.Words }

func providerFailure(format string, args ...any) *ProviderFailure {
	return &ProviderFailure{fmt.Sprintf(format, args...)}
}

// Caller is ControlRouter.Caller: the client session that asked.
type Caller struct {
	Session string
	Client  string
	// ClientRecord.Kind: mac, iPhone, iPad, browser or unknown.
	Kind string
	// The person the client belongs to (#994).
	Person string
}

// dateOf is a time on the wire: seconds since 2001-01-01, as ControlRouter's dates were
// written before the generated types (#1313), so no byte moves.
func dateOf(t time.Time) *wire.Date {
	d := wire.Date(float64(t.UnixNano()-referenceDate*int64(time.Second)) / 1e9)
	return &d
}

// referenceDate is 2001-01-01T00:00:00Z in Unix seconds.
const referenceDate = 978307200

// deref is what p points at, or T's zero.
func deref[T any](p *T) T {
	if p == nil {
		var zero T
		return zero
	}
	return *p
}

// optional is v, or nil for T's zero: what an omitempty field said before (#1313).
func optional[T comparable](v T) *T {
	var zero T
	if v == zero {
		return nil
	}
	return &v
}

// Method names (DaemonAPI.Method).
const (
	MethodProvidersList     = "providers/list"
	MethodProvidersAdd      = "providers/add"
	MethodProvidersUpdate   = "providers/update"
	MethodProvidersRemove   = "providers/remove"
	MethodProvidersRefresh  = "providers/refresh"
	MethodProvidersOptions  = "providers/options"
	MethodProvidersCreate   = "providers/create"
	MethodProvidersRuntimes = "providers/runtimes"
	MethodDraftStart        = "providers/draftStart"
	MethodDraftCancel       = "providers/draftCancel"
	MethodDraftAnswer       = "providers/draftAnswer"
	MethodHostsLink         = "hosts/link"
	MethodHostsUnlink       = "hosts/unlink"
	MethodHostsSetOptions   = "hosts/setMachineOptions"
	MethodHostsStart        = "hosts/start"
	MethodHostsStop         = "hosts/stop"
	MethodHostsDelete       = "hosts/deleteMachine"
	MethodHostsKeep         = "hosts/keep"
	MethodHostsListKept     = "hosts/listKept"
	MethodHostsDropKept     = "hosts/dropKept"
	MethodHostsRetryKept    = "hosts/retryKept"
	MethodWorkspacesAgent   = "machines/forAgent"
	MethodSessionOnMachine  = "machines/startSession"
	MethodSessionCall       = "machines/sessionCall"
	MethodSessionEnded      = "machines/sessionEnded"
	MethodHostMachines      = "host/machines"
	MethodHostProviderDraft = "host/providerDraft"
	MethodHostStatus        = "host/status"
	MethodAgentsPrompt      = "agents/prompt"
	MethodAgentsStart       = "agents/start"
	MethodAgentsStop        = "agents/stop"
	MethodAgentsFromStarter = "agents/fromStarter"
	MethodAgentsEndedThere  = "agents/endedElsewhere"
	MethodFoldersClone      = "folders/clone"
)

// Notification names (DaemonAPI.Notification).
const (
	NoticeProvidersChanged = "control/providersChanged"
	NoticeKeptChanged      = "control/keptChanged"
	NoticeKeptDelivered    = "control/keptDelivered"
	NoticeProviderDraft    = "control/providerDraft"
)

// WorkspaceMethods is DaemonAPI.Method.workspaceMethods: every method Answer answers.
var WorkspaceMethods = map[string]bool{
	MethodProvidersList: true, MethodProvidersAdd: true, MethodProvidersUpdate: true, MethodProvidersRemove: true,
	MethodProvidersRefresh: true, MethodHostsLink: true, MethodHostsUnlink: true, MethodHostsSetOptions: true,
	MethodHostsStart: true, MethodHostsStop: true, MethodHostsKeep: true, MethodHostsListKept: true,
	MethodHostsDropKept: true, MethodHostsRetryKept: true, MethodProvidersOptions: true, MethodProvidersCreate: true,
	MethodHostsDelete: true, MethodDraftStart: true, MethodDraftCancel: true, MethodDraftAnswer: true,
	MethodProvidersRuntimes: true,
}

// AgentWorkspaceMethods is DaemonAPI.Method.agentWorkspaceMethods: what an agent may ask
// through host/machines.
var AgentWorkspaceMethods = map[string]bool{
	MethodWorkspacesAgent: true, MethodHostsStart: true, MethodHostsStop: true, MethodProvidersOptions: true,
	MethodProvidersCreate: true, MethodHostsDelete: true, MethodSessionOnMachine: true, MethodSessionCall: true,
	MethodSessionEnded: true,
}

// KeptMethods is DaemonAPI.Method.keptMethods: the only requests that are kept.
var KeptMethods = map[string]bool{MethodAgentsPrompt: true, MethodAgentsStart: true}

// MakeProviderID is ProviderID.make: a slug of the name and four random characters,
// digitalocean-x7k2.
func MakeProviderID(name string) string {
	var mapped strings.Builder
	for _, r := range strings.ToLower(name) {
		if r < 128 && (r >= 'a' && r <= 'z' || r >= '0' && r <= '9') {
			mapped.WriteRune(r)
		} else {
			mapped.WriteByte('-')
		}
	}
	var parts []string
	for _, p := range strings.Split(mapped.String(), "-") {
		if p != "" {
			parts = append(parts, p)
		}
	}
	head := strings.Join(parts, "-")
	if len(head) > 24 {
		head = head[:24]
	}
	if head == "" {
		head = "provider"
	}
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 4)
	rand.Read(b)
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return head + "-" + string(b)
}

// MachineInfo is DaemonAPI.MachineInfo: one workspace, as its provider last listed it.
// State is running, starting, stopping, stopped or unknown; Host, in providers/list, the
// host it is linked to.
type MachineInfo = wire.MachineInfo

// MayBe is MachineInfo.mayBe(hostNamed:) (#976): whether a host added by hand may be
// this workspace.
func MayBe(w MachineInfo, hostName string) bool {
	host := strings.ToLower(hostName)
	if w.SSH != nil && *w.SSH != "" && strings.ToLower(*w.SSH) == host {
		return true
	}
	name := strings.ToLower(w.Name)
	if name == "" {
		return false
	}
	if host == name {
		return true
	}
	return strings.Contains("."+host+".", "."+name+".")
}

// ProviderSummary is DaemonAPI.ProviderSummary: a provider for the Providers page, never
// its commands, headers or secrets' values.
type ProviderSummary = wire.ProviderSummary

// MachineWorkspace is DaemonAPI.MachineWorkspace: a linked host's workspace, on its hosts/list
// row and in control/hostChanged. HostState is stopped, starting or stopping: shown over
// the uplink's own state while it is not online, and stopping always. Phase, while
// starting, is provider, connecting or sshStart.
type MachineWorkspace = wire.MachineWorkspace

// Overlay is ControlRouter.described's part for workspaces: a host's description as
// hosts/list and control/hostChanged say it, with its workspace laid over it. The
// workspace's hostState names the state while the host is not online, and stopping
// whatever it is.
func Overlay(described map[string]any, online bool, ws *MachineWorkspace) map[string]any {
	if ws == nil {
		return described
	}
	out := make(map[string]any, len(described)+1)
	for k, v := range described {
		out[k] = v
	}
	if state := deref(ws.HostState); state != "" && (state == "stopping" || !online) {
		out["state"] = state
	}
	out["workspace"] = ws
	return out
}

// OfflineRefusal is ControlRouter.offlineRefusal: what a request for a host that is not
// up is answered with. A host whose workspace is stopped says so (FR-022).
func OfflineRefusal(ws *MachineWorkspace) *Failure {
	if ws != nil && deref(ws.HostState) == "stopped" {
		return fail(CodeHostOffline, "That machine is stopped. Start it to reach it.")
	}
	return fail(CodeHostOffline, "That machine is offline.")
}

// ProviderAdd is DaemonAPI.ProviderAdd: providers/add and providers/update. Secrets, name
// to value, only ever go to the control plane and are never given back; CLI, the program
// Your commands use, for Write It for Me, is not kept; Draft is the draft this accepts
// (#858).
type ProviderAdd = wire.ProviderAdd

type providerRequest = wire.ProviderRequest

type hostRequest = wire.MachineRequest

// MachineLink is DaemonAPI.MachineLink: hosts/link.
type MachineLink = wire.MachineLink

// MachineOptions is DaemonAPI.MachineOptions. stopWhenIdleMinutes 0 turns it off.
type MachineOptions = wire.MachineOptions

// ProviderOptions is DaemonAPI.ProviderOptions: the New Machine form, a JSON Schema.
type ProviderOptions = wire.ProviderOptions

// ProviderCreate is DaemonAPI.ProviderCreate: providers/create.
type ProviderCreate = wire.ProviderCreate

// ProviderCreated is DaemonAPI.ProviderCreated: what providers/create made.
type ProviderCreated = wire.ProviderCreated

// MachineStop is DaemonAPI.MachineStop: hosts/stop.
type MachineStop = wire.MachineStop

// MachineWorkspaceCall is DaemonAPI.MachineWorkspaceCall: host/machines, for an agent there.
// Agent is who asked, for the log: "Claude (fix-login)".
type MachineWorkspaceCall = wire.MachineWorkspaceCall

// AgentMachines is DaemonAPI.AgentMachines: what list_machines shows an agent.
type AgentMachines = wire.AgentMachines

// AgentProvider is DaemonAPI.AgentMachines.Provider.
type AgentProvider = wire.AgentMachinesProvider

// AgentWorkspace is DaemonAPI.AgentMachines.Workspace.
type AgentWorkspace = wire.AgentMachinesMachine

// AgentHost is AgentMachinesHost: one of the person's machines, for start_session (#2887).
type AgentHost = wire.AgentMachinesHost

// MachineStatus is DaemonAPI.MachineStatus: host/status on channel 0 (#691 US4). Running is
// "Claude (fix-login)" for each agent working or waiting on a person; Schedule is nil from
// a host from before #1004, and empty when nothing is scheduled.
type MachineStatus = wire.MachineStatus

// MachineSchedule is DaemonAPI.MachineSchedule: a host's next scheduled workflow (#1004).
type MachineSchedule = wire.MachineSchedule

func schedule(s *MachineSchedule) *Schedule {
	if s == nil {
		return nil
	}
	out := &Schedule{Workflow: deref(s.Workflow)}
	if s.At != nil {
		t := s.At.Time()
		out.At = &t
	}
	return out
}

// Reply is a host's answer to a request the router delivered for the control plane.
type Reply struct {
	Result json.RawMessage
	// The host's refusal, when it said no.
	Error *Failure
}

// jsonValue is v as JSON, or nil for nil: an `any` field's omitempty (#1313).
func jsonValue(v any) wire.JSONValue {
	if v == nil {
		return nil
	}
	return rawOf(v)
}

// valueOf is JSON as a generic value, numbers kept as written, or nil for none.
func valueOf(j wire.JSONValue) any {
	if len(j) == 0 {
		return nil
	}
	var v any
	if decodeJSON(j, &v) != nil {
		return nil
	}
	return v
}

// intOf and int64Of move a count between a record's int and the wire's int64.
func intOf(n *int64) *int {
	if n == nil {
		return nil
	}
	return new(int(*n))
}

func int64Of(n *int) *int64 {
	if n == nil {
		return nil
	}
	return new(int64(*n))
}
