package agentsd

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

// The bot's key on the person's other machines (#3950): sealed machine to machine, to the
// key the person's lock names, so no client, no control plane and no other person's machine
// can read it.

const botPEM = "-----BEGIN RSA PRIVATE KEY-----\nthe bot's key\n-----END RSA PRIVATE KEY-----\n"

func theBot() connections.Bot {
	return connections.Bot{AppID: 42, Slug: "sam-agents", Owner: "sam", Person: "sam", PrivateKey: botPEM,
		MadeAt: time.UnixMilli(1_800_000_000_000).UTC()}
}

// botStore gives d a connections file of its own, and returns it.
func botStore(t *testing.T, d *Daemon) *connections.File {
	t.Helper()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	return file
}

func rawKey(k *ecdsa.PrivateKey) []byte { return k.D.FillBytes(make([]byte, 32)) }

func memberOf(t *testing.T, state *machinelock.State, id string) machinelock.Member {
	t.Helper()
	for _, m := range state.Members(wire.LockEntryKindAddMachine) {
		if m.ID == id {
			return m
		}
	}
	t.Fatalf("no machine %s in the lock", id)
	return machinelock.Member{}
}

// A test: the key reaches a second machine of the same person, sealed to that machine's key,
// and a machine of another person, a client and the control plane cannot read it.
func TestTheBotsKeyReachesTheOtherMachineSealedToIt(t *testing.T) {
	d, phone, peer, state := lockedMachine(t)
	defer d.Shutdown()
	file := botStore(t, d)
	if err := file.Put(theBot().Connection()); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var calls []wire.MachineWorkspaceCall
	ask := askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method != "machine/machines" {
			return nil, errors.New("not here")
		}
		b, _ := json.Marshal(params)
		var call wire.MachineWorkspaceCall
		json.Unmarshal(b, &call)
		mu.Lock()
		calls = append(calls, call)
		mu.Unlock()
		return json.RawMessage(`{}`), nil
	})
	d.askControl.Store(&ask)
	// Once any round started in the background has ended.
	d.botRound.Lock()
	mu.Lock()
	calls = nil
	mu.Unlock()
	d.shareBotKey(true, time.Now())
	d.botRound.Unlock()

	mu.Lock()
	defer mu.Unlock()
	if len(calls) != 1 {
		t.Fatalf("calls: %+v", calls)
	}
	call := calls[0]
	var r wire.MachineBotKey
	json.Unmarshal(call.Params, &r)
	if call.Method != wire.CallMachinesBotKey.Name || r.Host != "h-2" || r.Copy == nil || call.Deliver == nil ||
		call.Deliver.Method != wire.CallConnectionsBotTake.Name {
		t.Fatalf("call: %+v", call)
	}
	// What the control plane is given: no key, in the call or the signed delivery.
	all, _ := json.Marshal(call)
	if strings.Contains(string(all), "PRIVATE KEY") || strings.Contains(string(all), "the bot's key") {
		t.Fatalf("the key went in clear: %s", all)
	}
	// Signed by this machine, for h-2 only.
	if _, err := machinelock.CheckRequest(state, "h-2", call.Deliver.Method, []byte(call.Deliver.Params), call.Deliver.Lock, time.Now()); err != nil {
		t.Fatalf("the copy is not signed for h-2: %v", err)
	}
	if _, err := machinelock.CheckRequest(state, "h-3", call.Deliver.Method, []byte(call.Deliver.Params), call.Deliver.Lock, time.Now()); err == nil {
		t.Fatal("the copy for h-2 checks for another machine")
	}
	var sealed wire.ConnectionBotCopy
	json.Unmarshal([]byte(call.Deliver.Params), &sealed)

	// h-2 opens it with its own key.
	got, err := openBot(rawKey(peer), "sam", "h-2", sealed)
	if err != nil || got.PrivateKey != botPEM || got.AppID != 42 || got.Slug != "sam-agents" {
		t.Fatalf("h-2: %+v %v", got, err)
	}
	// Nobody else: a client of the person, a stranger (the control plane's own key, or
	// another person's machine), this machine as another one, or another person's lock.
	h1, _, _ := joinedKey(t, d)
	for name, try := range map[string]func() error{
		"the phone":                 func() error { _, err := openBot(rawKey(phone), "sam", "h-2", sealed); return err },
		"a stranger":                func() error { _, err := openBot(rawKey(newLockKey(t)), "sam", "h-2", sealed); return err },
		"h-1 as h-2":                func() error { _, err := openBot(h1, "sam", "h-2", sealed); return err },
		"h-2 in another's lock":     func() error { _, err := openBot(rawKey(peer), "pat", "h-2", sealed); return err },
		"h-2 at another version":    func() error { s := sealed; s.Version++; _, err := openBot(rawKey(peer), "sam", "h-2", s); return err },
		"h-2 as another App's copy": func() error { s := sealed; s.AppId++; _, err := openBot(rawKey(peer), "sam", "h-2", s); return err },
	} {
		if try() == nil {
			t.Fatalf("%s opened the bot's key", name)
		}
	}

	// The bot's state says which machines have its key.
	on := d.botKeyOn(42)
	if len(on) != 2 || on[0].Here == nil || !*on[0].Here || !on[0].Has || on[1].Name != "h-2" || !on[1].Has {
		t.Fatalf("keyOn: %+v", on)
	}
	// A removed machine drops from the list; an offline one waits.
	gone := askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		return nil, &controllink.AskError{Code: wire.FailureNoSuchHost, Message: "No machine is called h-2."}
	})
	d.askControl.Store(&gone)
	d.botRound.Lock()
	d.shareBotKey(true, time.Now())
	d.botRound.Unlock()
	if on := d.botKeyOn(42); len(on) != 1 {
		t.Fatalf("a removed machine is listed: %+v", on)
	}
}

