package agentsd

// Role is what a connection is, and so what it may ask for (ConnectionRole.swift).
// Decided by the host from who is on the other end, never from anything the caller says:
// on a Mac, the code signature of the process on daemon.sock (Go/internal/mac); a channel
// from the control plane is control.
type Role string

const (
	// RoleControl is the app or the bridge: everything.
	RoleControl Role = "control"
	// RoleAgent is this host's own binary run as a runtime's MCP helper: its tools only.
	RoleAgent Role = "agent"
	// RoleHostApp is Agents Host's window: what it counts, and nothing more (#168).
	RoleHostApp Role = "hostApp"
	// RoleStranger is anything else of this account: whether the host is there.
	RoleStranger Role = "stranger"
)

// CodeNotPermitted is DaemonAPI.Failure.notPermitted.
const CodeNotPermitted = -32045

func methodSet(names ...string) map[string]bool {
	s := map[string]bool{}
	for _, n := range names {
		s[n] = true
	}
	return s
}

// strangerMethods are enough to find out a host is answering.
var strangerMethods = methodSet("daemon/ping", "daemon/status")

// agentMethods are what a helper relays, one per app tool (ConnectionRole.agentMethods).
var agentMethods = methodSet("agents/finishTurn", "agents/afterTurn", "agents/setOwnLabels", "agents/waitOn",
	"agents/suggestPrompts", "agents/reportOutcome", "agents/showFile", "agents/askForm", "agents/manageWorkflows",
	"agents/startHelper", "agents/stopHelper", "agents/requestArchiveHelper", "agents/listHelpers",
	"agents/listSessions", "agents/readSession", "agents/messageAgent", "leases/lease", "leases/release",
	"leases/list", "events/wait", "events/cancel", "agents/moveSelf", "views/toolCall", "agents/workspaces",
	"agents/providerDraft")

// hostAppMethods are what Agents Host's window counts: projects, and agents working.
var hostAppMethods = methodSet("projects/list", "agents/list")

// Allows is ConnectionRole.allows.
func (r Role) Allows(method string) bool {
	switch r {
	case RoleControl, "":
		return true
	case RoleAgent:
		return agentMethods[method] || strangerMethods[method]
	case RoleHostApp:
		return hostAppMethods[method] || strangerMethods[method]
	default:
		// A host's git, through `agentsd git-credential` (#1122): any process of the account.
		return strangerMethods[method] || method == "git/credential"
	}
}

// HearsNotifications is ConnectionRole.hearsNotifications: a window hears what the host
// says; a helper waits only on its replies, and a stranger must not read every transcript.
func (r Role) HearsNotifications() bool { return r == RoleControl || r == "" }

// SignedRoles is RolePolicy.signedRoles: the role of a caller signed by this host's team
// as each identifier. Exact identifiers only: anything else is a stranger.
var SignedRoles = map[string]Role{
	"com.alexecollins.agents":        RoleControl,
	"com.alexecollins.agents.bridge": RoleControl,
	"agentsd":                        RoleAgent,
	"com.alexecollins.agents.host":   RoleHostApp,
}

// RoleForSignedIdentifier is RolePolicy.role(forSignedIdentifier:).
func RoleForSignedIdentifier(identifier string) Role {
	if r, ok := SignedRoles[identifier]; ok {
		return r
	}
	return RoleStranger
}
