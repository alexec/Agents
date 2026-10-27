// Package hosttunnels is HostTunnels.swift: reverse tunnels for servers behind a
// bastion (#435), or for any server the person asked for one (#610).
//
// A host joins by dialling the control plane. A server that this machine reaches only
// through a ProxyJump or ProxyCommand can rarely dial back. For such a server,
// machines/install gives a code whose address is https://127.0.0.1:<port> and leaves a
// record here. This holds "ssh -N -R" to it, so that address on the server is this
// control plane's listener. The certificate is checked by its pin, so the name does not
// matter.
//
//   - The session is the person's own ssh, with their config, agent and keys. Its known
//     hosts file holds only the key trusted at the install, or it is the person's own
//     known_hosts when the key was already there. No key is kept (#413).
//   - Only our forward rides it (#610): the config's forwards are cleared, and a forward
//     the server will not open ends the session with ssh's reason.
//   - It is held while the server is a host. A session that drops starts again, sooner
//     when it lasted longer, and at once when this machine wakes or its network
//     changes. A record whose host was removed goes, and so does one whose host never
//     joined.
//   - Only one copy holds tunnels (Agents Host's): the ssh is this machine's.
package hosttunnels

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Record is HostTunnels.Record, stored as v1/tunnels/<id>.json. Its fields are the
// same as hostinstall.TunnelRecord's, so one converts to the other:
// hosttunnels.Record(r).
type Record struct {
	ID string `json:"id"`
	// Destination is as typed: user@host, user@host:port, or a name from the ssh config.
	Destination string `json:"destination"`
	Name        string `json:"name"`
	// Port is the port on both ends: the server's loopback, this machine's listener.
	Port int `json:"port"`
	// Code is the host code's id: its spend says which host this carries.
	Code string  `json:"code"`
	Host *string `json:"host,omitempty"`
	// KnownHosts is the server's host key, as trusted at the install, in known_hosts
	// form. Empty when the person's own known_hosts had it (#610).
	KnownHosts string        `json:"knownHosts"`
	Made       records.Stamp `json:"made"`
}

// Tunnel is DaemonAPI.MachineTunnel: whether ssh has the server's end of the tunnel open
// now, and why not, in ssh's words, when it said any.
type Tunnel = wire.MachineTunnel

// Changed is DaemonAPI.MachineTunnelChanged, the params of control/tunnelChanged. It is
// by name, because a server's tunnel is up before it joins.
type Changed = wire.MachineTunnelChanged

// Prefix is HostTunnels.prefix.
const Prefix = "v1/tunnels/"

// Key is HostTunnels.key.
func Key(id string) string { return Prefix + id + ".json" }

// codeKey and spentKey are ControlCodes.key and ControlCodes.spentKey.
func codeKey(id string) string  { return "v1/codes/" + id + ".json" }
func spentKey(id string) string { return "v1/codes/" + id + ".spent" }

// UnjoinedKept is HostTunnels.unjoinedKept: a server that has not joined by then never
// will with that code (ControlCode.lifetime and ten minutes).
const UnjoinedKept = 5*time.Minute + 10*time.Minute

// Config is what HostTunnels.init takes.
type Config struct {
	Store store.Store
	// SSH is the ssh to run: "" is AGENTS_SSH, else DefaultSSH.
	SSH string
	// Env is the environment ssh runs with. Nil is this process's own, less what
	// MachineInstall.environment(keepAgent: true) takes out.
	Env []string
	// ConfigFile is an ssh config for tests, given with -F: "" is AGENTS_SSH_CONFIG,
	// else the person's own ~/.ssh/config.
	ConfigFile string
	// Port is the port on both ends: this machine's listener (configuration.port).
	Port int
	// Hosts are the control plane's hosts now (methods.allHosts).
	Hosts func(ctx context.Context) []records.MachineRecord
	// Changed is told when a tunnel comes up or goes down. Nil: nobody.
	Changed func(Changed)
	// Log takes a line for the log. Nil: none.
	Log func(string)
	// Asleep is whether a host's workspace is stopped, or being stopped, by its provider
	// (#864). Its tunnel waits and does not dial: through gh, a connection to a codespace
	// starts it again. Nil: never.
	Asleep func(host string) bool
	// Listed is the ssh destination a host's workspace is listed with now, as one word
	// ssh takes, or "" for none (#1691). A VM can have a new address at each start: its
	// tunnel dials the listed one, not the install's. Nil: none.
	Listed func(host string) string
}

