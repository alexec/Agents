package hosttunnels

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/procgroup"
)

// DefaultSSH is SSHCommand.system.
const DefaultSSH = "/usr/bin/ssh"

// sshCommand is the part of SSHCommand that a tunnel uses: the person's own ssh, with
// their config, keys, agent and known_hosts. It is a copy of hostinstall's, which is
// not exported.
type sshCommand struct {
	executable string
	// name is the destination, as the person typed it. It always goes after "--".
	name string
	env  []string
	// options go on every command that logs in.
	options []string
}

// batch is SSHCommand.batch.
var batch = []string{"-o", "BatchMode=yes", "-o", "ConnectTimeout=10"}

// quiet is SSHCommand.quiet: what the person's config may say that would break a
// connection of ours (#610).
var quiet = []string{"-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "ClearAllForwardings=yes"}

// sayErrors is MachineInstall.sayErrors: over a config's "LogLevel quiet" (#964).
var sayErrors = []string{"-o", "LogLevel=error"}

// destination is SSHCommand.destination: user@host:port is written ssh://user@host:port,
// which ssh reads. An alias, or anything else, goes as typed.
func (s sshCommand) destination() string {
	name := s.name
	colon := strings.LastIndex(name, ":")
	if strings.HasPrefix(name, "ssh://") || colon < 0 {
		return name
	}
	port, err := strconv.Atoi(name[colon+1:])
	if err != nil || port < 1 || port > 65535 || strings.Contains(name[:colon], ":") {
		return name
	}
	return "ssh://" + name
}

// resolveArguments is SSHCommand.resolveArguments.
func (s sshCommand) resolveArguments() []string { return []string{"-G", "--", s.destination()} }

// tunnelMasterArguments is SSHCommand.tunnelMasterArguments: a master of its own on
// control, never the person's. It opens no forward. ClearAllForwardings drops every
// forward of the config, and would drop a -R given here too. So the tunnel's one
// forward is asked for when the master is up (tunnelForwardArguments).
func (s sshCommand) tunnelMasterArguments(control string) []string {
	return join(batch, s.options, quiet, []string{
		"-M", "-N", "-S", control, "-o", "ControlPersist=no",
		"-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ExitOnForwardFailure=yes",
		"--", s.destination()})
}

// tunnelForwardArguments is SSHCommand.tunnelForwardArguments: the server's
// 127.0.0.1:remote reaches this machine's 127.0.0.1:local.
func (s sshCommand) tunnelForwardArguments(control string, remotePort, localPort int) []string {
	return []string{"-S", control, "-O", "forward",
		"-R", "127.0.0.1:" + strconv.Itoa(remotePort) + ":127.0.0.1:" + strconv.Itoa(localPort),
		"--", s.destination()}
}

// tunnelCancelArguments is tunnelForwardArguments' undoing: the master stops the
// server's forward, and the server lets go of its port.
func (s sshCommand) tunnelCancelArguments(control string, remotePort, localPort int) []string {
	args := s.tunnelForwardArguments(control, remotePort, localPort)
	args[3] = "cancel"
	return args
}

// tunnelControlArguments is SSHCommand.tunnelControlArguments: "-O check" or "-O exit",
// asked of a tunnel's master.
func (s sshCommand) tunnelControlArguments(control, operation string) []string {
	return []string{"-S", control, "-O", operation, "--", s.destination()}
}

func join(parts ...[]string) []string {
	var all []string
	for _, p := range parts {
		all = append(all, p...)
	}
	return all
}

// output is SSHCommand.Output.
type output struct {
	status int
	stdout string
	stderr string
}

// run is SSHCommand.run: ssh with these arguments, waited for. A program left running
// in the background can hold a pipe open, so the pipes are waited for only a few
// seconds past the exit.
func (s sshCommand) run(ctx context.Context, args []string) (output, error) {
	cmd := exec.CommandContext(ctx, s.executable, args...)
	cmd.Env = s.env
	var out, errs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errs
	cmd.WaitDelay = 5 * time.Second
	// A ProxyCommand ssh leaves running, such as gh's relay, ends with it (#1643).
	procgroup.Own(cmd)
	err := cmd.Run()
	procgroup.End(cmd)
	if cmd.ProcessState == nil {
		// It never started.
		return output{}, err
	}
	// A signal says -1: as ssh's own failure.
	status := cmd.ProcessState.ExitCode()
	if status < 0 {
		status = 255
	}
	return output{status: status, stdout: out.String(), stderr: errs.String()}, nil
}

// environment is MachineInstall.environment(keepAgent: true): this process's environment,
// less what could open a prompt nobody sees and less the app's own variables.
func environment(inherited []string) []string {
	var env []string
	for _, kv := range inherited {
		key, _, _ := strings.Cut(kv, "=")
		if key == "SSH_ASKPASS" || key == "SSH_ASKPASS_REQUIRE" || key == "DISPLAY" ||
			strings.HasPrefix(key, "CLAUDE") || strings.HasPrefix(key, "AGENTS_") {
			continue
		}
		env = append(env, kv)
	}
	return env
}

// personsKnownHosts is MachineInstall.personsKnownHosts: the person's own known_hosts, for
// a server whose ssh config checks against none (#514).
func personsKnownHosts(ctx context.Context, s sshCommand) []string {
	resolved, err := s.run(ctx, join(s.options, s.resolveArguments()))
	if err != nil || resolved.status != 0 {
		return nil
	}
	return knownHostsOverride(resolved.stdout)
}

// knownHostsOverride is MachineInstall.knownHostsOverride: from "ssh -G" output, the
// default known_hosts files when every one it names is /dev/null, otherwise nothing.
func knownHostsOverride(resolved string) []string {
	var files []string
	for _, line := range lines(resolved) {
		key, value, ok := strings.Cut(line, " ")
		if !ok || strings.ToLower(key) != "userknownhostsfile" {
			continue
		}
		files = strings.Fields(value)
		break
	}
	if len(files) == 0 {
		return nil
	}
	for _, f := range files {
		if f != "/dev/null" {
			return nil
		}
	}
	return []string{"-o", "UserKnownHostsFile=~/.ssh/known_hosts ~/.ssh/known_hosts2"}
}

// lines are the non-empty lines of text.
func lines(text string) []string {
	return strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' })
}

// sshExecutable is MachineInstall.sshExecutable: AGENTS_SSH, else DefaultSSH.
func sshExecutable() string {
	if s := os.Getenv("AGENTS_SSH"); s != "" {
		return s
	}
	return DefaultSSH
}

// configFile is MachineInstall.configFile: -F and the file AGENTS_SSH_CONFIG names, for
// tests. Otherwise nothing, and ssh reads the person's own ~/.ssh/config.
func configFile(file string) []string {
	if file == "" {
		file = os.Getenv("AGENTS_SSH_CONFIG")
	}
	if file == "" {
		return nil
	}
	return []string{"-F", file}
}

// The sentences of MachineInstall.say that a tunnel's end can give, for a key ssh offered
// itself (keyGiven true, as HostTunnels.worded says them).
const (
	sayUnknownHost    = "ssh doesn’t know that server."
	sayLoginRefused   = "The server refused that key."
	sayHostKeyChanged = "The server’s host key has changed since your known_hosts last saw it, so nothing was installed. If the server was rebuilt, remove its old key (ssh-keygen -R) and try again."
	sayHostKeyUnknown = "The server’s host key isn’t in your known_hosts. Add it over ssh to see the key and trust it."
	sayTimedOut       = "It did not answer: the connection timed out or was refused."
)

// classified is SSHCommand.classify(status: 255, stderr:, agentHasKeys: true), then
// MachineInstall.say: ssh's words, as the person is told them. ok is false for
// installFailed, whose words are ssh's own.
func classified(stderr string) (said string, ok bool) {
	has := func(s string) bool { return strings.Contains(stderr, s) }
	switch {
	case has("Could not resolve hostname"):
		return sayUnknownHost, true
	case has("you have requested strict checking") && !has("REMOTE HOST IDENTIFICATION HAS CHANGED"):
		return sayHostKeyUnknown, true
	case has("REMOTE HOST IDENTIFICATION HAS CHANGED"), has("Host key verification failed"):
		return sayHostKeyChanged, true
	case has("Permission denied"):
		return sayLoginRefused, true
	case has("Connection timed out"), has("Operation timed out"), has("No route to host"), has("Connection refused"):
		return sayTimedOut, true
	case has("administratively prohibited"):
		// MachineInstall.say has no words for it: Swift prints the case.
		return "noStreamLocalForwarding", true
	case has("No space left on device"):
		return "diskFull(freeBytes: 0)", true
	}
	return "", false
}
