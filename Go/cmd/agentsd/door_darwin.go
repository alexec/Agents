package main

import (
	"log"
	"net"
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/internal/agentsd"
	"github.com/alexec/agents/Go/internal/mac"
)

// door is RolePolicy.forDaemon on a Mac: roles by the caller's code signature, through
// agents-mac beside this binary in Agents Host's Contents/Helpers. A host that is not
// signed by a team (agents-mac says so, or is not there) cannot tell programs apart and is
// open, as the Swift one; so is a scratch root, unless AGENTS_ENFORCE_ROLES is set.
func door(root string) agentsd.SocketDoor {
	self, _ := os.Executable()
	peers := &mac.Peers{Helper: filepath.Join(filepath.Dir(self), "agents-mac")}
	team, err := peers.Team()
	switch {
	case err != nil:
		log.Printf("socket: no agents-mac to read signatures with (%v), so every process of this account may call everything", err)
		return nil
	case team == "":
		log.Printf("socket: not signed by a team, so every process of this account may call everything")
		peers.Close()
		return nil
	case !ordinaryRoot(root) && os.Getenv("AGENTS_ENFORCE_ROLES") == "":
		log.Printf("socket: a scratch root, so every process of this account may call everything")
		peers.Close()
		return nil
	}
	log.Printf("socket: roles by code signature, team %s", team)
	return func(c net.Conn) (agentsd.Role, bool) {
		uc, ok := c.(*net.UnixConn)
		if !ok {
			return agentsd.RoleStranger, true
		}
		a, err := peers.Identify(uc)
		if err != nil {
			log.Printf("socket: could not read a caller's signature: %v", err)
			return agentsd.RoleStranger, true
		}
		if a.OtherUser {
			log.Printf("socket: refused a caller of another account")
			return "", false
		}
		return agentsd.RoleForSignedIdentifier(a.Identifier), true
	}
}