// asleepCheck is how often a tunnel whose host is asleep asks again.
var asleepCheck = 5 * time.Second

// Tunnels is the HostTunnels actor.
type Tunnels struct {
	store   store.Store
	ssh     sshCommand
	port    int
	hosts   func(ctx context.Context) []records.MachineRecord
	changed func(Changed)
	log     func(string)
	asleep  func(host string) bool
	listed  func(host string) string
	// folder is short: a control socket's path must fit in 104 bytes, with ssh's suffix.
	folder string

	// work keeps Add and Reconcile one at a time, as the actor does across its awaits.
	work sync.Mutex
	// say keeps each change and its callback in order.
	say sync.Mutex

	mu      sync.Mutex
	records map[string]Record
	held    map[string]*holding
	states  map[string]Tunnel
	stopped bool
	ticker  context.CancelFunc
	running sync.WaitGroup
}

// holding is one held tunnel: its loop's cancel, and a channel closed when it ends.
type holding struct {
	cancel context.CancelFunc
	done   chan struct{}
}

// New is HostTunnels.init.
func New(c Config) *Tunnels {
	executable := c.SSH
	if executable == "" {
		executable = sshExecutable()
	}
	env := c.Env
	if env == nil {
		env = environment(os.Environ())
	}
	hosts := c.Hosts
	if hosts == nil {
		hosts = func(context.Context) []records.MachineRecord { return nil }
	}
	log := c.Log
	if log == nil {
		log = func(string) {}
	}
	changed := c.Changed
	if changed == nil {
		changed = func(Changed) {}
	}
	asleep := c.Asleep
	if asleep == nil {
		asleep = func(string) bool { return false }
	}
	listed := c.Listed
	if listed == nil {
		listed = func(string) string { return "" }
	}
	return &Tunnels{
		store:   c.Store,
		ssh:     sshCommand{executable: executable, env: env, options: configFile(c.ConfigFile)},
		port:    c.Port,
		hosts:   hosts,
		changed: changed,
		log:     log,
		asleep:  asleep,
		listed:  listed,
		folder:  fmt.Sprintf("/tmp/agents-tunnels-%d-%d", os.Getuid(), os.Getpid()),
		records: map[string]Record{},
		held:    map[string]*holding{},
		states:  map[string]Tunnel{},
	}
}

// Port is the port on both ends, for hostinstall's Tunnels.
func (t *Tunnels) Port() int { return t.port }

// Start is HostTunnels.start: it takes up the records and keeps them true every
// every (15 seconds when 0). A tick that took far longer on the wall clock than on the
// monotonic clock, which stops while this machine sleeps, is a wake. Then every session
// starts again, and does not wait for ServerAlive to give up on a dead connection. A
// change of the network starts every session again too.
func (t *Tunnels) Start(every time.Duration) {
	if every <= 0 {
		every = 15 * time.Second
	}
	t.mu.Lock()
	if t.ticker != nil {
		t.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.ticker = cancel
	t.stopped = false
	t.mu.Unlock()
	go func() {
		for ctx.Err() == nil {
			t.Reconcile(ctx)
			before := time.Now()
			select {
			case <-ctx.Done():
				return
			case <-time.After(every):
			}
			after := time.Now()
			// Round(0) drops the monotonic reading: what is left is the wall clock.
			if after.Round(0).Sub(before.Round(0))-after.Sub(before) > 5*time.Second {
				t.Restart("this Mac woke")
			}
		}
	}()
	go t.watchNetwork(ctx)
}

// Restart is HostTunnels.restart: every session starts again now, and the waits
// between tries are forgotten.
func (t *Tunnels) Restart(why string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.held) == 0 {
		return
	}
	t.log("tunnels: " + why + "; starting every session again")
	old := t.held
	t.held = map[string]*holding{}
	for _, h := range old {
		h.cancel()
	}
	for id, record := range t.records {
		t.holdLocked(record, old[id])
	}
}