// joinedKey is d's own machine key, raw.
func joinedKey(t *testing.T, d *Daemon) ([]byte, bool, error) {
	t.Helper()
	return d.HostKey.Load()
}

// h-2 gives h-1 the key: h-1 takes it only signed by a machine of its lock, sealed to its own
// key, and keeps it in its own store; a forgotten bot is not taken again.
func TestAMachineTakesTheBotsKeyOnlyFromItsOwnLock(t *testing.T) {
	d, _, peer, state := lockedMachine(t)
	defer d.Shutdown()
	file := botStore(t, d)
	c := channelTo(d)
	signed := func(id int, key *ecdsa.PrivateKey, method string, params any) string {
		p, _ := json.Marshal(params)
		sig, err := machinelock.SignRequest(key, "h-1", method, p, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		s, _ := json.Marshal(sig)
		b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(p), "lock": json.RawMessage(s)})
		return string(b)
	}
	sealed, err := sealBot(theBot(), "sam", memberOf(t, state, "h-1"))
	if err != nil {
		t.Fatal(err)
	}
	// Not by a stranger, nor unsigned in the control plane's words.
	c.send(signed(1, newLockKey(t), wire.CallConnectionsBotTake.Name, sealed))
	if got := c.answer(t, 1); !notInLockAnswer(got) {
		t.Fatalf("a stranger's copy was taken: %s", got)
	}
	c.send(requestLine(2, wire.CallConnectionsBotTake.Name, sealed))
	if got := c.answer(t, 2); !notInLockAnswer(got) {
		t.Fatalf("an unsigned copy was taken: %s", got)
	}
	if _, ok, _ := file.Get(connections.GitHubBot); ok {
		t.Fatal("kept")
	}
	// A copy sealed to another person's lock does not open here.
	pat, _ := sealBot(theBot(), "pat", memberOf(t, state, "h-1"))
	c.send(signed(3, peer, wire.CallConnectionsBotTake.Name, pat))
	if got := c.answer(t, 3); !strings.Contains(got, "does not open") {
		t.Fatalf("another lock's copy: %s", got)
	}
	// h-2's copy is taken.
	c.send(signed(4, peer, wire.CallConnectionsBotTake.Name, sealed))
	if got := c.answer(t, 4); strings.Contains(got, `"error"`) {
		t.Fatalf("h-2's copy: %s", got)
	}
	kept, ok, _ := file.Get(connections.GitHubBot)
	if b, isBot := connections.BotOf(kept); !ok || !isBot || b.PrivateKey != botPEM || b.AppID != 42 {
		t.Fatalf("kept: %+v", kept)
	}
	// h-2 forgot the bot: h-1 deletes it, and takes it from no one again.
	c.send(signed(5, peer, wire.CallConnectionsBotDrop.Name, wire.ConnectionBotDrop{AppId: 42}))
	if got := c.answer(t, 5); strings.Contains(got, `"error"`) {
		t.Fatalf("drop: %s", got)
	}
	if _, ok, _ := file.Get(connections.GitHubBot); ok {
		t.Fatal("the bot's key was kept after the drop")
	}
	c.send(signed(6, peer, wire.CallConnectionsBotTake.Name, sealed))
	if got := c.answer(t, 6); !strings.Contains(got, "forget") {
		t.Fatalf("a forgotten bot was taken again: %s", got)
	}
}

// With no lock, a machine takes the key from no one: nothing would say who sent it.
func TestAMachineWithNoLockTakesNoBotsKey(t *testing.T) {
	d, key, _ := joinedMachine(t)
	defer d.Shutdown()
	botStore(t, d)
	sealed, err := sealBot(theBot(), "sam", machinelock.Member{ID: "h-1", SealingKey: key})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.takeBot(sealed); err == nil || !strings.Contains(err.Error(), "no lock") {
		t.Fatalf("taken with no lock: %v", err)
	}
}

// Forget the Bot tells the other machines; a machine the person removed deletes its key.
func TestForgettingAndRemovingTakeTheBotsKeyAway(t *testing.T) {
	d, _, _, _ := lockedMachine(t)
	defer d.Shutdown()
	file := botStore(t, d)
	file.Put(theBot().Connection())
	var mu sync.Mutex
	var drops []string
	ask := askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		b, _ := json.Marshal(params)
		var call wire.MachineWorkspaceCall
		json.Unmarshal(b, &call)
		if call.Deliver != nil && call.Deliver.Method == wire.CallConnectionsBotDrop.Name {
			mu.Lock()
			drops = append(drops, call.Deliver.Params)
			mu.Unlock()
		}
		return json.RawMessage(`{}`), nil
	})
	d.askControl.Store(&ask)
	file.Delete(connections.GitHubBot)
	d.botRound.Lock()
	d.forgetBotEverywhere(42)
	d.shareBotKey(false, time.Now())
	d.botRound.Unlock()
	mu.Lock()
	defer mu.Unlock()
	if len(drops) == 0 || drops[len(drops)-1] != `{"appId":42}` {
		t.Fatalf("drops: %v", drops)
	}
	d.botMu.Lock()
	tell := d.loadBotCopiesLocked().Tell
	d.botMu.Unlock()
	if len(tell) != 0 {
		t.Fatalf("still to tell: %v", tell)
	}

	file.Put(theBot().Connection())
	d.BotMachineRemoved()
	if _, ok, _ := file.Get(connections.GitHubBot); ok {
		t.Fatal("a removed machine kept the bot's key")
	}
}
