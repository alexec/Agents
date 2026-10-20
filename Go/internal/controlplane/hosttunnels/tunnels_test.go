package hosttunnels

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// These port HostTunnelsTests.swift: a server behind a bastion dials the control plane
// through a reverse tunnel held over ssh (#435).

var ctx = context.Background()

func TestATunnelsEndIsSaidInWords(t *testing.T) {
	// A codespace still waking, through `gh codespace ssh` (#965).
	if got := worded("Connection to UNKNOWN port 65535 timed out"); got != "It did not answer: the connection timed out or was refused." {
		t.Errorf("timed out: %q", got)
	}
	if got := worded("No ED25519 host key is known for cs and you have requested strict checking."); got != sayHostKeyUnknown {
		t.Errorf("host key unknown: %q", got)
	}
	if got := worded("the ssh session ended"); got != "the ssh session ended" {
		t.Errorf("ended: %q", got)
	}
}

func TestTheTunnelIsAMasterOfItsOwnThatOpensNoForwardOfTheConfigs(t *testing.T) {
	ssh := sshCommand{name: "agents@ws:2222"}
	control := "/tmp/agents-tunnels-1-2/abcd1234.ctl"
	master := ssh.tunnelMasterArguments(control)
	if !slices.Contains(master, "-M") || !slices.Contains(master, "-N") {
		t.Errorf("not a master: %v", master)
	}
	if i := slices.Index(master, "-S"); i < 0 || master[i+1] != control {
		t.Errorf("no control socket: %v", master)
	}
	for _, option := range []string{"ControlPersist=no", "ExitOnForwardFailure=yes", "BatchMode=yes",
		// #610: the config's forwards are not opened, and its RemoteCommand and
		// RequestTTY cannot break -N.
		"ClearAllForwardings=yes", "RemoteCommand=none", "RequestTTY=no"} {
		if !slices.Contains(master, option) {
			t.Errorf("no %s: %v", option, master)
		}
	}
	// ClearAllForwardings clears a -R on the command line too, so there is none here…
	for _, flag := range []string{"-R", "-L", "-D"} {
		if slices.Contains(master, flag) {
			t.Errorf("a %s: %v", flag, master)
		}
	}
	if tail := master[len(master)-2:]; !reflect.DeepEqual(tail, []string{"--", "ssh://agents@ws:2222"}) {
		t.Errorf("ends %v", tail)
	}
	// …and the one forward is asked of the master.
	if got := ssh.tunnelForwardArguments(control, 8791, 8792); !reflect.DeepEqual(got, []string{
		"-S", control, "-O", "forward", "-R", "127.0.0.1:8791:127.0.0.1:8792", "--", "ssh://agents@ws:2222"}) {
		t.Errorf("forward: %v", got)
	}
	if got := ssh.tunnelControlArguments(control, "check"); !reflect.DeepEqual(got, []string{
		"-S", control, "-O", "check", "--", "ssh://agents@ws:2222"}) {
		t.Errorf("check: %v", got)
	}
}

func TestARefusedForwardIsSaidInSSHsWords(t *testing.T) {
	for stderr, want := range map[string]string{
		"mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 8791\nmuxclient: master forward request failed\n": "remote port forwarding failed for listen port 8791",
		"debug1: x\nControl socket connect(/tmp/x.ctl): No such file or directory\n":                                                                    "Control socket connect(/tmp/x.ctl): No such file or directory",
		"": "the server would not open the tunnel's forward",
	} {
		if got := forwardFailure(stderr); got != want {
			t.Errorf("%q: %q", stderr, got)
		}
	}
}

