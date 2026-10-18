package agentsd

import (
	"errors"
	"log"
	"net"
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/mac"
)

// platformSocketPolicy is RolePolicy.forDaemon: roles by code signature, through the
// agents-peer helper beside this binary in Agents Host's Helpers. Roles need signatures
// to tell programs apart, so with no helper, or one not signed by a team, the socket is
// open. So is a scratch root unless AGENTS_ENFORCE_ROLES is set: a walk drives its host
// from a shell, and nothing on a scratch root is anybody's real work. Whatever the
// policy, another account is turned away before it can send a line.
func platformSocketPolicy(d *Daemon) SocketPolicy {
	if !store.IsStandard(d.Store.Loc.Root) && os.Getenv("AGENTS_ENFORCE_ROLES") == "" {
		return ownAccount{openPolicy{why: "a scratch root, so "}}
	}
	helper := os.Getenv("AGENTS_PEER_HELPER")
	if helper == "" {
		exe, err := os.Executable()
		if err != nil {
			return ownAccount{openPolicy{why: "no path to agents-peer, so "}}
		}
		helper = filepath.Join(filepath.Dir(exe), "agents-peer")
	}
	if _, err := os.Stat(helper); err != nil {
		return ownAccount{openPolicy{why: "no agents-peer beside agentsd, so "}}
	}
	p := mac.NewPeerChecker(helper)
	team, err := p.Team()
	if errors.Is(err, mac.ErrUnsigned) {
		return ownAccount{openPolicy{why: "not signed by a team, so "}}
	}
	if err != nil {
		// It may answer later: every caller is a stranger until it does.
		log.Printf("socket: %v", err)
	}
	return signatures{peers: p, team: team}
}

// ownTokenOf is the caller's audit token, if it is this account's.
func ownTokenOf(c net.Conn) (mac.Token, bool) {
	t, err := mac.PeerToken(c)
	if err != nil || int(t.UID()) != os.Geteuid() {
		return mac.Token{}, false
	}
	return t, true
}

// ownAccount is a policy that first turns away every other account, by audit token.
type ownAccount struct{ SocketPolicy }

func (p ownAccount) Role(c net.Conn) (Role, bool) {
	if _, ok := ownTokenOf(c); !ok {
		return "", false
	}
	return p.SocketPolicy.Role(c)
}

// signatures is RolePolicy.signatures: control for the app and the bridge, agent for the
// helper, hostApp for Agents Host, each signed by this team; anything else a stranger.
type signatures struct {
	peers *mac.PeerChecker
	team  string
}

func (s signatures) Summary() string { return "roles by code signature, team " + s.team }

func (s signatures) Role(c net.Conn) (Role, bool) {
	t, ok := ownTokenOf(c)
	if !ok {
		return "", false
	}
	r, err := s.peers.Role(t)
	if err != nil {
		log.Printf("socket: pid %d: %v", t.PID(), err)
		return RoleStranger, true
	}
	return Role(r), true
}
