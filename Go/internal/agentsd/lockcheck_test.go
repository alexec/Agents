package agentsd

import (
	"crypto/ecdsa"
	"encoding/json"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

// lockedMachine is a machine h-1 that holds sam's lock: the client phone, the machine
// itself, and the machine peer.
func lockedMachine(t *testing.T) (d *Daemon, phone, peer *ecdsa.PrivateKey, state *machinelock.State) {
	t.Helper()
	d, key, _ := joinedMachine(t)
	mac, phone, peer := newLockKey(t), newLockKey(t), newLockKey(t)
	c := []wire.LockEntry{lockEntry(t, mac, wire.LockEntryKindRoot, mac, nil)}
	add := func(body wire.LockBody) {
		h := machinelock.HashOf(c[len(c)-1])
		body.Person, body.Previous, body.At = "sam", h[:], wire.DateOf(time.Now())
		e, err := machinelock.Sign(mac, body)
		if err != nil {
			t.Fatal(err)
		}
		c = append(c, e)
	}
	add(wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: machinelock.PublicKey(phone), ID: new(phoneClient), Name: new("Sam’s iPhone")})
	add(wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: key, SealingKey: key, ID: new("h-1")})
	add(wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: machinelock.PublicKey(peer), SealingKey: machinelock.PublicKey(peer), ID: new("h-2")})
	if !d.TakeLock(wire.Lock{Person: "sam", Entries: c}) {
		t.Fatal("the lock was not taken")
	}
	state, _ = d.heldLock()
	return d, phone, peer, state
}

// phoneClient is the phone's client id, as the signer put it on the lock (#3543).
const phoneClient = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

// channelTo is a channel the control plane opened for a client: what the machine says
// comes back as it came, MAC and all.
func channelTo(d *Daemon) *conn {
	c := newConn()
	go d.Accept(c)
	return c
}

func (c *conn) send(line string) { c.in <- line }

// answer is the next line that answers id.
func (c *conn) answer(t *testing.T, id int) string {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if string(m.ID) == string(mustJSON(id)) {
				return line
			}
		case <-deadline:
			t.Fatalf("no answer to %d", id)
		}
	}
}

func requestLine(id int, method string, params any) string {
	p, _ := json.Marshal(params)
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(p)})
	return string(b)
}

func notInLockAnswer(line string) bool { return strings.Contains(line, `"code":-32104`) }

// hello opens a checked channel on c as the client with key signer.
func hello(t *testing.T, c *conn, state *machinelock.State, signer *ecdsa.PrivateKey) *machinelock.Channel {
	t.Helper()
	h, err := machinelock.NewHello(signer)
	if err != nil {
		t.Fatal(err)
	}
	c.send(requestLine(100, wire.CallLockHello.Name, h.Params))
	var m struct {
		Result *wire.LockHelloReply `json:"result"`
		Error  *Error               `json:"error"`
	}
	json.Unmarshal([]byte(c.answer(t, 100)), &m)
	if m.Result == nil {
		t.Fatalf("lock/hello: %+v", m.Error)
	}
	ch, err := h.Finish(state, "h-1", *m.Result)
	if err != nil {
		t.Fatal(err)
	}
	return ch
}

