package hostinstall

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// DetectedServer is DaemonAPI.DetectedServer: one host in the ssh config (its Host name,
// and user@hostname:port as `ssh -G` resolved it), what hosts/detect did with it, and why,
// in words, when it was not added (#429).
type DetectedServer = wire.DetectedServer

// Outcome is DaemonAPI.DetectedServer.Outcome.
type Outcome = string

// The outcomes of hosts/detect.
const (
	// Added: it answered and was installed. It joins by itself.
	Added Outcome = "added"
	// Known: a host by that name is already on the control plane.
	Known Outcome = "known"
	// Bastion: another host's ProxyJump or ProxyCommand goes through it.
	Bastion Outcome = "bastion"
	// Unreachable: it did not answer, or would not let ssh in without a prompt.
	Unreachable Outcome = "unreachable"
	// Failed: it answered, and the install failed.
	Failed Outcome = "failed"
)

// SSHHost is DaemonAPI.SSHHost: a server ssh knows by a name, for Add a Machine's server
// box (#610): the Host name in the config (or the destination as typed), user@hostname:port
// as `ssh -G` resolved it, whether it is reached through a ProxyJump or ProxyCommand (so
// it rarely can dial back, and a tunnel is the default), whether it is another host's way
// in, and whether a host by that name is on the control plane already.
type SSHHost = wire.SSHHost

// probeResult is HostDetect.Probe: it let ssh in, or why not.
type probeResult struct {
	answered  bool
	installed bool
	why       string
}

// detector is HostDetect, with each step a function, so tests can give their own.
type detector struct {
	aliases    func() []string
	resolve    func(ctx context.Context, alias string) *Resolved
	probe      func(ctx context.Context, alias string) probeResult
	install    func(ctx context.Context, alias string) error
	knownNames func(ctx context.Context) []string
}

// How many ssh connections at once (HostDetect.probes, .installs): enough that a dozen
// dead hosts take one timeout, few enough not to trip a server's MaxStartups.
const (
	probesAtOnce   = 8
	installsAtOnce = 2
	probeLimit     = 30 * time.Second
)

// detector is HostDetect.init(installer:knownNames:): the person's own ssh, their
// ~/.ssh/config (or ConfigFile, or AGENTS_SSH_CONFIG), agent and known_hosts.
func (i *Installer) detector() detector {
	config := i.configFile()
	var file string
	if len(config) == 2 {
		file = config[1]
	} else {
		home, _ := os.UserHomeDir()
		file = filepath.Join(home, ".ssh", "config")
	}
	sshFor := func(alias string, options []string) sshCommand {
		return sshCommand{executable: i.sshExecutable(), name: alias, env: i.env(true), options: options}
	}
	return detector{
		aliases: func() []string {
			home, _ := os.UserHomeDir()
			return Aliases(file, "", home)
		},
		resolve: func(ctx context.Context, alias string) *Resolved {
			ssh := sshFor(alias, config)
			out, err := ssh.run(ctx, join(config, ssh.resolveArguments()), "")
			if err != nil || out.status != 0 {
				return nil
			}
			r := ParseResolved(alias, out.stdout)
			return &r
		},
		probe: func(ctx context.Context, alias string) probeResult {
			ssh := sshFor(alias, join(config, []string{"-o", "StrictHostKeyChecking=yes"}))
			ssh.options = append(ssh.options, personsKnownHostsOptions(ctx, ssh)...)
			found, err := within(ctx, probeLimit, func(ctx context.Context) (*facts, error) {
				return (installer{ssh}).probe(ctx)
			})
			var p *Problem
			if errors.As(err, &p) {
				return probeResult{why: Say(p, false)}
			}
			if err != nil {
				return probeResult{why: "It did not answer."}
			}
			return probeResult{answered: true, installed: found.installedSHA256 != nil}
		},
		install: func(ctx context.Context, alias string) error {
			_, err := i.install(ctx, Request{Destination: alias}, true)
			return err
		},
		knownNames: func(ctx context.Context) []string {
			if i.KnownNames == nil {
				return nil
			}
			return i.KnownNames(ctx)
		},
	}
}

// Detect is hosts/detect (#429): every server in the ssh config that answers, added
// without being typed in. The reply is []DetectedServer.
func (i *Installer) Detect(ctx context.Context) (any, error) {
	return i.detector().run(ctx), nil
}

// SSHHosts is hosts/sshHosts (#610). The reply is []SSHHost. destination "" is every
// host in the config; otherwise just that, as typed.
func (i *Installer) SSHHosts(ctx context.Context, destination string) (any, error) {
	return i.detector().sshHosts(ctx, trimSpaces(destination)), nil
}

func (d detector) resolveAll(ctx context.Context, names []string) []Resolved {
	return each(names, probesAtOnce, func(alias string) Resolved {
		if r := d.resolve(ctx, alias); r != nil {
			return *r
		}
		return Resolved{Alias: alias, Options: map[string]string{}}
	})
}