func TestOnlySSHsOwnWordsAreKeptAsTheReason(t *testing.T) {
	for line, want := range map[string]string{
		"debug1: Connecting to ws port 22.":                           "",
		"OpenSSH_9.8p1, LibreSSL 3.3.6":                               "",
		"Warning: remote port forwarding failed for listen port 8791": "remote port forwarding failed for listen port 8791",
		"agents@ws: Permission denied (publickey).":                   "agents@ws: Permission denied (publickey).",
	} {
		if got, _ := said(line); got != want {
			t.Errorf("%q: %q", line, got)
		}
	}
	// Lines come in pieces; the last one worth saying is kept.
	var heard sessionLines
	heard.take([]byte("debug1: x\nagents@ws: Permi"))
	heard.take([]byte("ssion denied (publickey).\nTransferred: 0\n"))
	if got := heard.problem(); got != "agents@ws: Permission denied (publickey)." {
		t.Errorf("heard %q", got)
	}
}

func TestASessionIsUpWhenTheForwardIsOpenAndDownWithSSHsReasonWhenItIsRefused(t *testing.T) {
	folder := t.TempDir()
	log := filepath.Join(folder, "argv")
	up := fakeSSH(t, folder, "up", log, "exit 0", "exec sleep 30")
	heard := &heardChanges{}
	tunnels := newTunnels(store.NewMemory(), up, heard, []records.HostRecord{{ID: "ws", Name: "ws"}})
	if err := tunnels.Add(ctx, record("ws")); err != nil {
		t.Fatal(err)
	}
	heard.waitFor(t, func(c Changed) bool { return c.Tunnel.Up })
	if got := tunnels.State("ws"); got == nil || !sameTunnel(*got, Tunnel{Up: true}) {
		t.Errorf("state %+v", got)
	}
	tunnels.Stop()
	calls, _ := os.ReadFile(log)
	if !strings.Contains(string(calls), "-O forward -R 127.0.0.1:8791:127.0.0.1:8791") {
		t.Errorf("no forward asked: %s", calls)
	}
	if !strings.Contains(string(calls), "ClearAllForwardings=yes") {
		t.Errorf("forwards not cleared: %s", calls)
	}

	// The server will not open it: the master is ended, and the reason is ssh's.
	refused := fakeSSH(t, folder, "refused", "", `echo "mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 8791" >&2
echo "muxclient: master forward request failed" >&2
exit 255`, "exec sleep 30")
	failing := &heardChanges{}
	other := newTunnels(store.NewMemory(), refused, failing, []records.HostRecord{{ID: "ws", Name: "ws"}})
	if err := other.Add(ctx, record("ws")); err != nil {
		t.Fatal(err)
	}
	// Wait for ssh's reason, not the first change: under load an earlier state can come first (#851).
	refusal := Tunnel{Problem: ptr("remote port forwarding failed for listen port 8791")}
	failing.waitFor(t, func(c Changed) bool { return sameTunnel(c.Tunnel, refusal) })
	if got := other.State("ws"); got == nil || !sameTunnel(*got, refusal) {
		t.Errorf("state %+v, changes %+v", got, failing.all())
	}
	other.Stop()

	// ssh itself gave up: its last words, said as an install says them (#965).
	denied := fakeSSH(t, folder, "denied", "", "exit 255", `echo "agents@ws: Permission denied (publickey)." >&2
exit 255`)
	refusing := &heardChanges{}
	third := newTunnels(store.NewMemory(), denied, refusing, []records.HostRecord{{ID: "ws", Name: "ws"}})
	if err := third.Add(ctx, record("ws")); err != nil {
		t.Fatal(err)
	}
	denial := Tunnel{Problem: ptr("The server refused that key.")}
	refusing.waitFor(t, func(c Changed) bool { return sameTunnel(c.Tunnel, denial) })
	if got := third.State("ws"); got == nil || !sameTunnel(*got, denial) {
		t.Errorf("state %+v, changes %+v", got, refusing.all())
	}
	third.Stop()
}