// Stop is HostTunnels.stop. It also waits for every session's ssh to end.
func (t *Tunnels) Stop() {
	t.mu.Lock()
	if t.ticker != nil {
		t.ticker()
		t.ticker = nil
	}
	t.stopped = true
	for _, h := range t.held {
		h.cancel()
	}
	t.held = map[string]*holding{}
	t.mu.Unlock()
	t.running.Wait()
	os.RemoveAll(t.folder)
}

// LetGo drops every tunnel held for destination: name was installed on that server, so
// the host they carried is replaced, and their forward would take the port the new one
// needs. A session that goes cancels its forward first (#1769).
func (t *Tunnels) LetGo(ctx context.Context, destination, name string) {
	t.work.Lock()
	defer t.work.Unlock()
	t.letGoLocked(ctx, destination, name)
}

func (t *Tunnels) letGoLocked(ctx context.Context, destination, name string) {
	t.mu.Lock()
	var olds []Record
	for _, old := range t.records {
		if strings.EqualFold(old.Destination, destination) {
			olds = append(olds, old)
		}
	}
	t.mu.Unlock()
	for _, old := range olds {
		t.log("tunnel to " + old.Name + ": " + name + " was installed on that server; letting go")
		t.store.Delete(ctx, Key(old.ID))
		t.mu.Lock()
		t.forgetLocked(old.ID)
		t.mu.Unlock()
	}
}

