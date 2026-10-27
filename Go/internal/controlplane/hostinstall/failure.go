// Package hostinstall is "Add a Machine over ssh" (058, US4, T072; #429, #610): the
// control plane's hosts/install, hosts/update, hosts/checkAgain, hosts/detect and
// hosts/sshHosts. It ports ControlPlaneKit's MachineInstall.swift, HostDetect.swift and
// SSHConfigHosts.swift, with the parts of AgentsKit's SSHCommand, HostKeyCheck and
// ServerInstaller that they use. HostTunnels.swift (#435) is not here: the Tunnels
// interface is where it goes.
package hostinstall

import (
	"fmt"
	"strings"
)

// Error codes a client sees: JSONRPCError's and DaemonAPI.Failure's.
const (
	InvalidParams = -32602
	InternalError = -32603
	NotSupported  = -32009
	NotPermitted  = -32045
	// NotAllowed is DaemonAPI.Failure.notAllowed: every install failure is said with it.
	NotAllowed  = -32060
	HostOffline = -32090
	NoSuchHost  = -32091
)

// Failure is JSONRPCError: an error a client sees, with its code and its words. The
// service turns it into a JSON-RPC error.
type Failure struct {
	Code    int
	Message string
}

func (f *Failure) Error() string { return fmt.Sprintf("%d %s", f.Code, f.Message) }

// NotHere is ControlMethods.notHere.
var NotHere = &Failure{Code: NotSupported, Message: "This control plane cannot do that yet."}

// Problem is HostProblem: why a server cannot be used, one kind per sentence.
type Problem struct {
	Kind ProblemKind
	// Words: ssh's or the server's own, for installFailed and timedOut.
	Words string
	// FreeBytes, for diskFull.
	FreeBytes int64
	// System and Architecture, for unsupportedSystem.
	System, Architecture string
}

// ProblemKind is a case of HostProblem.
type ProblemKind string

// The cases of HostProblem that ssh and the installer give.
const (
	UnknownHost             ProblemKind = "unknownHost"
	LoginRefused            ProblemKind = "loginRefused"
	KeyLocked               ProblemKind = "keyLocked"
	HostKeyChanged          ProblemKind = "hostKeyChanged"
	HostKeyUnknown          ProblemKind = "hostKeyUnknown"
	UnsupportedSystem       ProblemKind = "unsupportedSystem"
	NoStreamLocalForwarding ProblemKind = "noStreamLocalForwarding"
	DiskFull                ProblemKind = "diskFull"
	InstallFailed           ProblemKind = "installFailed"
	TimedOut                ProblemKind = "timedOut"
	Offline                 ProblemKind = "offline"
)

func problem(kind ProblemKind) *Problem { return &Problem{Kind: kind} }

func installFailed(words string) *Problem { return &Problem{Kind: InstallFailed, Words: words} }

func timedOut(words string) *Problem { return &Problem{Kind: TimedOut, Words: words} }

// Error is the case as Swift prints it, as `"\(problem)"` does.
func (p *Problem) Error() string {
	switch p.Kind {
	case InstallFailed, TimedOut:
		return fmt.Sprintf("%s(%q)", p.Kind, p.Words)
	case DiskFull:
		return fmt.Sprintf("diskFull(freeBytes: %d)", p.FreeBytes)
	case UnsupportedSystem:
		return fmt.Sprintf("unsupportedSystem(system: %q, architecture: %q)", p.System, p.Architecture)
	}
	return string(p.Kind)
}

// Say is MachineInstall.say: the problem in words for the person. keyGiven says whether
// the request gave a key, or ssh offered its own.
func Say(p *Problem, keyGiven bool) string {
	switch p.Kind {
	case UnknownHost:
		return "ssh doesn’t know that server."
	case LoginRefused, KeyLocked:
		if !keyGiven {
			return "The server refused every key ssh offered. If yours has a passphrase, add it to the agent (ssh-add), or choose a key."
		}
		if p.Kind == LoginRefused {
			return "The server refused that key."
		}
		return "That key has a passphrase. Give a key without one for the install, or run the command instead."
	case HostKeyChanged:
		return "The server’s host key has changed since your known_hosts last saw it, so nothing was installed. If the server was rebuilt, remove its old key (ssh-keygen -R) and try again."
	case HostKeyUnknown:
		return "The server’s host key isn’t in your known_hosts. Add it over ssh to see the key and trust it."
	case TimedOut:
		return "It did not answer: the connection timed out or was refused."
	case InstallFailed:
		if strings.TrimSpace(p.Words) == "" {
			return "ssh failed without saying why."
		}
		return p.Words
	}
	return p.Error()
}

// words is MachineInstall.words: a Problem becomes a Failure a client sees, said for
// whether a key was given. Any other error goes on as it is.
func words(err error, keyGiven bool) error {
	if p, ok := err.(*Problem); ok {
		return &Failure{Code: NotAllowed, Message: Say(p, keyGiven)}
	}
	return err
}
