package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

// The bot's key on the person's other machines (#3950, a follow-up of #3858). A machine that
// holds the key seals it with HPKE to each other machine of the person's lock, to the sealing
// key that the lock's addMachine names (so a control plane cannot put in a key of its own),
// and sends it as connections/bot/take, signed with its own machine key, through
// machines/botKey. The control plane passes on the envelope and can open none; no client
// sees the key. The receiving machine takes it only as a request signed by a machine of its
// own lock, opens it with its own key and keeps it in its own store, as the machine that
// made the bot does. A machine of another person is in another lock, so it never gets a
// copy, and a copy for one machine does not open on another: the associated data names the
// person, the machine, the App and its version.
//
// Forget the Bot sends connections/bot/drop to the others, and each machine that hears it
// takes no copy of that App again. A machine that the person removes is refused by the
// control plane as forgotten, and deletes the key when it hears that (BotMachineRemoved).
// With no lock, nothing is sealed or taken: the key stays on the machine that made it.

const (
	// botKeyPurpose is HPKE's info the bot's key is sealed under.
	botKeyPurpose = "com.alexecollins.agents.githubbot.v1"
	// botCopiesFile is what this machine knows of the copies: not secret.
	botCopiesFile = "github-bot-copies.json"
	// mostForgotten bounds the Apps a machine remembers it was told to forget.
	mostForgotten = 16
)

// How often this machine gives the key again: to a machine still waiting for it, and to
// every machine, so one removed since drops from the list.
var (
	botWaitingEvery = 15 * time.Minute
	botAllEvery     = 6 * time.Hour
)

// The states of a machine in botCopies.Machines.
const (
	botHas     = "has"
	botWaiting = "waiting"
	botGone    = "gone"
)

// botCopies is what this machine knows of the bot's copies, in <root>/github-bot-copies.json.
type botCopies struct {
	// AppID is the bot Machines is about.
	AppID int64 `json:"appId,omitempty"`
	// Machines is each other machine of the lock, by id: has, waiting or gone.
	Machines map[string]string `json:"machines,omitempty"`
	// Forgotten is each App this machine forgot, or was told to: it takes no copy of them.
	Forgotten []int64 `json:"forgotten,omitempty"`
	// Tell is each machine still to be told to forget an App, by id.
	Tell map[string]int64 `json:"tell,omitempty"`
	// All is when every machine was given the key last.
	All time.Time `json:"all,omitzero"`
	// Last is when the waiting ones were given it last.
	Last time.Time `json:"last,omitzero"`
}

func (d *Daemon) botCopiesPath() string { return filepath.Join(d.Store.Loc.Root, botCopiesFile) }

// loadBotCopiesLocked is the copies file; d.botMu is held.
func (d *Daemon) loadBotCopiesLocked() botCopies {
	var c botCopies
	if b, err := os.ReadFile(d.botCopiesPath()); err == nil {
		json.Unmarshal(b, &c)
	}
	if c.Machines == nil {
		c.Machines = map[string]string{}
	}
	if c.Tell == nil {
		c.Tell = map[string]int64{}
	}
	return c
}

func (d *Daemon) saveBotCopiesLocked(c botCopies) {
	b, err := json.Marshal(c)
	if err == nil {
		err = store.WriteAtomically(d.botCopiesPath(), b, 0o600)
	}
	if err != nil {
		log.Printf("connections: what this machine knows of the bot's copies could not be kept: %v", err)
	}
}

func (c *botCopies) forget(app int64) {
	if !slices.Contains(c.Forgotten, app) {
		c.Forgotten = append(c.Forgotten, app)
	}
	if len(c.Forgotten) > mostForgotten {
		c.Forgotten = c.Forgotten[len(c.Forgotten)-mostForgotten:]
	}
	if c.AppID == app {
		c.AppID, c.Machines = 0, map[string]string{}
	}
}

// BotKeyAD is the associated data of the bot's key sealed for one machine of the person.
func BotKeyAD(person, host string, app, version int64) []byte {
	return fmt.Appendf(nil, "githubbot.v1|%s|%s|%d|%d", person, controllink.MachineRecipient(host), app, version)
}