// #3492, the epic's Done when: a control plane that forges a client, or forwards a request
// with a client's identity it did not sign, is refused by the machine.
func TestAMachineRefusesWhatTheControlPlaneForges(t *testing.T) {
	d, phone, _, state := lockedMachine(t)

	// The control plane's own request, with a client's identity on the channel: refused.
	cp := channelTo(d)
	cp.send(requestLine(1, "folders/list", map[string]any{}))
	if line := cp.answer(t, 1); !notInLockAnswer(line) {
		t.Fatalf("an unsigned request was taken: %s", line)
	}
	// It may ask what it asks for itself, which starts nothing.
	cp.send(requestLine(2, "daemon/ping", map[string]any{}))
	if line := cp.answer(t, 2); notInLockAnswer(line) {
		t.Fatalf("a ping was refused: %s", line)
	}
	// A client it makes up, with a key of its own: refused at the hello.
	forged, _ := machinelock.NewHello(newLockKey(t))
	cp.send(requestLine(3, wire.CallLockHello.Name, forged.Params))
	if line := cp.answer(t, 3); !notInLockAnswer(line) {
		t.Fatalf("a made-up client's hello was taken: %s", line)
	}
	// A MAC it makes up, with no channel.
	cp.send(`{"jsonrpc":"2.0","id":4,"method":"folders/list","params":{},"lock":{"n":1,"mac":"` + strings.Repeat("A", 43) + `="}}`)
	if line := cp.answer(t, 4); !notInLockAnswer(line) {
		t.Fatalf("a made-up MAC was taken: %s", line)
	}

	// The real client opens a channel; its requests are taken, and the answers carry a MAC.
	phoneChannel := channelTo(d)
	ch := hello(t, phoneChannel, state, phone)
	request := requestLine(5, "folders/list", map[string]any{})
	sealed := ch.Seal(request)
	phoneChannel.send(sealed)
	answer := phoneChannel.answer(t, 5)
	body, err := ch.Open(answer)
	if err != nil || notInLockAnswer(body) || !strings.Contains(body, `"result"`) {
		t.Fatalf("the client's request: %s, %v", answer, err)
	}
	// The control plane sends the client's request again: a replay.
	phoneChannel.send(sealed)
	if line := phoneChannel.answer(t, 5); !notInLockAnswer(line) {
		t.Fatalf("a replayed request was taken: %s", line)
	}
	// It changes a byte of the client's next one.
	changed := strings.Replace(ch.Seal(requestLine(6, "folders/list", map[string]any{})), `"folders/list"`, `"folders/lisu"`, 1)
	phoneChannel.send(changed)
	if line := phoneChannel.answer(t, 6); !notInLockAnswer(line) {
		t.Fatalf("a changed request was taken: %s", line)
	}
	// It forwards the client's request on another channel, as that client.
	cp.send(ch.Seal(requestLine(7, "folders/list", map[string]any{})))
	if line := cp.answer(t, 7); !notInLockAnswer(line) {
		t.Fatalf("a request forwarded on another channel was taken: %s", line)
	}
	// It sends the client's hello again on a channel of its own: the machine answers, but
	// the keys are the client's and the machine's alone, so its own MAC does not check.
	again, _ := machinelock.NewHello(phone)
	replay := channelTo(d)
	replay.send(requestLine(8, wire.CallLockHello.Name, again.Params))
	replay.answer(t, 8)
	replay.send(ch.Seal(requestLine(9, "folders/list", map[string]any{})))
	if line := replay.answer(t, 9); !notInLockAnswer(line) {
		t.Fatalf("a request on a replayed hello was taken: %s", line)
	}
}

func TestSignedRequestsFromAClientOrAMachineOfTheLock(t *testing.T) {
	d, phone, peer, _ := lockedMachine(t)
	c := channelTo(d)
	signed := func(id int, key *ecdsa.PrivateKey, to, method string, params any) string {
		p, _ := json.Marshal(params)
		sig, err := machinelock.SignRequest(key, to, method, p, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		s, _ := json.Marshal(sig)
		b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(p), "lock": json.RawMessage(s)})
		return string(b)
	}
	prompt := map[string]any{"agentID": "11111111-1111-1111-1111-111111111111", "text": "go"}
	// A prompt kept for this machine while it was away, signed by the client: taken (the
	// agent is not here, which is the machine's own answer).
	line := signed(1, phone, "h-1", wire.CallAgentsPrompt.Name, prompt)
	c.send(line)
	if got := c.answer(t, 1); notInLockAnswer(got) {
		t.Fatalf("a client's kept prompt was refused: %s", got)
	}
	// Delivered twice: the second is refused.
	c.send(line)
	if got := c.answer(t, 1); !notInLockAnswer(got) {
		t.Fatalf("a kept prompt was taken twice: %s", got)
	}
	for name, l := range map[string]string{
		"for another machine":  signed(2, phone, "h-2", wire.CallAgentsPrompt.Name, prompt),
		"by a stranger":        signed(2, newLockKey(t), "h-1", wire.CallAgentsPrompt.Name, prompt),
		"a client's terminal":  signed(2, phone, "h-1", "mac/terminal", map[string]any{}),
		"a machine's terminal": signed(2, peer, "", "mac/terminal", map[string]any{}),
		"a machine's prompt":   signed(2, peer, "", wire.CallAgentsPrompt.Name, prompt),
	} {
		c.send(l)
		if got := c.answer(t, 2); !notInLockAnswer(got) {
			t.Fatalf("%s was taken: %s", name, got)
		}
	}
	// Another machine of the lock, for the session its agent started here (D7).
	c.send(signed(3, peer, "", "agents/fromStarter", map[string]any{"session": "11111111-1111-1111-1111-111111111111", "op": "status"}))
	if got := c.answer(t, 3); notInLockAnswer(got) {
		t.Fatalf("a machine's call was refused: %s", got)
	}
}

// A person's set-up keeps working until they have a lock: a machine with none takes what
// it took before, and says so at lock/hello.
func TestAMachineWithNoLockTakesWhatItDidBefore(t *testing.T) {
	d, _, _ := joinedMachine(t)
	c := channelTo(d)
	c.send(requestLine(1, "folders/list", map[string]any{}))
	if line := c.answer(t, 1); notInLockAnswer(line) || !strings.Contains(line, `"result"`) {
		t.Fatalf("an unsigned request with no lock: %s", line)
	}
	h, _ := machinelock.NewHello(newLockKey(t))
	c.send(requestLine(2, wire.CallLockHello.Name, h.Params))
	if line := c.answer(t, 2); !strings.Contains(line, `"error"`) || notInLockAnswer(line) {
		t.Fatalf("lock/hello with no lock: %s", line)
	}
}