func TestAMasterThatNeverAnswersIsEnded(t *testing.T) {
	was := connecting
	connecting = time.Second
	defer func() { connecting = was }()
	folder := t.TempDir()
	// -O check never answers yes.
	never := filepath.Join(folder, "never")
	os.WriteFile(never, []byte("#!/bin/sh\nfor word in \"$@\"; do [ \"$word\" = check ] && exit 255; done\nexec sleep 30\n"), 0o755)
	heard := &heardChanges{}
	tunnels := newTunnels(store.NewMemory(), never, heard, []records.HostRecord{{ID: "ws", Name: "ws"}})
	defer tunnels.Stop()
	if err := tunnels.Add(ctx, record("ws")); err != nil {
		t.Fatal(err)
	}
	heard.waitFor(t, func(c Changed) bool {
		return c.Tunnel.Problem != nil && *c.Tunnel.Problem == "ssh did not connect within 1 seconds"
	})
}

func TestAWakeStartsEverySessionAgain(t *testing.T) {
	folder := t.TempDir()
	log := filepath.Join(folder, "argv")
	ssh := fakeSSH(t, folder, "up", log, "exit 0", "exec sleep 30")
	heard := &heardChanges{}
	tunnels := newTunnels(store.NewMemory(), ssh, heard, []records.HostRecord{{ID: "ws", Name: "ws"}})
	defer tunnels.Stop()
	if err := tunnels.Add(ctx, record("ws")); err != nil {
		t.Fatal(err)
	}
	heard.waitFor(t, func(c Changed) bool { return c.Tunnel.Up })
	tunnels.Restart("this Mac woke")
	eventually(t, func() bool {
		calls, _ := os.ReadFile(log)
		return strings.Count(string(calls), "-O forward") == 2
	})
}

func TestATunnelLearnsItsHostFromTheCodeAndGoesWhenTheHostDoes(t *testing.T) {
	folder := t.TempDir()
	sleeper := fakeSSH(t, folder, "sleep", "", "exit 0", "exec sleep 30")
	memory := store.NewMemory()
	known := &knownHosts{hosts: []records.HostRecord{{ID: "ws", Name: "ws"}}}
	tunnels := New(Config{Store: memory, SSH: sleeper, Env: []string{}, Port: 8791, Hosts: known.get})
	defer tunnels.Stop()
	r := record("")
	if err := tunnels.Add(ctx, r); err != nil {
		t.Fatal(err)
	}
	if tunnels.State("ws") != nil {
		t.Error("a host before it joined")
	}
	// Not joined yet: listed by name, so the window can say how it stands (#660).
	if got := tunnels.Unjoined(); len(got) != 1 || got[0].Name != "ws" || got[0].Host != nil {
		t.Errorf("unjoined %+v", got)
	}

	// The host's join spends the code: the tunnel is that host's from then on.
	memory.Put(ctx, codeKey(r.Code), []byte("{}"), store.Absent)
	memory.Put(ctx, spentKey(r.Code), []byte(`{"publicKey":"AQ==","host":"ws"}`), store.Absent)
	tunnels.Reconcile(ctx)
	if tunnels.State("ws") == nil {
		t.Error("the tunnel did not learn its host")
	}
	if got := tunnels.Unjoined(); len(got) != 0 {
		t.Errorf("unjoined %+v", got)
	}
	if destination, keys, ok := tunnels.Installed("ws"); !ok || destination != "agents@ws" || keys != r.KnownHosts {
		t.Errorf("installed %q %q %v", destination, keys, ok)
	}
	stored, _ := memory.Get(ctx, Key(r.ID))
	var back Record
	if stored == nil || json.Unmarshal(stored.Data, &back) != nil || back.Host == nil || *back.Host != "ws" {
		t.Errorf("stored %v", stored)
	}

	// Removed: the tunnel and its record go.
	known.set(nil)
	tunnels.Reconcile(ctx)
	if tunnels.State("ws") != nil {
		t.Error("the tunnel stayed")
	}
	if keys, _ := memory.List(ctx, Prefix); len(keys) != 0 {
		t.Errorf("records left: %v", keys)
	}
}

