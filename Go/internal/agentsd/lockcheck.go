package agentsd

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

// Each request checked end to end (#3492, specs/3399-machine-lock D6, D7). Once this machine
// holds its person's lock, a request that comes through the control plane is taken only
// when a key of that lock vouches for it:
//
//   - with an HMAC from a channel a client of the lock opened with lock/hello;
//   - signed by a client of the lock, for a prompt or a start kept while this machine was
//     away (LockSignature, to this machine, at most a day old, once);
//   - signed by another machine of the lock, for the steps of start_session, its calls to
//     the session it started, and send and bring_back (D7);
//   - or one of the few the control plane asks for itself, which start nothing.
//
// Everything else is refused with notInLock, the control plane's own word for who sent it
// notwithstanding. A machine with no lock yet takes what it took before the lock, so a
// person's set-up keeps working until they have one. daemon.sock is this account's own and
// is not checked; the window's local socket is, so its key comes from the lock too.

// lockSeenFile keeps lockSeen across a restart.
const lockSeenFile = "lock-seen.json"

// mostSeen bounds lockSeen: the oldest go first.
const mostSeen = 4096

// controlAsks is what the control plane asks of a machine for itself, unsigned: whether it
// is there, the Console's and a project's list of sessions, a report's facts, a backup
// before a delete, and the folders a new workspace is cloned with. None starts an agent,
// runs a command or reads a file.
var controlAsks = methodSet([]string{
	"daemon/ping", "daemon/status", wire.CallLockHello.Name,
	wire.CallAgentsList.Name, wire.CallWorktreesAll.Name, wire.CallAgentsSummaryFacts.Name,
	wire.CallBackupsMake.Name, "folders/clone",
})

// clientSigned is what a client may sign for a machine that is not there: what the control
// plane keeps for a stopped workspace (#691 US3).
var clientSigned = methodSet([]string{wire.CallAgentsStart.Name, wire.CallAgentsPrompt.Name})

// machineSigned is what another of the person's machines may ask (D7): the steps of
// start_session (#2887, #2927), and of send and bring_back (#2929, #2947). Not terminals,
// nor any other file.
var machineSigned = methodSet([]string{
	wire.CallAgentsStart.Name, "agents/fromStarter", "agents/endedElsewhere",
	"folders/receiveState", "folders/receiveUpload", "folders/receive",
	"folders/sendFacts", "folders/sendPack", "folders/sendRead",
})

// registerLockHello serves lock/hello, so the host says host.lock/3. A checked connection
// answers it before dispatch (readChecked); daemon.sock, which is not checked, has no channel.
func (d *Daemon) registerLockHello() {
	On(d, wire.CallLockHello, func(_ context.Context, _ *Client, _ wire.LockHello) (wire.LockHelloReply, error) {
		return wire.LockHelloReply{}, &Error{Code: wire.FailureNotSupported, Message: "This connection is the machine's own, and needs no channel."}
	})
}

// lockChecked says whether a connection's requests are checked against the lock: every one
// the control plane carries, and the window's local socket; not daemon.sock.
func lockChecked(conn any) bool {
	if sc, ok := conn.(*sockConn); ok {
		return sc.local
	}
	return true
}

// clientLock is a connection's checked channel, once a client opened one.
type clientLock struct {
	mu      sync.Mutex
	channel *machinelock.Channel
}

func (l *clientLock) get() *machinelock.Channel {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.channel
}

func (l *clientLock) set(c *machinelock.Channel) {
	l.mu.Lock()
	l.channel = c
	l.mu.Unlock()
}

func notInLock(why string) *Error {
	return &Error{Code: wire.FailureNotInLock, Message: "This machine takes requests only from your devices: " + why + "."}
}

// readChecked reads one line on a checked connection as dispatch takes it. It answers
// lock/hello and every refusal itself, and then says false.
func (d *Daemon) readChecked(c *Client, line string) (message, bool) {
	var m message
	sealed := machinelock.Sealed(line)
	body := line
	var openErr error
	if sealed {
		if ch := c.lock.get(); ch == nil {
			openErr = errors.New("no channel was opened with lock/hello")
		} else if opened, err := ch.Open(line); err != nil {
			openErr = err
		} else {
			body = opened
		}
	}
	if err := json.Unmarshal([]byte(body), &m); err != nil {
		if openErr == nil {
			c.send(message{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &Error{Code: CodeParse, Message: "parse error"}})
		}
		return m, false
	}
	if m.Method == "" {
		return m, true // a reply: nothing here asks a client anything
	}
	if openErr != nil {
		return m, d.refuse(c, m, openErr.Error())
	}
	if m.Method == wire.CallLockHello.Name {
		d.answerHello(c, m)
		return m, false
	}
	state, pinned := d.heldLock()
	switch {
	case sealed, !pinned:
		return m, true
	case state == nil && !controlAsks[m.Method]:
		return m, d.refuse(c, m, "it has not read your lock yet; try again in a moment")
	}
	if s, ok := machinelock.SignatureOf(m.Lock); ok {
		return m, d.takeSigned(c, state, m, s)
	}
	if controlAsks[m.Method] {
		return m, true
	}
	return m, d.refuse(c, m, "the request is not signed by one of them")
}