func (d detector) known(ctx context.Context) map[string]bool {
	known := map[string]bool{}
	for _, n := range d.knownNames(ctx) {
		known[strings.ToLower(n)] = true
	}
	return known
}

func isKnown(host Resolved, known map[string]bool) bool {
	return known[strings.ToLower(host.Alias)] || known[strings.ToLower(host.HostName())]
}

// run is HostDetect.run:
//  1. The concrete Host names, each resolved by `ssh -G`.
//  2. Bastions are dropped: a name another entry goes through is a way in, not a server.
//     Hosts behind one stay, and are probed through it.
//  3. A host the control plane has by that name is left alone.
//  4. The rest are probed, a few at once. One that does not answer is not added.
//  5. What answered is installed as hosts/install would with no key, trusting the host
//     key the person's known_hosts already has. One with Agents installed already is
//     joined the same way (#485).
func (d detector) run(ctx context.Context) []DetectedServer {
	names := d.aliases()
	resolved := d.resolveAll(ctx, names)
	bastions := Bastions(resolved)
	known := d.known(ctx)

	results := map[string]DetectedServer{}
	var toProbe []Resolved
	for _, host := range resolved {
		switch {
		case IsBastion(host, bastions):
			results[host.Alias] = detected(host, Bastion, "Other hosts are reached through it.")
		case isKnown(host, known):
			results[host.Alias] = detected(host, Known, "Already a host.")
		default:
			toProbe = append(toProbe, host)
		}
	}

	type probed struct {
		host   Resolved
		answer probeResult
	}
	answers := each(toProbe, probesAtOnce, func(host Resolved) probed {
		return probed{host, d.probe(ctx, host.Alias)}
	})
	var toInstall []Resolved
	for _, a := range answers {
		if a.answer.answered {
			toInstall = append(toInstall, a.host)
		} else {
			results[a.host.Alias] = detected(a.host, Unreachable, a.answer.why)
		}
	}

	installed := each(toInstall, installsAtOnce, func(host Resolved) DetectedServer {
		err := d.install(ctx, host.Alias)
		if err == nil {
			return detected(host, Added, "")
		}
		var f *Failure
		if errors.As(err, &f) {
			return detected(host, Failed, f.Message)
		}
		return detected(host, Failed, err.Error())
	})
	for _, server := range installed {
		results[server.Alias] = server
	}
	all := []DetectedServer{}
	for _, n := range names {
		if r, ok := results[n]; ok {
			all = append(all, r)
		}
	}
	return all
}

func detected(host Resolved, outcome Outcome, detail string) DetectedServer {
	server := DetectedServer{Alias: host.Alias, Resolved: host.Display(), Outcome: outcome}
	if detail != "" {
		server.Detail = &detail
	}
	return server
}

// sshHosts is HostDetect.sshHosts (#610): what Add a Machine's server box suggests, from
// `ssh -G` alone, with no network. Each says whether ssh reaches it through a bastion,
// so the sheet can turn a tunnel on for it.
func (d detector) sshHosts(ctx context.Context, destination string) []SSHHost {
	var names []string
	if destination != "" {
		names = []string{destination}
	} else {
		names = d.aliases()
	}
	resolved := d.resolveAll(ctx, names)
	bastions := map[string]bool{}
	if destination == "" {
		bastions = Bastions(resolved)
	}
	known := d.known(ctx)
	all := []SSHHost{}
	for _, host := range resolved {
		all = append(all, SSHHost{Alias: host.Alias, Resolved: host.Display(),
			ThroughBastion: len(host.JumpHosts()) > 0, IsBastion: IsBastion(host, bastions), Known: isKnown(host, known)})
	}
	return all
}

// each is HostDetect.each: work on each item, at most limit at once, the results in
// the items' order.
func each[T, R any](items []T, limit int, work func(T) R) []R {
	results := make([]R, len(items))
	slots := make(chan struct{}, limit)
	var wg sync.WaitGroup
	for n, item := range items {
		slots <- struct{}{}
		wg.Add(1)
		go func() {
			defer func() { <-slots; wg.Done() }()
			results[n] = work(item)
		}()
	}
	wg.Wait()
	return results
}

// within is HostDetect.within: work, or a timeout when it takes longer. ssh's own
// ConnectTimeout does not cover a ProxyCommand that hangs. The work is not waited for;
// its context ends, and it ends by itself.
func within[T any](ctx context.Context, limit time.Duration, work func(context.Context) (T, error)) (T, error) {
	ctx, cancel := context.WithCancel(ctx)
	type result struct {
		value T
		err   error
	}
	done := make(chan result, 1)
	go func() {
		v, err := work(ctx)
		done <- result{v, err}
	}()
	timer := time.NewTimer(limit)
	defer timer.Stop()
	select {
	case r := <-done:
		cancel()
		return r.value, r.err
	case <-timer.C:
		cancel()
		var zero T
		return zero, timedOut("It did not answer in time.")
	}
}
