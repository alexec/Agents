package hostinstall

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Ports HostDetectTests: servers from the ssh config (#429).

func TestTheConcreteNamesAreReadThroughIncludes(t *testing.T) {
	ssh := t.TempDir()
	os.MkdirAll(filepath.Join(ssh, "config.d"), 0o755)
	config := `# defaults
Host *
    User agents
Host *.example.com !secret.example.com
    ForwardAgent no
Include config.d/*
Host devbox build-1 # two names
    HostName 10.0.0.4
Host=quoted "with space"
Match host devbox exec "true"
    Port 2222
Include config
`
	os.WriteFile(filepath.Join(ssh, "config"), []byte(config), 0o600)
	os.WriteFile(filepath.Join(ssh, "config.d/b"), []byte("Host gpu\n  ProxyJump bastion\nHost bastion\n"), 0o600)
	os.WriteFile(filepath.Join(ssh, "config.d/a"), []byte("host a\nHOST = devbox\n"), 0o600)

	got := Aliases(filepath.Join(ssh, "config"), "", ssh)
	want := []string{"a", "devbox", "gpu", "bastion", "build-1", "quoted", "with space"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%q", got)
	}
	if got := Aliases(filepath.Join(ssh, "none"), "", ssh); got == nil || len(got) != 0 {
		t.Fatalf("no config: %q", got)
	}
}

func TestABastionIsWhatAnotherEntryGoesThrough(t *testing.T) {
	hosts := []Resolved{
		{"gpu", map[string]string{"hostname": "10.1.0.9", "proxyjump": "ops@jump.example.com:2200,bastion"}},
		{"old", map[string]string{"hostname": "old.lan", "proxycommand": "ssh -q -W %h:%p gateway"}},
		{"nc", map[string]string{"hostname": "nc.lan", "proxycommand": "/usr/bin/ssh -l me -J hop1 relay nc %h %p"}},
		{"cf", map[string]string{"proxycommand": "cloudflared access ssh --hostname %h"}},
		{"bastion", map[string]string{"hostname": "203.0.113.1", "proxyjump": "none"}},
		{"jump", map[string]string{"hostname": "jump.example.com"}},
		{"devbox", map[string]string{"hostname": "10.0.0.4", "user": "agents", "port": "2222"}},
	}
	bastions := Bastions(hosts)
	want := map[string]bool{"jump.example.com": true, "bastion": true, "gateway": true, "hop1": true, "relay": true}
	if !reflect.DeepEqual(bastions, want) {
		t.Fatalf("%v", bastions)
	}
	var skipped []string
	for _, h := range hosts {
		if IsBastion(h, bastions) {
			skipped = append(skipped, h.Alias)
		}
	}
	// jump by its HostName; the hosts behind them stay candidates.
	if !reflect.DeepEqual(skipped, []string{"bastion", "jump"}) {
		t.Fatalf("%q", skipped)
	}
	if got := hosts[len(hosts)-1].Display(); got != "agents@10.0.0.4:2222" {
		t.Fatal(got)
	}
	if got := hostPart("ssh://me@[::1]:22"); got != "::1" {
		t.Fatal(got)
	}
}

func TestSSHDashGIsReadByKeyword(t *testing.T) {
	r := ParseResolved("devbox", "user agents\nhostname 10.0.0.4\nport 22\nproxyjump bastion\nidentityfile ~/.ssh/a\nidentityfile ~/.ssh/b\n")
	if r.Display() != "agents@10.0.0.4" || r.Options["identityfile"] != "~/.ssh/a" ||
		!reflect.DeepEqual(r.JumpHosts(), []string{"bastion"}) {
		t.Fatalf("%+v", r)
	}
}

func TestOnlyWhatAnswersIsAddedAndBastionsNeverAre(t *testing.T) {
	var mu sync.Mutex
	var installed, probed []string
	d := detector{
		aliases: func() []string { return []string{"devbox", "bastion", "gpu", "down", "mine", "had"} },
		resolve: func(_ context.Context, alias string) *Resolved {
			switch alias {
			case "gpu":
				return &Resolved{alias, map[string]string{"hostname": "10.1.0.9", "proxyjump": "bastion"}}
			case "down":
				return nil
			}
			return &Resolved{alias, map[string]string{"hostname": alias + ".lan"}}
		},
		probe: func(_ context.Context, alias string) probeResult {
			mu.Lock()
			probed = append(probed, alias)
			mu.Unlock()
			switch alias {
			case "down":
				return probeResult{why: "It did not answer."}
			case "had":
				return probeResult{answered: true, installed: true}
			}
			return probeResult{answered: true}
		},
		install: func(_ context.Context, alias string) error {
			if alias == "gpu" {
				return &Failure{Code: 1, Message: "no host for that system"}
			}
			mu.Lock()
			installed = append(installed, alias)
			mu.Unlock()
			return nil
		},
		knownNames: func(context.Context) []string { return []string{"mine.lan"} },
	}
	results := d.run(context.Background())
	var aliases []string
	var outcomes []Outcome
	for _, r := range results {
		aliases = append(aliases, r.Alias)
		outcomes = append(outcomes, r.Outcome)
	}
	if !reflect.DeepEqual(aliases, []string{"devbox", "bastion", "gpu", "down", "mine", "had"}) {
		t.Fatalf("%q", aliases)
	}
	if !reflect.DeepEqual(outcomes, []Outcome{Added, Bastion, Failed, Unreachable, Known, Added}) {
		t.Fatalf("%q", outcomes)
	}
	if d := results[2].Detail; d == nil || *d != "no host for that system" {
		t.Fatalf("%v", d)
	}
	// Agents installed there already is not this control plane's host yet (#485).
	sort.Strings(installed)
	if !reflect.DeepEqual(installed, []string{"devbox", "had"}) {
		t.Fatalf("installed %q", installed)
	}
	// The bastion answers, and is never probed nor added; a known host is left alone.
	sort.Strings(probed)
	if !reflect.DeepEqual(probed, []string{"devbox", "down", "gpu", "had"}) {
		t.Fatalf("probed %q", probed)
	}
	// As Swift's JSONEncoder writes it: no detail when there is none.
	data, _ := json.Marshal(results[:2])
	want := `[{"alias":"devbox","resolved":"devbox.lan","outcome":"added"},` +
		`{"alias":"bastion","resolved":"bastion.lan","outcome":"bastion","detail":"Other hosts are reached through it."}]`
	if string(data) != want {
		t.Fatalf("%s", data)
	}
}

// #610: Add a Machine's server box, from ssh -G alone: nothing is probed or installed.
func TestTheServerBoxIsOfferedTheConfigsHostsResolved(t *testing.T) {
	d := detector{
		aliases: func() []string { return []string{"devbox", "bastion", "gpu", "mine"} },
		resolve: func(_ context.Context, alias string) *Resolved {
			switch alias {
			case "gpu":
				return &Resolved{alias, map[string]string{"user": "me", "hostname": "10.1.0.9", "proxyjump": "bastion"}}
			case "devbox":
				return &Resolved{alias, map[string]string{"user": "agents", "hostname": "127.0.0.1", "port": "2222"}}
			case "agents@ws:2200":
				return &Resolved{alias, map[string]string{"user": "agents", "hostname": "ws", "port": "2200",
					"proxycommand": "ssh -W %h:%p jump"}}
			}
			return &Resolved{alias, map[string]string{"hostname": alias + ".lan"}}
		},
		probe: func(context.Context, string) probeResult { t.Error("probed"); return probeResult{} },
		install: func(context.Context, string) error {
			t.Error("installed")
			return nil
		},
		knownNames: func(context.Context) []string { return []string{"mine.lan"} },
	}
	all := d.sshHosts(context.Background(), "")
	want := []SSHHost{
		{Alias: "devbox", Resolved: "agents@127.0.0.1:2222"},
		{Alias: "bastion", Resolved: "bastion.lan", IsBastion: true},
		{Alias: "gpu", Resolved: "me@10.1.0.9", ThroughBastion: true},
		{Alias: "mine", Resolved: "mine.lan", Known: true},
	}
	if !reflect.DeepEqual(all, want) {
		t.Fatalf("%+v", all)
	}
	// Typed, not in the config: still resolved, so a ProxyCommand a wildcard gives it counts.
	typed := d.sshHosts(context.Background(), "agents@ws:2200")
	if !reflect.DeepEqual(typed, []SSHHost{{Alias: "agents@ws:2200", Resolved: "agents@ws:2200", ThroughBastion: true}}) {
		t.Fatalf("%+v", typed)
	}
	data, _ := json.Marshal(typed)
	if string(data) != `[{"alias":"agents@ws:2200","resolved":"agents@ws:2200","throughBastion":true,"isBastion":false,"known":false}]` {
		t.Fatalf("%s", data)
	}
}

func TestAHungProbeEndsAtItsLimit(t *testing.T) {
	start := time.Now()
	_, err := within(context.Background(), 100*time.Millisecond, func(ctx context.Context) (int, error) {
		time.Sleep(5 * time.Second)
		return 1, nil
	})
	var p *Problem
	if !errors.As(err, &p) || p.Kind != TimedOut {
		t.Fatalf("%v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("it waited")
	}
}

func TestAtMostSoManyAtOnceAndInOrder(t *testing.T) {
	var running, most atomic.Int32
	items := make([]int, 20)
	for n := range items {
		items[n] = n
	}
	out := each(items, 3, func(item int) int {
		now := running.Add(1)
		for {
			m := most.Load()
			if now <= m || most.CompareAndSwap(m, now) {
				break
			}
		}
		time.Sleep(10 * time.Millisecond)
		running.Add(-1)
		return item * 2
	})
	for n, v := range out {
		if v != n*2 {
			t.Fatalf("%v", out)
		}
	}
	if most.Load() > 3 {
		t.Fatalf("%d at once", most.Load())
	}
}

// machines/detect and machines/sshHosts on the fake ssh, with a config of their own.
func TestDetectInstallsWhatTheConfigNames(t *testing.T) {
	f := newFake(t)
	f.env["FAKE_SSH_PERSON_KNOWS"] = "1"
	config := filepath.Join(f.dir, "ssh_config")
	os.WriteFile(config, []byte("Host devbox\n  HostName devbox.lan\nHost mine\n"), 0o600)
	var steps []string
	i := f.installer(&fakeCodes{}, &steps)
	i.ConfigFile = config
	i.KnownNames = func(context.Context) []string { return []string{"MINE"} }

	got, err := i.Detect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := []DetectedServer{
		{Alias: "devbox", Resolved: "agents@devbox", Outcome: Added},
		detected(Resolved{"mine", map[string]string{"user": "agents", "hostname": "mine", "port": "22"}}, Known, "Already a host."),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%+v", got)
	}
	if _, err := os.Stat(f.server("root/control-join-code")); err != nil {
		t.Fatal("devbox was not installed")
	}

	hosts, err := i.SSHHosts(context.Background(), "  ")
	if err != nil || len(hosts.([]SSHHost)) != 2 {
		t.Fatalf("%v %v", hosts, err)
	}
	one, _ := i.SSHHosts(context.Background(), "agents@ws:2200")
	if got := one.([]SSHHost); len(got) != 1 || got[0].Alias != "agents@ws:2200" {
		t.Fatalf("%+v", got)
	}
}

func TestAServerThatDoesNotLetSSHInIsUnreachable(t *testing.T) {
	f := newFake(t)
	config := filepath.Join(f.dir, "ssh_config")
	os.WriteFile(config, []byte("Host devbox\n"), 0o600)
	var steps []string
	i := f.installer(&fakeCodes{}, &steps)
	i.ConfigFile = config
	got, _ := i.Detect(context.Background())
	servers := got.([]DetectedServer)
	if len(servers) != 1 || servers[0].Outcome != Unreachable || servers[0].Detail == nil ||
		*servers[0].Detail != "The server’s host key isn’t in your known_hosts. Add it over ssh to see the key and trust it." {
		t.Fatalf("%+v", servers)
	}
}