// refuse answers a request with notInLock, and says false.
func (d *Daemon) refuse(c *Client, m message, why string) bool {
	log.Printf("lock: refused %s from the control plane: %s", m.Method, why)
	if m.ID != nil {
		c.send(message{JSONRPC: "2.0", ID: m.ID, Error: notInLock(why)})
	}
	return false
}

// answerHello is lock/hello: a client of the lock opens a checked channel.
func (d *Daemon) answerHello(c *Client, m message) {
	answer := func(result any, err error) {
		if m.ID == nil {
			return
		}
		if err != nil {
			var re *Error
			if !errors.As(err, &re) {
				re = notInLock(err.Error())
			}
			c.send(message{JSONRPC: "2.0", ID: m.ID, Error: re})
			return
		}
		b, _ := json.Marshal(result)
		c.send(message{JSONRPC: "2.0", ID: m.ID, Result: b})
	}
	var hello wire.LockHello
	if err := json.Unmarshal(m.Params, &hello); err != nil {
		answer(nil, Invalid("lock/hello: %v", err))
		return
	}
	state, pinned := d.heldLock()
	if !pinned {
		answer(nil, &Error{Code: wire.FailureNotSupported, Message: "This machine holds no lock yet."})
		return
	}
	if state == nil {
		answer(nil, notInLock("it has not read your lock yet; try again in a moment"))
		return
	}
	signer, err := d.machineSigner()
	if err != nil {
		answer(nil, &Error{Code: CodeServer, Message: "This machine's key could not be read: " + err.Error()})
		return
	}
	channel, reply, err := machinelock.Answer(state, signer, hello)
	if err != nil {
		log.Printf("lock: refused a channel: %v", err)
		answer(nil, err)
		return
	}
	// The answer goes before the channel is set: it is not MAC'd, its signature is its proof.
	answer(reply, nil)
	c.lock.set(channel)
	who := channel.Member.Name
	if who == "" {
		who = "a device"
	}
	log.Printf("lock: %s opened a checked channel", who)
}

func (d *Daemon) machineSigner() (*ecdsa.PrivateKey, error) {
	d.lockMu.Lock()
	defer d.lockMu.Unlock()
	if d.lockSigner != nil {
		return d.lockSigner, nil
	}
	if d.HostKey == nil {
		return nil, errors.New("this machine has no key")
	}
	private, found, err := d.HostKey.Load()
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, errors.New("this machine has not joined a control plane")
	}
	key, err := machinelock.MachineSigner(private)
	if err != nil {
		return nil, err
	}
	d.lockSigner = key
	return key, nil
}

// takeSigned checks a signed request: by a client for what may be kept, or by another
// machine of the lock for start_session's steps; each once.
func (d *Daemon) takeSigned(c *Client, state *machinelock.State, m message, s wire.LockSignature) bool {
	host, _, _, ok := d.lockIdentity()
	if !ok {
		return d.refuse(c, m, "this machine has not joined a control plane")
	}
	now := time.Now()
	member, err := machinelock.CheckRequest(state, host, m.Method, m.Params, s, now)
	if err != nil {
		return d.refuse(c, m, err.Error())
	}
	if member.Client() && !clientSigned[m.Method] || !member.Client() && !machineSigned[m.Method] {
		return d.refuse(c, m, "that key may not sign "+m.Method)
	}
	if !d.seeSigned(machinelock.SignedID(s), s.At, now) {
		return d.refuse(c, m, machinelock.ErrReplayed.Error())
	}
	return true
}

// seeSigned notes a signed request as taken; false when it was taken before.
func (d *Daemon) seeSigned(id string, at int64, now time.Time) bool {
	d.lockMu.Lock()
	defer d.lockMu.Unlock()
	path := filepath.Join(d.Store.Loc.Root, lockSeenFile)
	if d.lockSeen == nil {
		d.lockSeen = map[string]int64{}
		if b, err := os.ReadFile(path); err == nil {
			json.Unmarshal(b, &d.lockSeen)
		}
	}
	if _, seen := d.lockSeen[id]; seen {
		return false
	}
	oldest := now.Add(-machinelock.RequestLifetime).Unix()
	for k, t := range d.lockSeen {
		if t < oldest {
			delete(d.lockSeen, k)
		}
	}
	if len(d.lockSeen) >= mostSeen {
		ids := make([]string, 0, len(d.lockSeen))
		for k := range d.lockSeen {
			ids = append(ids, k)
		}
		sort.Slice(ids, func(i, j int) bool { return d.lockSeen[ids[i]] < d.lockSeen[ids[j]] })
		for _, k := range ids[:len(ids)-mostSeen+1] {
			delete(d.lockSeen, k)
		}
	}
	d.lockSeen[id] = at
	if b, err := json.Marshal(d.lockSeen); err == nil {
		if err := store.WriteAtomically(path, b, 0o600); err != nil {
			log.Printf("lock: the signed requests taken could not be kept: %v", err)
		}
	}
	return true
}