// After a restart the machine checks requests against the lock it kept, before the control
// plane sends it again.
func TestTheLockIsKeptAcrossARestart(t *testing.T) {
	d, phone, _, _ := lockedMachine(t)
	d.lockMu.Lock()
	d.lockHeld, d.lockRead = nil, false
	d.lockMu.Unlock()
	state, pinned := d.heldLock()
	if !pinned || state == nil || state.Count() != 4 {
		t.Fatalf("the kept lock: %v, %v", state, pinned)
	}
	if m, ok := state.Member(machinelock.PublicKey(phone)); !ok || !m.Client() {
		t.Fatal("the client is not in the kept lock")
	}
}

// #3493 (D4): only agentsd lock reset, on daemon.sock, resets a machine's lock. The control
// plane cannot, nor can a client of the lock through it. After the reset the machine pins
// the next lock on first use: the new lock the person started.
func TestOnlyTheMachinesOwnAccountResetsItsLock(t *testing.T) {
	d, phone, _, state := lockedMachine(t)
	pinned := d.LockPin()

	cp := channelTo(d)
	cp.send(requestLine(1, wire.CallDaemonLockReset.Name, map[string]any{}))
	if line := cp.answer(t, 1); !notInLockAnswer(line) {
		t.Fatalf("the control plane's reset was taken: %s", line)
	}
	phoneChannel := channelTo(d)
	ch := hello(t, phoneChannel, state, phone)
	phoneChannel.send(ch.Seal(requestLine(2, wire.CallDaemonLockReset.Name, map[string]any{})))
	body, err := ch.Open(phoneChannel.answer(t, 2))
	if err != nil || !strings.Contains(body, `"code":-32045`) {
		t.Fatalf("a client's reset through the control plane: %s, %v", body, err)
	}
	if pin := d.LockPin(); pin.Count != pinned.Count {
		t.Fatalf("the pin moved: %+v", pin)
	}

	d.ResetLock()
	if pin := d.LockPin(); pin.Count != 0 {
		t.Fatalf("the pin after the reset: %+v", pin)
	}
	if _, held := d.heldLock(); held {
		t.Fatal("the machine still holds the old lock")
	}
	if fileExists(d.lockFilePath()) {
		t.Fatal("the old lock is still kept")
	}
	laptop := newLockKey(t)
	fresh := lockEntry(t, laptop, wire.LockEntryKindRoot, laptop, nil)
	if !d.TakeLock(wire.Lock{Person: "sam", Entries: []wire.LockEntry{fresh}}) {
		t.Fatal("the new lock was not pinned on first use")
	}
	if pin := d.LockPin(); pin.Count != 1 {
		t.Fatalf("the pin of the new lock: %+v", pin)
	}
}

func TestLockResetOnDaemonSockAsksForTheLockAgain(t *testing.T) {
	d, path := serveWith(t, fixedPolicy{role: RoleStranger, ok: true})
	var mu sync.Mutex
	var said []string
	d.SetControl(func(method string, _ any) { mu.Lock(); said = append(said, method); mu.Unlock() })
	os.WriteFile(d.lockPinPath(), []byte(`{"person":"sam","count":1,"head":"AA=="}`), 0o644)
	if m := socketCall(t, path, wire.CallDaemonLockReset.Name); m == nil || m.Error != nil {
		t.Fatalf("this account's reset: %+v", m)
	}
	if d.LockPin().Count != 0 {
		t.Fatal("the pin is still there")
	}
	mu.Lock()
	defer mu.Unlock()
	if !slices.ContainsFunc(said, func(m string) bool { return wire.OldMethodName(m) == wire.CallHostLockAgain.Name }) {
		t.Fatalf("the machine did not ask for its lock again: %v", said)
	}
	if RoleAgent.Allows(wire.CallDaemonLockReset.Name) {
		t.Fatal("an agent's helper may reset the lock")
	}
}

