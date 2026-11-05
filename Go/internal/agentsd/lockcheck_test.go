package agentsd

import (
	"crypto/ecdsa"
	"encoding/json"
	"strings"
	"testing"
	"time"

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
	add(wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: machinelock.PublicKey(phone)})
	add(wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: key, SealingKey: key, ID: new("h-1")})
	add(wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: machinelock.PublicKey(peer), SealingKey: machinelock.PublicKey(peer), ID: new("h-2")})
	if !d.TakeLock(wire.Lock{Person: "sam", Entries: c}) {
		t.Fatal("the lock was not taken")
	}
	state, _ = d.heldLock()
	return d, phone, peer, state
}

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
