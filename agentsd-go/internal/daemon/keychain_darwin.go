package daemon

import "os/exec"

// keychainSignIn: on a Mac, Claude Code keeps its sign-in in the login Keychain, and
// claude-agent-acp, run as this user, reads it itself. This asks only whether the item is
// there (no -w: the secret is never read here). Lending it to a server, as the Swift
// host's MacSignInRelay does, would read it with -w and serve it through a TLS relay.
func keychainSignIn() bool {
	return exec.Command("/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials").Run() == nil
}