// sealBot seals the bot to one machine of the lock, to the sealing key its addMachine names.
func sealBot(b connections.Bot, person string, to machinelock.Member) (wire.ConnectionBotCopy, error) {
	plain, err := json.Marshal(b)
	if err != nil {
		return wire.ConnectionBotCopy{}, err
	}
	defer clear(plain)
	version := b.MadeAt.UnixMilli()
	sealed, err := controllink.Seal(to.SealingKey, botKeyPurpose, BotKeyAD(person, to.ID, b.AppID, version), plain)
	if err != nil {
		return wire.ConnectionBotCopy{}, err
	}
	return wire.ConnectionBotCopy{AppId: b.AppID, Version: version, Sealed: sealed}, nil
}

// openBot opens a copy sealed to this machine.
func openBot(private []byte, person, host string, c wire.ConnectionBotCopy) (connections.Bot, error) {
	plain, err := controllink.Open(private, botKeyPurpose, BotKeyAD(person, host, c.AppId, c.Version), c.Sealed)
	if err != nil {
		return connections.Bot{}, errors.New("it does not open with this machine's key")
	}
	defer clear(plain)
	var b connections.Bot
	if err := json.Unmarshal(plain, &b); err != nil || b.AppID != c.AppId || b.PrivateKey == "" || b.Slug == "" {
		return connections.Bot{}, errors.New("it is not a bot's key")
	}
	if b.MadeAt.UnixMilli() != c.Version {
		return connections.Bot{}, errors.New("its version is not the one sealed")
	}
	return b, nil
}

func (d *Daemon) registerGitHubBotCopies() {
	On(d, wire.CallConnectionsBotTake, func(ctx context.Context, c *Client, r wire.ConnectionBotCopy) (wire.Empty, error) {
		return wire.Empty{}, d.takeBot(r)
	})
	On(d, wire.CallConnectionsBotDrop, func(ctx context.Context, c *Client, r wire.ConnectionBotDrop) (wire.Empty, error) {
		return wire.Empty{}, d.dropBot(r.AppId)
	})
}

// takeBot is connections/bot/take: a copy from another machine of the lock. With a lock, the
// request was checked before it came here (lockcheck.go): only a machine of the lock, or a
// client of it on a checked channel, signs for this method. With none it is refused, since
// nothing would say who sent it.
func (d *Daemon) takeBot(r wire.ConnectionBotCopy) error {
	state, pinned := d.heldLock()
	if !pinned || state == nil {
		log.Printf("connections: a copy of the bot's key refused: this machine holds no lock")
		return invalid("This machine has no lock, so it takes the bot's key from no other machine.")
	}
	host := d.ownHostID()
	private, found, err := d.HostKey.Load()
	if host == "" || err != nil || !found {
		return invalid("This machine has not joined a control plane.")
	}
	bot, err := openBot(private, state.Person, host, r)
	if err != nil {
		log.Printf("connections: a copy of the bot's key refused: %v", err)
		return invalid("The bot's key was not taken: " + err.Error() + ".")
	}
	s, err := d.connectionStore()
	if err != nil {
		return err
	}
	d.botMu.Lock()
	defer d.botMu.Unlock()
	copies := d.loadBotCopiesLocked()
	if slices.Contains(copies.Forgotten, bot.AppID) {
		log.Printf("connections: a copy of the bot's key refused: that bot was forgotten here")
		return invalid("This machine was told to forget that bot.")
	}
	d.connRenew.Lock()
	defer d.connRenew.Unlock()
	if held, ok, err := s.Get(connections.GitHubBot); err != nil {
		return err
	} else if have, isBot := connections.BotOf(held); ok && isBot {
		if have.AppID == bot.AppID && have.MadeAt.UnixMilli() == r.Version {
			return nil
		}
		if have.MadeAt.UnixMilli() > r.Version {
			return invalid("This machine has a newer bot.")
		}
	}
	if err := s.Put(bot.Connection()); err != nil {
		log.Printf("connections: a copy of the bot's key not kept")
		return err
	}
	if copies.AppID != bot.AppID {
		copies.AppID, copies.Machines = bot.AppID, map[string]string{}
	}
	d.saveBotCopiesLocked(copies)
	log.Printf("connections: took the bot's key from another of this person's machines")
	return nil
}