func TestATunnelLearnsItsHostByNameWhenTheCodeIsSwept(t *testing.T) {
	folder := t.TempDir()
	sleeper := fakeSSH(t, folder, "sleep", "", "exit 0", "exec sleep 30")
	memory := store.NewMemory()
	tunnels := newTunnels(memory, sleeper, &heardChanges{}, []records.HostRecord{{ID: "h1", Name: "ws"}})
	defer tunnels.Stop()
	if err := tunnels.Add(ctx, record("")); err != nil {
		t.Fatal(err)
	}
	tunnels.Reconcile(ctx)
	if tunnels.State("h1") == nil {
		t.Error("not learnt by name")
	}
}

func TestTheSameServerAddedAgainLetsItsOldTunnelGo(t *testing.T) {
	folder := t.TempDir()
	sleeper := fakeSSH(t, folder, "sleep", "", "exit 0", "exec sleep 30")
	memory := store.NewMemory()
	tunnels := newTunnels(memory, sleeper, &heardChanges{}, nil)
	defer tunnels.Stop()
	if err := tunnels.Add(ctx, record("")); err != nil {
		t.Fatal(err)
	}
	second := record("")
	second.Destination = "AGENTS@ws"
	if err := tunnels.Add(ctx, second); err != nil {
		t.Fatal(err)
	}
	keys, _ := memory.List(ctx, Prefix)
	if len(keys) != 1 || keys[0].Key != Key(second.ID) {
		t.Errorf("records %v", keys)
	}
}

func TestAServerThatNeverJoinedIsLetGo(t *testing.T) {
	folder := t.TempDir()
	sleeper := fakeSSH(t, folder, "sleep", "", "exit 0", "exec sleep 30")
	memory := store.NewMemory()
	stale := record("")
	stale.Made = records.At(time.Now().Add(-UnjoinedKept - time.Second))
	data, _ := records.Encode(stale)
	memory.Put(ctx, Key(stale.ID), data, store.Absent)
	tunnels := newTunnels(memory, sleeper, &heardChanges{}, nil)
	defer tunnels.Stop()
	tunnels.Reconcile(ctx)
	if keys, _ := memory.List(ctx, Prefix); len(keys) != 0 {
		t.Errorf("records left: %v", keys)
	}
}

// The JSON is Swift's: the record as ControlRecords.encoder writes it, the change as
// JSONEncoder does, with nil left out.
func TestTheJSONIsSwifts(t *testing.T) {
	r := Record{ID: "a", Destination: "agents@ws", Name: "ws", Port: 8791, Code: "c", KnownHosts: "",
		Made: records.At(time.Date(2026, 10, 16, 12, 0, 0, 5e6, time.UTC))}
	data, err := records.Encode(r)
	if err != nil {
		t.Fatal(err)
	}
	want := `{
  "code": "c",
  "destination": "agents@ws",
  "id": "a",
  "knownHosts": "",
  "made": "2026-10-16T12:00:00.005Z",
  "name": "ws",
  "port": 8791
}`
	if string(data) != want {
		t.Errorf("stored\n%s", data)
	}
	change, _ := json.Marshal(Changed{Name: "ws", Tunnel: Tunnel{}})
	if string(change) != `{"name":"ws","tunnel":{"up":false}}` {
		t.Errorf("change %s", change)
	}
	change, _ = json.Marshal(Changed{Name: "ws", Host: new(wire.HostID("h")), Tunnel: Tunnel{Problem: ptr("p")}})
	if string(change) != `{"name":"ws","host":"h","tunnel":{"up":false,"problem":"p"}}` {
		t.Errorf("change %s", change)
	}
}

// Helpers

func ptr(s string) *string { return &s }

func record(host string) Record {
	r := Record{ID: records.NewPersonID(), Destination: "agents@ws", Name: "ws", Port: 8791,
		Code: records.NewPersonID(), KnownHosts: "ws ssh-ed25519 AAAA\n", Made: records.Now()}
	if host != "" {
		r.Host = &host
	}
	return r
}