// Add is HostTunnels.add: a tunnel for a server just installed, held at once so its
// first dial finds it. One held before for the same destination goes (LetGo).
func (t *Tunnels) Add(ctx context.Context, record Record) error {
	t.work.Lock()
	defer t.work.Unlock()
	t.letGoLocked(ctx, record.Destination, record.Name)
	data, err := records.Encode(record)
	if err != nil {
		return err
	}
	if _, err := t.store.Put(ctx, Key(record.ID), data, store.Absent); err != nil {
		return err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.records[record.ID] = record
	t.holdLocked(record, nil)
	return nil
}

// forgetLocked drops a record, its session and its state.
func (t *Tunnels) forgetLocked(id string) {
	delete(t.records, id)
	if h := t.held[id]; h != nil {
		h.cancel()
		delete(t.held, id)
	}
	delete(t.states, id)
}

// State is HostTunnels.state(for:): how the tunnel for this host stands, or nil when it
// has none.
func (t *Tunnels) State(host string) *Tunnel {
	t.mu.Lock()
	defer t.mu.Unlock()
	for id, record := range t.records {
		if record.Host != nil && *record.Host == host {
			state := t.states[id]
			return &state
		}
	}
	return nil
}

// Installed is HostTunnels.installed(for:): where this host was installed over ssh,
// and its key as trusted then (empty when the person's own known_hosts had it), for
// starting its agentsd again (#965). ok is false when no tunnel carries it.
func (t *Tunnels) Installed(host string) (destination, knownHosts string, ok bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, record := range t.records {
		if record.Host != nil && *record.Host == host {
			return record.Destination, record.KnownHosts, true
		}
	}
	return "", "", false
}

// Repin keeps a new host key for this host's tunnel, in known_hosts form (#1701): a
// workspace whose host key is made again at each start, as an ssh start the control plane
// made after its own Start has just taken it. Its session starts again at once with it.
// ok is false when no tunnel carries the host.
func (t *Tunnels) Repin(ctx context.Context, host, knownHosts string) (bool, error) {
	t.work.Lock()
	defer t.work.Unlock()
	t.mu.Lock()
	var record Record
	found := false
	for _, r := range t.records {
		if r.Host != nil && *r.Host == host {
			record, found = r, true
			break
		}
	}
	t.mu.Unlock()
	if !found {
		return false, nil
	}
	record.KnownHosts = knownHosts
	data, err := records.Encode(record)
	if err != nil {
		return true, err
	}
	// Only this copy writes tunnels, so nobody else's write can be lost.
	if _, err := t.store.Put(ctx, Key(record.ID), data, store.Always); err != nil {
		return true, err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.records[record.ID] = record
	t.log("tunnel to " + record.Name + ": its workspace's new host key is kept")
	if old := t.held[record.ID]; old != nil {
		old.cancel()
		delete(t.held, record.ID)
		t.holdLocked(record, old)
	}
	return true, nil
}

// Unjoined is HostTunnels.unjoined(): the servers whose tunnel is held but who have not
// joined yet, by name, oldest first (#660). They have no host row, so the window lists
// them with how the tunnel stands.
func (t *Tunnels) Unjoined() []Changed {
	t.mu.Lock()
	defer t.mu.Unlock()
	var waiting []Record
	for _, record := range t.records {
		if record.Host == nil {
			waiting = append(waiting, record)
		}
	}
	sort.Slice(waiting, func(i, j int) bool { return waiting[i].Made.Before(waiting[j].Made.Time) })
	out := []Changed{}
	for _, record := range waiting {
		out = append(out, Changed{Name: record.Name, Tunnel: t.states[record.ID]})
	}
	return out
}

// Reconcile is HostTunnels.reconcile: it reads the records again, learns which host
// each carries, lets go of those nobody needs, and holds the rest.
func (t *Tunnels) Reconcile(ctx context.Context) {
	t.work.Lock()
	defer t.work.Unlock()
	keys, err := t.store.List(ctx, Prefix)
	if err != nil {
		return
	}
	read := map[string]Record{}
	for _, key := range keys {
		object, err := t.store.Get(ctx, key.Key)
		if err != nil || object == nil {
			continue
		}
		var record Record
		if json.Unmarshal(object.Data, &record) != nil || record.ID == "" {
			continue
		}
		read[record.ID] = record
	}
	known := t.hosts(ctx)
	ids := make([]string, 0, len(read))
	for id := range read {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		record := read[id]
		if record.Host == nil {
			if host := t.joined(ctx, record, known); host != nil {
				record.Host = host
				// Only this copy writes tunnels, so nobody else's write can be lost.
				if data, err := records.Encode(record); err == nil {
					t.store.Put(ctx, Key(record.ID), data, store.Always)
				}
				read[id] = record
			}
		}
		var gone bool
		if record.Host != nil {
			gone = true
			for _, h := range known {
				if h.ID == *record.Host {
					gone = false
					break
				}
			}
		} else {
			gone = time.Since(record.Made.Time) > UnjoinedKept
		}
		if gone {
			t.log("tunnel to " + record.Name + ": no longer a host; letting go")
			t.store.Delete(ctx, Key(record.ID))
			delete(read, id)
		}
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.records = read
	for id, h := range t.held {
		if _, ok := read[id]; !ok {
			h.cancel()
			delete(t.held, id)
			delete(t.states, id)
		}
	}
	for _, record := range read {
		t.holdLocked(record, nil)
	}
}

// joined is HostTunnels.joined: the host that spent this record's code. When the code
// has been swept, it is a host of the record's name that no other tunnel carries.
func (t *Tunnels) joined(ctx context.Context, record Record, known []records.MachineRecord) *string {
	if object, err := t.store.Get(ctx, spentKey(record.Code)); err == nil && object != nil {
		var spent struct {
			Host *string `json:"host"`
		}
		if json.Unmarshal(object.Data, &spent) == nil && spent.Host != nil {
			return spent.Host
		}
	}
	if object, err := t.store.Get(ctx, codeKey(record.Code)); err != nil || object == nil {
		t.mu.Lock()
		carried := map[string]bool{}
		for _, r := range t.records {
			if r.Host != nil {
				carried[*r.Host] = true
			}
		}
		t.mu.Unlock()
		for _, h := range known {
			if h.Name == record.Name && !carried[h.ID] {
				id := h.ID
				return &id
			}
		}
	}
	return nil
}

// holdLocked is HostTunnels.hold: one session after another, until let go. A session
// that lasted is tried again soon; one that keeps failing, less often. after is the
// session before it, which must end first: both would use the same control socket.
func (t *Tunnels) holdLocked(record Record, after *holding) {
	if t.held[record.ID] != nil || t.stopped {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	h := &holding{cancel: cancel, done: make(chan struct{})}
	t.held[record.ID] = h
	t.running.Add(1)
	go func() {
		defer t.running.Done()
		defer close(h.done)
		if after != nil {
			select {
			case <-after.done:
			case <-ctx.Done():
				return
			}
		}
		wait := 2 * time.Second
		for ctx.Err() == nil {
			// The record as it is now: Reconcile and Repin change it under a held session.
			t.mu.Lock()
			if now, ok := t.records[record.ID]; ok {
				record = now
			}
			t.mu.Unlock()
			// A stopped workspace is not dialled, or the dial would start it again (#864).
			if record.Host != nil && t.asleep(*record.Host) {
				words := "Its workspace is stopped: the tunnel waits for Start."
				t.sayState(ctx, record.ID, Tunnel{Up: false, Problem: &words})
				select {
				case <-ctx.Done():
					return
				case <-time.After(asleepCheck):
				}
				wait = 2 * time.Second
				continue
			}
			ssh := t.ssh
			ssh.name = record.Destination
			if record.Host != nil {
				if listed := t.listed(*record.Host); listed != "" {
					ssh.name = listed
				}
			}
			started := time.Now()
			problem := session(ctx, record, ssh, t.folder, func() { t.sayState(ctx, record.ID, Tunnel{Up: true}) })
			if ctx.Err() != nil {
				return
			}
			words := worded(problem)
			t.sayState(ctx, record.ID, Tunnel{Up: false, Problem: &words})
			if time.Since(started) > 60*time.Second {
				wait = 2 * time.Second
			} else {
				wait = min(wait*2, 60*time.Second)
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(wait):
			}
		}
	}()
}

// sayState is HostTunnels.say: a new state is kept, logged and told.
func (t *Tunnels) sayState(ctx context.Context, id string, state Tunnel) {
	t.say.Lock()
	defer t.say.Unlock()
	t.mu.Lock()
	record, ok := t.records[id]
	if !ok || ctx.Err() != nil || sameTunnel(t.states[id], state) {
		t.mu.Unlock()
		return
	}
	t.states[id] = state
	t.mu.Unlock()
	line := "tunnel to " + record.Name + ": "
	if state.Up {
		line += "up"
	} else {
		line += "down"
		if state.Problem != nil {
			line += ": " + *state.Problem
		}
	}
	t.log(line)
	t.changed(Changed{Name: record.Name, Host: (*wire.MachineRef)(record.Host), Tunnel: state})
}

func sameTunnel(a, b Tunnel) bool {
	if a.Up != b.Up || (a.Problem == nil) != (b.Problem == nil) {
		return false
	}
	return a.Problem == nil || *a.Problem == *b.Problem
}

// worded is HostTunnels.worded: why a session ended, in words where ssh's are known
// (#965). "Connection to UNKNOWN port 65535 timed out", from a codespace still waking,
// says it did not answer.
func worded(problem string) string {
	if strings.Contains(problem, "Connection to ") && strings.Contains(problem, " timed out") {
		return sayTimedOut
	}
	if said, ok := classified(problem); ok {
		return said
	}
	return problem
}
