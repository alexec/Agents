// Package buildinfo says which build of agentsd or agents-control is running.
package buildinfo

// Implementation names the language a host or control plane is written in. A host sends
// it in machine/hello beside its version, so the Hosts pane can show "Go" (#1134).
const Implementation = "go"

// Version is set at link time: -ldflags "-X github.com/alexec/agents/Go/internal/buildinfo.Version=0.2.0".
var Version = "dev"

// String is the version and the implementation, as a log line shows them.
func String() string {
	return Version + " (" + Implementation + ")"
}