// What a machine says unasked carries the channel's MAC too (#3541): a client with a channel
// takes a notification only when it checks, in order with the answers.
func TestWhatAMachineSaysUnaskedCarriesItsMAC(t *testing.T) {
	d, phone, _, state := lockedMachine(t)
	cp := channelTo(d)
	phoneChannel := channelTo(d)
	ch := hello(t, phoneChannel, state, phone)
	// Every client is reached: the control plane's own channel unsealed, the phone's with its MAC.
	cp.send(requestLine(1, "daemon/ping", map[string]any{}))
	cp.answer(t, 1)
	Broadcast(d, wire.NotifyWorkflowRemoved, wire.WorkflowRemovedNotification{})
	note := func(c *conn) string {
		t.Helper()
		deadline := time.After(5 * time.Second)
		for {
			select {
			case line := <-c.out:
				if strings.Contains(line, wire.NotifyWorkflowRemoved.Name) {
					return line
				}
			case <-deadline:
				t.Fatal("no notification")
			}
		}
	}
	if line := note(cp); machinelock.Sealed(line) {
		t.Fatalf("a channel with no lock/hello got a MAC: %s", line)
	}
	line := note(phoneChannel)
	body, err := ch.Open(line)
	if err != nil || !strings.Contains(body, wire.NotifyWorkflowRemoved.Name) {
		t.Fatalf("the notification %s: %v", line, err)
	}
	// An answer after it has the next count.
	phoneChannel.send(ch.Seal(requestLine(2, "daemon/ping", map[string]any{})))
	if _, err := ch.Open(phoneChannel.answer(t, 2)); err != nil {
		t.Fatalf("the answer after: %v", err)
	}
}

// #3542: the control plane may stop, unsigned, the writer of a provider draft it holds,
// whose start a client of the lock signed; no other agent.
func TestTheControlPlaneStopsOnlyADraftsWriter(t *testing.T) {
	d, _, _, _ := lockedMachine(t)
	cwd := t.TempDir()
	writer := seeded(t, d, cwd, func(a *wire.Agent) {
		a.Purpose = &wire.AgentPurpose{ProviderDraft: &wire.AgentPurposeProviderDraft{ID: wire.UUID(store.NewUUID())}}
	})
	work := seeded(t, d, cwd, nil)
	cp := channelTo(d)
	cp.send(requestLine(1, wire.CallAgentsStop.Name, wire.AgentStopRequest{AgentID: work.ID}))
	if line := cp.answer(t, 1); !notInLockAnswer(line) {
		t.Fatalf("the control plane stopped a person's agent: %s", line)
	}
	cp.send(requestLine(2, wire.CallAgentsStop.Name, wire.AgentStopRequest{AgentID: writer.ID, ByAdmin: new(true)}))
	if line := cp.answer(t, 2); !notInLockAnswer(line) {
		t.Fatalf("the control plane stopped a writer as an admin: %s", line)
	}
	cp.send(requestLine(3, wire.CallAgentsStop.Name, wire.AgentStopRequest{AgentID: writer.ID}))
	if line := cp.answer(t, 3); notInLockAnswer(line) {
		t.Fatalf("the control plane could not stop its draft's writer: %s", line)
	}
}

// #3543: who did it names the device from the lock. The machine refuses a channel that the
// control plane opened for another client than the lock's key, and writes the lock member's
// client and name into the event; the person stays the control plane's word.
func TestTheAuditNamesTheDeviceFromTheLock(t *testing.T) {
	d, phone, _, state := lockedMachine(t)
	d.RaiseByHand = true
	said := func(client string) actorConn {
		name, id := "Not the phone", wire.UUID(client)
		c := actorConn{newConn(), &wire.AuditActor{User: "sam", Client: &id, ClientName: &name}}
		go d.Accept(c)
		t.Cleanup(func() { close(c.in) })
		return c
	}

	// The control plane opens the channel for another of sam's clients: the hello is refused.
	other := said("11111111-2222-3333-4444-555555555555")
	h, _ := machinelock.NewHello(phone)
	other.send(requestLine(1, wire.CallLockHello.Name, h.Params))
	if line := other.answer(t, 1); !notInLockAnswer(line) {
		t.Fatalf("a channel for another client was taken: %s", line)
	}

	// For the phone, in another case: taken, and the event names the phone as the lock does.
	c := said(strings.ToUpper(phoneClient))
	ch := hello(t, c.conn, state, phone)
	draft := map[string]any{"name": "branch.moved", "at": now(), "scope": map[string]any{"mac": map[string]any{}},
		"sentence": "moved.", "details": map[string]any{}, "chainDepth": 0}
	c.send(ch.Seal(requestLine(2, "events/raise", map[string]any{"draft": draft})))
	body, err := ch.Open(c.answer(t, 2))
	if err != nil {
		t.Fatal(err)
	}
	var m struct{ Result wire.Event }
	if err := json.Unmarshal([]byte(body), &m); err != nil {
		t.Fatal(err)
	}
	a := m.Result.Actor
	if a == nil || a.User != "sam" || a.Client == nil || !strings.EqualFold(string(*a.Client), phoneClient) ||
		a.ClientName == nil || *a.ClientName != "Sam’s iPhone" {
		t.Fatalf("the event's actor: %+v (%s)", a, body)
	}
}
