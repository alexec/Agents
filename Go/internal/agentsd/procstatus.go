package agentsd

import (
	"os"
	"strconv"
	"strings"
)

// procStatus is what /proc/<pid>/status says of a process (PeerCredentials.ProcessStatus):
// its name, its real uid and its parent. Readable for every process, whoever owns it,
// unless /proc is mounted hidepid.
type procStatus struct {
	name   string
	uid    int
	parent int
}

// parseProcStatus reads a status file; false for anything without all three lines.
func parseProcStatus(status string) (procStatus, bool) {
	fields := map[string]string{}
	for _, line := range strings.Split(status, "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok {
			fields[k] = v
		}
	}
	name := strings.TrimSpace(fields["Name"])
	uids := strings.Fields(fields["Uid"])
	parent, perr := strconv.Atoi(strings.TrimSpace(fields["PPid"]))
	if name == "" || len(uids) == 0 || perr != nil {
		return procStatus{}, false
	}
	uid, err := strconv.Atoi(uids[0])
	if err != nil {
		return procStatus{}, false
	}
	return procStatus{name: name, uid: uid, parent: parent}, true
}

// readProcStatus is parseProcStatus of /proc/<pid>/status.
func readProcStatus(pid int) (procStatus, bool) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/status")
	if err != nil {
		return procStatus{}, false
	}
	return parseProcStatus(string(b))
}

// sshdNames are the names OpenSSH's session processes go by: sshd before 9.8,
// sshd-session after.
var sshdNames = map[string]bool{"sshd": true, "sshd-session": true}

// isSSHSession says whether peer, of this account, is an ssh login's own session process:
// the one that carries a -L forward to the socket, which is how a Mac reaches a server's
// daemon. Only the privileged sshd, as root, makes one, so its parent is a root sshd that
// is not pid 1 (in a container sshd may be pid 1, and every orphan is handed to pid 1).
// Nothing an agent starts has a root parent: it descends from the daemon, or, orphaned,
// from pid 1 or a systemd --user of this account. A name can be set by anyone, but not on
// a root process.
func isSSHSession(peer procStatus, parent *procStatus) bool {
	if !sshdNames[peer.name] || peer.parent <= 1 || parent == nil || parent.uid != 0 {
		return false
	}
	return sshdNames[parent.name]
}