// dropBot is connections/bot/drop: another machine forgot the bot, so this one does too.
func (d *Daemon) dropBot(app int64) error {
	if _, pinned := d.heldLock(); !pinned {
		return invalid("This machine has no lock, so it takes no word about the bot from another machine.")
	}
	s, err := d.connectionStore()
	if err != nil {
		return err
	}
	d.botMu.Lock()
	defer d.botMu.Unlock()
	copies := d.loadBotCopiesLocked()
	copies.forget(app)
	d.connRenew.Lock()
	held, ok, err := s.Get(connections.GitHubBot)
	if have, isBot := connections.BotOf(held); err == nil && ok && isBot && have.AppID == app {
		err = s.Delete(connections.GitHubBot)
	}
	d.connRenew.Unlock()
	d.saveBotCopiesLocked(copies)
	if err != nil {
		log.Printf("connections: the bot's key not deleted")
		return err
	}
	log.Printf("connections: forgot the bot, as another of this person's machines did")
	return nil
}

// forgetBotEverywhere is Forget the Bot: after this machine deleted the key, every other
// machine of the lock is told to forget it too.
func (d *Daemon) forgetBotEverywhere(app int64) {
	state, _ := d.heldLock()
	d.botMu.Lock()
	copies := d.loadBotCopiesLocked()
	copies.forget(app)
	if state != nil {
		me := d.ownHostID()
		for _, m := range state.Members(wire.LockEntryKindAddMachine) {
			if m.ID != "" && m.ID != me {
				copies.Tell[m.ID] = app
			}
		}
	}
	d.saveBotCopiesLocked(copies)
	d.botMu.Unlock()
	d.goShareBotKey(true)
}

// BotMachineRemoved is the control plane saying this machine is forgotten: the person
// removed it, so it keeps no key of the bot's, its own or a copy.
func (d *Daemon) BotMachineRemoved() {
	s, err := d.connectionStore()
	if err != nil {
		return
	}
	d.botMu.Lock()
	defer d.botMu.Unlock()
	d.connRenew.Lock()
	_, ok, err := s.Get(connections.GitHubBot)
	if err == nil && ok {
		err = s.Delete(connections.GitHubBot)
	}
	d.connRenew.Unlock()
	if err != nil {
		log.Printf("connections: this machine was removed, and the bot's key could not be deleted")
		return
	}
	if ok {
		log.Printf("connections: this machine was removed, so it deleted the bot's key")
	}
	os.Remove(d.botCopiesPath())
}

// ShareBotKey gives the key to the machines waiting for it: when this machine is back on
// its control plane.
func (d *Daemon) ShareBotKey() { d.goShareBotKey(false) }

// goShareBotKey gives the key to the machines waiting for it (all: to every machine) in the
// background, once at a time.
func (d *Daemon) goShareBotKey(all bool) {
	go func() {
		if !d.botRound.TryLock() {
			return
		}
		defer d.botRound.Unlock()
		d.shareBotKey(all, time.Now())
	}()
}

// shareBotKeyDue is the clock's turn: the waiting machines every 15 minutes, all every 6 hours.
func (d *Daemon) shareBotKeyDue(now time.Time) {
	d.botMu.Lock()
	c := d.loadBotCopiesLocked()
	d.botMu.Unlock()
	switch {
	case now.Sub(c.All) >= botAllEvery:
		d.goShareBotKey(true)
	case now.Sub(c.Last) >= botWaitingEvery:
		d.goShareBotKey(false)
	}
}

// botKeyAsk is one machines/botKey: the step, signed with this machine's key for the machine
// it goes to. The answer's code is the control plane's or that machine's.
func (d *Daemon) botKeyAsk(ctx context.Context, host string, step any) error {
	ask := d.askControl.Load()
	if ask == nil {
		return &Error{Code: wire.FailureNotSupported, Message: "This machine isn’t on a control plane."}
	}
	r := wire.MachineBotKey{Host: host}
	method := wire.CallConnectionsBotTake.Name
	switch s := step.(type) {
	case wire.ConnectionBotCopy:
		r.Copy = &s
	case wire.ConnectionBotDrop:
		r.Drop, method = &s, wire.CallConnectionsBotDrop.Name
	}
	signer, err := d.machineSigner()
	if err != nil {
		return err
	}
	b, err := json.Marshal(step)
	if err != nil {
		return err
	}
	sig, err := machinelock.SignRequest(signer, host, method, b, time.Now())
	if err != nil {
		return err
	}
	p, _ := json.Marshal(r)
	call := wire.MachineWorkspaceCall{Agent: "the agents' bot", Method: wire.CallMachinesBotKey.Name, Params: p,
		Deliver: &wire.LockDelivery{Method: method, Params: string(b), Lock: sig}}
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	_, err = (*ask)(ctx, "machine/machines", call)
	var refused *controllink.AskError
	if errors.As(err, &refused) {
		return &Error{Code: refused.Code, Message: refused.Message}
	}
	return err
}

