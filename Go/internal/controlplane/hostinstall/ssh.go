package hostinstall

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

// sshAdd is the ssh-add HostKeyCheck.fetch asks whether the agent holds a key.
var sshAdd = "/usr/bin/ssh-add"

// sshCommand is SSHCommand, without a master: the person's own ssh, with their config,
// keys, agent and known_hosts. BatchMode is on for every call, so ssh never waits on a
// prompt nobody can see.
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

// ownConnection is SSHCommand.ownConnection: never the person's ControlMaster.
var ownConnection = []string{"-o", "ControlMaster=no", "-o", "ControlPath=none"}

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

// resolveArguments is SSHCommand.resolveArguments: what the config says about this
// name, with no network.
func (s sshCommand) resolveArguments() []string { return []string{"-G", "--", s.destination()} }

// keyFetchArguments is SSHCommand.keyFetchArguments: connect only far enough to learn
// the host key, offering no credentials, into knownHosts alone.
func (s sshCommand) keyFetchArguments(knownHosts string) []string {
	args := join(batch, quiet, ownConnection, []string{
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "UserKnownHostsFile=" + knownHosts,
		"-o", "GlobalKnownHostsFile=/dev/null",
		"-o", "PreferredAuthentications=none"})
	// After ours: ssh keeps the first value it is given for each option.
	return join(args, s.options, []string{"--", s.destination(), "true"})
}

// runArguments is SSHCommand.runArguments: a shell command on the server, over a
// connection of its own (#610).
func (s sshCommand) runArguments(remote string) []string {
	return join(batch, s.options, quiet, ownConnection, []string{"--", s.destination(), remote})
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

// run is SSHCommand.run: ssh with these arguments, waited for. stdin, when given, is a
// file handed to ssh as its standard input, so a binary is streamed and not held. A
// program left running in the background can hold a pipe open, so the pipes are
// waited for only a few seconds past the exit.
func (s sshCommand) run(ctx context.Context, args []string, stdin string) (output, error) {
	cmd := exec.CommandContext(ctx, s.executable, args...)
	cmd.Env = s.env
	if stdin != "" {
		f, err := os.Open(stdin)
		if err != nil {
			return output{}, err
		}
		defer f.Close()
		cmd.Stdin = f
	}
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

// sshEnvironment is SSHCommand.environment: this process's environment, less what
// could open a prompt nobody sees and less the app's own variables.
func sshEnvironment(inherited []string) []string {
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

// environment is MachineInstall.environment: what ssh runs with. The agent stays only when
// no key was given, so a refused key is never followed by another identity.
func environment(keepAgent bool, inherited []string) []string {
	var env []string
	for _, kv := range sshEnvironment(inherited) {
		if !keepAgent && strings.HasPrefix(kv, "SSH_AUTH_SOCK=") {
			continue
		}
		env = append(env, kv)
	}
	return env
}

// throughBastionResolved is SSHCommand.throughBastion: whether `ssh -G` says this name
// is reached through another machine, a ProxyJump or a ProxyCommand (#435).
func throughBastionResolved(resolved string) bool {
	for _, line := range lines(resolved) {
		key, value, ok := strings.Cut(line, " ")
		if !ok {
			continue
		}
		key = strings.ToLower(key)
		if (key == "proxyjump" || key == "proxycommand") && strings.ToLower(strings.TrimSpace(value)) != "none" {
			return true
		}
	}
	return false
}

// lines are the non-empty lines of text.
func lines(text string) []string {
	return strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' })
}

// classify is SSHCommand.classify: what went wrong, from ssh's own words. Nil when the
// command succeeded. agentHasKeys splits a refused login in two: with nothing in the
// agent, the likeliest reason is a key that needs its passphrase.
func classify(status int, stderr string, agentHasKeys bool) *Problem {
	if status == 0 {
		return nil
	}
	has := func(s string) bool { return strings.Contains(stderr, s) }
	switch {
	case has("Could not resolve hostname"):
		return problem(UnknownHost)
	case has("you have requested strict checking") && !has("REMOTE HOST IDENTIFICATION HAS CHANGED"):
		return problem(HostKeyUnknown)
	case has("REMOTE HOST IDENTIFICATION HAS CHANGED"), has("Host key verification failed"):
		return problem(HostKeyChanged)
	case has("Permission denied"):
		if agentHasKeys {
			return problem(LoginRefused)
		}
		return problem(KeyLocked)
	case has("Connection timed out"), has("Operation timed out"), has("No route to host"), has("Connection refused"):
		return timedOut("connect")
	case has("administratively prohibited"):
		return problem(NoStreamLocalForwarding)
	case has("No space left on device"):
		return &Problem{Kind: DiskFull}
	}
	all := lines(stderr)
	if len(all) > 3 {
		all = all[len(all)-3:]
	}
	return installFailed(strings.Join(all, "\n"))
}

// agentHasKeys is SSHCommand.agentHasKeys: whether the agent holds any key.
// `ssh-add -l` exits 0 when it lists one.
func agentHasKeys(ctx context.Context, env []string) bool {
	cmd := exec.CommandContext(ctx, sshAdd, "-l")
	cmd.Env = env
	return cmd.Run() == nil
}