func newTunnels(s store.Store, ssh string, heard *heardChanges, hosts []records.HostRecord) *Tunnels {
	return New(Config{Store: s, SSH: ssh, Env: []string{}, Port: 8791,
		Hosts:   func(context.Context) []records.HostRecord { return hosts },
		Changed: heard.add})
}

// fakeSSH is a stand-in for ssh: "-O check" answers, "-O forward" runs forward, and
// anything else is the master, running master. Every call's arguments go to log.
func fakeSSH(t *testing.T, folder, name, log, forward, master string) string {
	t.Helper()
	file := filepath.Join(folder, name)
	logging := ""
	if log != "" {
		logging = "printf '%s\\n' \"$*\" >> '" + log + "'\n"
	}
	script := "#!/bin/sh\n" + logging + `op=""
for word in "$@"; do [ "$previous" = "-O" ] && op="$word"; previous="$word"; done
case "$op" in
    check) exit 0 ;;
    forward)
` + forward + `
    ;;
esac
` + master + "\n"
	if err := os.WriteFile(file, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return file
}

func eventually(t *testing.T, condition func() bool) {
	t.Helper()
	for i := 0; i < 200 && !condition(); i++ {
		time.Sleep(50 * time.Millisecond)
	}
	if !condition() {
		t.Error("never")
	}
}

type heardChanges struct {
	mu      sync.Mutex
	changes []Changed
}

func (h *heardChanges) add(c Changed) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.changes = append(h.changes, c)
}

func (h *heardChanges) all() []Changed {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.changes)
}

func (h *heardChanges) waitFor(t *testing.T, condition func(Changed) bool) {
	t.Helper()
	eventually(t, func() bool { return slices.ContainsFunc(h.all(), condition) })
	if !slices.ContainsFunc(h.all(), condition) {
		t.Fatalf("changes %+v", h.all())
	}
}

type knownHosts struct {
	mu    sync.Mutex
	hosts []records.HostRecord
}

func (k *knownHosts) get(context.Context) []records.HostRecord {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.hosts
}

func (k *knownHosts) set(hosts []records.HostRecord) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.hosts = hosts
}

// A host whose workspace is stopped is not dialled: through gh, a dial starts a codespace
// again (#864). Once it is awake, the tunnel dials as before.
func TestATunnelToAStoppedWorkspaceWaitsAndDoesNotDial(t *testing.T) {
	was := asleepCheck
	asleepCheck = 50 * time.Millisecond
	defer func() { asleepCheck = was }()
	folder := t.TempDir()
	log := filepath.Join(folder, "argv")
	ssh := fakeSSH(t, folder, "up", log, "exit 0", "exec sleep 30")
	heard := &heardChanges{}
	var mu sync.Mutex
	asleep := true
	tunnels := New(Config{Store: store.NewMemory(), SSH: ssh, Env: []string{}, Port: 8791,
		Hosts:   func(context.Context) []records.HostRecord { return []records.HostRecord{{ID: "ws", Name: "ws"}} },
		Changed: heard.add,
		Asleep: func(host string) bool {
			mu.Lock()
			defer mu.Unlock()
			return host == "ws" && asleep
		}})
	defer tunnels.Stop()
	if err := tunnels.Add(ctx, record("ws")); err != nil {
		t.Fatal(err)
	}
	heard.waitFor(t, func(c Changed) bool {
		return c.Tunnel.Problem != nil && *c.Tunnel.Problem == "Its workspace is stopped: the tunnel waits for Start."
	})
	time.Sleep(300 * time.Millisecond)
	if calls, _ := os.ReadFile(log); len(calls) != 0 {
		t.Fatalf("dialled a stopped workspace: %s", calls)
	}
	mu.Lock()
	asleep = false
	mu.Unlock()
	heard.waitFor(t, func(c Changed) bool { return c.Tunnel.Up })
}
