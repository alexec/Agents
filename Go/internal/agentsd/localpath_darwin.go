package agentsd

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
)

func localPathHere() bool { return true }

// makeLocalGroup asks agents-peer to make the app group's container. macOS refuses a plain
// mkdir there, and Go cannot ask for it without cgo; agents-peer, signed by the team with
// the group in its entitlements, can.
func makeLocalGroup() {
	helper := os.Getenv("AGENTS_PEER_HELPER")
	if helper == "" {
		exe, err := os.Executable()
		if err != nil {
			return
		}
		helper = filepath.Join(filepath.Dir(exe), "agents-peer")
	}
	if _, err := os.Stat(helper); err != nil {
		return
	}
	if out, err := exec.Command(helper, "container", LocalGroup).CombinedOutput(); err != nil {
		log.Printf("local: agents-peer container: %v: %s", err, out)
	}
}
