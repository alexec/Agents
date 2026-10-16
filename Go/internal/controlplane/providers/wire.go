// Package providers is workspace providers on the control plane (#691, #858): MCP servers
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
}

// RefDate is a date on the wire, as Swift's default JSONEncoder writes it: seconds since
// 2001-01-01.
type RefDate time.Time

const referenceDate = 978307200

func (d RefDate) MarshalJSON() ([]byte, error) {
	return json.Marshal(float64(time.Time(d).UnixNano()-referenceDate*int64(time.Second)) / 1e9)
}

func (d *RefDate) UnmarshalJSON(b []byte) error {
	var seconds float64
	if err := json.Unmarshal(b, &seconds); err != nil {
		return err
	}
	*d = RefDate(time.Unix(referenceDate, 0).Add(time.Duration(seconds * float64(time.Second))))
	return nil
}

func refDate(t time.Time) *RefDate {
	d := RefDate(t)
	return &d
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
	MethodHostsSetOptions   = "hosts/setWorkspaceOptions"
	MethodHostsStart        = "hosts/start"
	MethodHostsStop         = "hosts/stop"
	MethodHostsDelete       = "hosts/deleteWorkspace"
	MethodHostsKeep         = "hosts/keep"
	MethodHostsListKept     = "hosts/listKept"
	MethodHostsDropKept     = "hosts/dropKept"
	MethodHostsRetryKept    = "hosts/retryKept"
	MethodWorkspacesAgent   = "workspaces/forAgent"
	MethodHostWorkspaces    = "host/workspaces"
	MethodHostProviderDraft = "host/providerDraft"
	MethodHostStatus        = "host/status"
	MethodAgentsPrompt      = "agents/prompt"
	MethodAgentsStart       = "agents/start"
	MethodAgentsStop        = "agents/stop"
	MethodProjectsClone     = "projects/clone"
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
// through host/workspaces.
var AgentWorkspaceMethods = map[string]bool{
	MethodWorkspacesAgent: true, MethodHostsStart: true, MethodHostsStop: true, MethodProvidersOptions: true,
	MethodProvidersCreate: true, MethodHostsDelete: true,
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

// WorkspaceInfo is DaemonAPI.WorkspaceInfo: one workspace, as its provider last listed it.
type WorkspaceInfo struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// running, starting, stopping, stopped or unknown.
	State  string `json:"state"`
	SSH    string `json:"ssh,omitempty"`
	Tunnel *bool  `json:"tunnel,omitempty"`
	Cost   string `json:"cost,omitempty"`
	// The host it is linked to, in providers/list.
	Host string `json:"host,omitempty"`
}

// MayBe is WorkspaceInfo.mayBe(hostNamed:) (#976): whether a host added by hand may be
// this workspace.
func (w WorkspaceInfo) MayBe(hostName string) bool {
	host := strings.ToLower(hostName)
	if w.SSH != "" && strings.ToLower(w.SSH) == host {
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
type ProviderSummary struct {
	ID           string          `json:"id"`
	Name         string          `json:"name"`
	Kind         string          `json:"kind"`
	Secrets      map[string]bool `json:"secrets"`
	Capabilities []string        `json:"capabilities"`
	Contract     int             `json:"contract"`
	Mapped       bool            `json:"mapped"`
	Preset       string          `json:"preset,omitempty"`
	Workspaces   []WorkspaceInfo `json:"workspaces"`
	ListedAt     *RefDate        `json:"listedAt,omitempty"`
	Current      bool            `json:"current"`
	Problem      string          `json:"problem,omitempty"`
}

// HostWorkspace is DaemonAPI.HostWorkspace: a linked host's workspace, on its hosts/list
// row and in control/hostChanged.
type HostWorkspace struct {
	Provider       string `json:"provider"`
	ProviderName   string `json:"providerName"`
	Workspace      string `json:"workspace"`
	WorkspaceName  string `json:"workspaceName"`
	WorkspaceState string `json:"workspaceState"`
	// stopped, starting or stopping: shown over the uplink's own state while it is not
	// online, and stopping always.
	HostState string `json:"hostState,omitempty"`
	// While starting: provider, connecting or sshStart.
	Phase               string   `json:"phase,omitempty"`
	Since               *RefDate `json:"since,omitempty"`
	Problem             string   `json:"problem,omitempty"`
	StoppedBy           string   `json:"stoppedBy,omitempty"`
	CanStart            bool     `json:"canStart"`
	CanStop             bool     `json:"canStop"`
	StartWhenUsed       bool     `json:"startWhenUsed"`
	StopWhenIdleMinutes *int     `json:"stopWhenIdleMinutes,omitempty"`
	Cost                string   `json:"cost,omitempty"`
	Current             bool     `json:"current"`
	StartForSchedules   *bool    `json:"startForSchedules,omitempty"`
	TellsSchedule       *bool    `json:"tellsSchedule,omitempty"`
	NextWorkflow        string   `json:"nextWorkflow,omitempty"`
	NextWorkflowAt      *RefDate `json:"nextWorkflowAt,omitempty"`
	WakeAt              *RefDate `json:"wakeAt,omitempty"`
}

// Overlay is ControlRouter.described's part for workspaces: a host's description as
// hosts/list and control/hostChanged say it, with its workspace laid over it. The
// workspace's hostState names the state while the host is not online, and stopping
// whatever it is.
func Overlay(described map[string]any, online bool, ws *HostWorkspace) map[string]any {
	if ws == nil {
		return described
	}
	out := make(map[string]any, len(described)+1)
	for k, v := range described {
		out[k] = v
	}
	if ws.HostState != "" && (ws.HostState == "stopping" || !online) {
		out["state"] = ws.HostState
	}
	out["workspace"] = ws
	return out
}

// OfflineRefusal is ControlRouter.offlineRefusal: what a request for a host that is not
// up is answered with. A host whose workspace is stopped says so (FR-022).
func OfflineRefusal(ws *HostWorkspace) *Failure {
	if ws != nil && ws.HostState == "stopped" {
		return fail(CodeHostOffline, "That host is stopped. Start it to reach it.")
	}
	return fail(CodeHostOffline, "That host is offline.")
}

// ProviderAdd is DaemonAPI.ProviderAdd: providers/add and providers/update.
type ProviderAdd struct {
	ID       string            `json:"id,omitempty"`
	Name     string            `json:"name"`
	Kind     string            `json:"kind"`
	Command  *string           `json:"command,omitempty"`
	Args     []string          `json:"args,omitempty"`
	URL      *string           `json:"url,omitempty"`
	Headers  map[string]string `json:"headers,omitempty"`
	Commands any               `json:"commands,omitempty"`
	Map      any               `json:"map,omitempty"`
	// Name to value. Only ever sent to the control plane; never given back.
	Secrets map[string]string `json:"secrets,omitempty"`
	// Your commands: the program its commands use, for Write It for Me. Not kept.
	CLI *string `json:"cli,omitempty"`
	// The draft this accepts (#858).
	Draft string `json:"draft,omitempty"`
}

type providerRequest struct {
	ID string `json:"id,omitempty"`
}

type hostRequest struct {
	Host string `json:"host"`
}

// HostLink is DaemonAPI.HostLink: hosts/link.
type HostLink struct {
	Host                string `json:"host"`
	Provider            string `json:"provider"`
	Workspace           string `json:"workspace"`
	StartWhenUsed       *bool  `json:"startWhenUsed,omitempty"`
	StopWhenIdleMinutes *int   `json:"stopWhenIdleMinutes,omitempty"`
}

// HostWorkspaceOptions is DaemonAPI.HostWorkspaceOptions. stopWhenIdleMinutes 0 turns it off.
type HostWorkspaceOptions struct {
	Host                string `json:"host"`
	StartWhenUsed       *bool  `json:"startWhenUsed,omitempty"`
	StopWhenIdleMinutes *int   `json:"stopWhenIdleMinutes,omitempty"`
	StartForSchedules   *bool  `json:"startForSchedules,omitempty"`
}

// ProviderOptions is DaemonAPI.ProviderOptions: the New Workspace form, a JSON Schema.
type ProviderOptions struct {
	Schema any `json:"schema"`
}

// ProviderCreate is DaemonAPI.ProviderCreate: providers/create.
type ProviderCreate struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Options any      `json:"options,omitempty"`
	Clones  []string `json:"clones,omitempty"`
}

// ProviderCreated is DaemonAPI.ProviderCreated: what providers/create made.
type ProviderCreated struct {
	Workspace WorkspaceInfo `json:"workspace"`
	Joining   bool          `json:"joining"`
}

// HostStop is DaemonAPI.HostStop: hosts/stop.
type HostStop struct {
	Host           string `json:"host"`
	ConfirmRunning *bool  `json:"confirmRunning,omitempty"`
}

// HostWorkspaceCall is DaemonAPI.HostWorkspaceCall: host/workspaces, for an agent there.
type HostWorkspaceCall struct {
	// Who asked, for the log: "Claude (fix-login)".
	Agent  string          `json:"agent"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// AgentWorkspaces is DaemonAPI.AgentWorkspaces: what list_workspaces shows an agent.
type AgentWorkspaces struct {
	Providers []AgentProvider `json:"providers"`
}

// AgentProvider is DaemonAPI.AgentWorkspaces.Provider.
type AgentProvider struct {
	ID         string           `json:"id"`
	Name       string           `json:"name"`
	CanMake    bool             `json:"canMake"`
	CanDelete  bool             `json:"canDelete"`
	Options    any              `json:"options,omitempty"`
	Workspaces []AgentWorkspace `json:"workspaces"`
}

// AgentWorkspace is DaemonAPI.AgentWorkspaces.Workspace.
type AgentWorkspace struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	State     string `json:"state"`
	Host      string `json:"host,omitempty"`
	HostState string `json:"hostState,omitempty"`
	Cost      string `json:"cost,omitempty"`
}

// HostStatus is DaemonAPI.HostStatus: host/status on channel 0 (#691 US4).
type HostStatus struct {
	Idle bool `json:"idle"`
	// "Claude (fix-login)": each agent working or waiting on a person.
	Running []string `json:"running"`
	// Nil from a host from before #1004; empty when nothing is scheduled.
	Schedule *HostSchedule `json:"schedule,omitempty"`
}

// HostSchedule is DaemonAPI.HostSchedule: a host's next scheduled workflow (#1004).
type HostSchedule struct {
	At       *RefDate `json:"at,omitempty"`
	Workflow string   `json:"workflow,omitempty"`
}

func (s *HostSchedule) schedule() *Schedule {
	if s == nil {
		return nil
	}
	out := &Schedule{Workflow: s.Workflow}
	if s.At != nil {
		t := time.Time(*s.At)
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