func failureCode(err error) int {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return 0
}

// shareBotKey tells the machines still to hear that the bot was forgotten, then gives this
// machine's key to each other machine of the lock that waits for it, or to all.
func (d *Daemon) shareBotKey(all bool, now time.Time) {
	state, pinned := d.heldLock()
	me := d.ownHostID()
	if !pinned || state == nil || me == "" || d.askControl.Load() == nil {
		return
	}
	d.botMu.Lock()
	copies := d.loadBotCopiesLocked()
	d.botMu.Unlock()
	told := map[string]bool{}
	for host, app := range copies.Tell {
		err := d.botKeyAsk(d.ctx, host, wire.ConnectionBotDrop{AppId: app})
		if err == nil || failureCode(err) == wire.FailureNoSuchHost {
			told[host] = true
		}
	}
	bot, ok := d.heldBot()
	machines := map[string]string{}
	if ok {
		for _, m := range state.Members(wire.LockEntryKindAddMachine) {
			if m.ID == "" || m.ID == me {
				continue
			}
			was := botWaiting
			if copies.AppID == bot.AppID && copies.Machines[m.ID] != "" {
				was = copies.Machines[m.ID]
			}
			machines[m.ID] = was
			if !all && was != botWaiting {
				continue
			}
			sealed, err := sealBot(bot, state.Person, m)
			if err == nil {
				err = d.botKeyAsk(d.ctx, m.ID, sealed)
			}
			switch {
			case err == nil:
				machines[m.ID] = botHas
			case failureCode(err) == wire.FailureNoSuchHost:
				machines[m.ID] = botGone
			case failureCode(err) == wire.FailureHostOffline:
				// It gets it when it is online.
			default:
				machines[m.ID] = botWaiting
				log.Printf("connections: the bot's key did not go to %s: %v", m.ID, err)
			}
		}
	}
	d.botMu.Lock()
	defer d.botMu.Unlock()
	c := d.loadBotCopiesLocked()
	for host := range told {
		delete(c.Tell, host)
	}
	if ok {
		c.AppID, c.Machines = bot.AppID, machines
	}
	c.Last = now
	if all {
		c.All = now
	}
	d.saveBotCopiesLocked(c)
}

// heldBot is the bot this machine keeps.
func (d *Daemon) heldBot() (connections.Bot, bool) {
	s, err := d.connectionStore()
	if err != nil {
		return connections.Bot{}, false
	}
	c, ok, err := s.Get(connections.GitHubBot)
	if err != nil || !ok {
		return connections.Bot{}, false
	}
	return connections.BotOf(c)
}

// botKeyOn is the person's machines and which hold the key, for connections/bot: this one
// first, then the others of the lock by name. Nil with no lock.
func (d *Daemon) botKeyOn(app int64) []wire.ConnectionBotMachine {
	state, _ := d.heldLock()
	me := d.ownHostID()
	if state == nil || me == "" {
		return nil
	}
	d.botMu.Lock()
	c := d.loadBotCopiesLocked()
	d.botMu.Unlock()
	here := true
	out := []wire.ConnectionBotMachine{{Name: d.ownName(), Here: &here, Has: true}}
	var others []wire.ConnectionBotMachine
	for _, m := range state.Members(wire.LockEntryKindAddMachine) {
		if m.ID == "" || m.ID == me {
			continue
		}
		was := ""
		if c.AppID == app {
			was = c.Machines[m.ID]
		}
		if was == botGone {
			continue
		}
		name := m.Name
		if name == "" {
			name = m.ID
		}
		others = append(others, wire.ConnectionBotMachine{Name: name, Has: was == botHas})
	}
	sort.Slice(others, func(i, j int) bool { return others[i].Name < others[j].Name })
	return append(out, others...)
}
