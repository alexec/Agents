package agentsd

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// agents-secret NAME from a terminal (#4179, step D of the spike #4168): a call with no
// session's grant asks a person. agentsd opens a Needs you request (secretUse, use terminal,
// the place the name of the command that ran agents-secret, as it says it), held as
// fill_secret's is, and the person answers:
//
//   - once: this call, and no other;
//   - hour: every call of agents-secret NAME with no grant for one hour, kept in agentsd's
//     memory only, so a restart asks again;
//   - deny: the call fails with words that say a person denied it.
//
// The known gap, which the request's words say: agentsd cannot tell a terminal from an agent
// that dropped its grant. An agent with a grant has no need to drop it, so this ask stops only
// processes that are not sessions, and an hour's allow is open to every caller with no grant
// for that hour. A secret with Ask before use is refused here as it is to a session: #4013's
// rule is that a flagged value never goes into a process of the user.
//
// The call is secrets/terminalValue on daemon.sock, which any process of this account may make
// (strangerOnly in roles.go), as `agentsd lock reset` does.

// secretUseHour is the answer that allows a terminal's calls for terminalHour.
const secretUseHour = "hour"

// terminalCaveat is the known gap, in the request's words on every client.
const terminalCaveat = "Agents cannot tell a terminal from an agent outside its session."

// terminalHour is how long Allow for 1 Hour lasts; a test makes it short.
var terminalHour = time.Hour

// terminalPlace is a terminal's read's place in the record, as the spike #4168 says it.
const terminalPlace = "terminal"

// terminalState is what a person allowed calls with no grant, by the secret's name. In memory
// only: a restart asks again.
type terminalState struct {
	terminalOnceLeft map[string]int
	terminalUntil    map[string]time.Time
	// terminalHeld is each call held on a terminal's request, by the request's id: every
	// caller that waits on it hears that it ended.
	terminalHeld map[wire.UUID][]chan struct{}
}

func (d *Daemon) registerSecretTerminal() {
	On(d, wire.CallSecretsTerminalValue, func(ctx context.Context, _ *Client, r wire.SecretTerminalRequest) (wire.SecretTerminalValue, error) {
		return d.terminalSecret(ctx, strings.TrimSpace(r.Name), terminalCommandName(deref(r.Command)), formHoldLimit)
	})
}

// terminalCommandName is the place a request names: a command's base name, printable and
// short, or "a terminal" when the caller said none.
func terminalCommandName(s string) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsPrint(r) {
			return r
		}
		return -1
	}, filepath.Base(strings.TrimSpace(s)))
	if s == "" || s == "." || s == "/" {
		return "a terminal"
	}
	if r := []rune(s); len(r) > 40 {
		s = string(r[:40])
	}
	return s
}

// terminalSecret is secrets/terminalValue: name's value once a person allowed it, the open
// request it waits on after hold, or an error with words.
func (d *Daemon) terminalSecret(ctx context.Context, name, command string, hold time.Duration) (wire.SecretTerminalValue, error) {
	if !secretAskName.MatchString(name) {
		return wire.SecretTerminalValue{}, Invalid("Give the secret's name: agents-secret NAME, with letters, digits and underscores.")
	}
	home := d.personalHome()
	if home == "" {
		return wire.SecretTerminalValue{}, Invalid("This machine has no personal home to keep secrets in.")
	}
	if isSealedSecret(home, name) {
		return wire.SecretTerminalValue{}, Invalid("%s has Ask before use, so agentsd never puts its value in a process. "+
			"A person turns Ask before use off for %s in Settings ▸ Secrets to read it here.", name, name)
	}
	if !secretIsSet(home, name) {
		return wire.SecretTerminalValue{}, Invalid("%s is not set on this machine.", name)
	}
	if d.terminalAllowed(name) {
		return d.terminalValue(home, name)
	}
	ask := wire.RequestSecretUse{Name: name, Use: wire.SecretUseTerminal, Place: command}
	id := d.openTerminalRequest(home, ask)
	held := make(chan struct{}, 1)
	d.secretUseMu.Lock()
	if d.terminalHeld == nil {
		d.terminalHeld = map[wire.UUID][]chan struct{}{}
	}
	d.terminalHeld[id] = append(d.terminalHeld[id], held)
	d.secretUseMu.Unlock()
	defer func() {
		d.secretUseMu.Lock()
		left := d.terminalHeld[id][:0]
		for _, c := range d.terminalHeld[id] {
			if c != held {
				left = append(left, c)
			}
		}
		if len(left) == 0 {
			delete(d.terminalHeld, id)
		} else {
			d.terminalHeld[id] = left
		}
		d.secretUseMu.Unlock()
	}()
	if rec := d.request(id); rec == nil || rec.State == wire.RequestStateOpen {
		timer := time.NewTimer(hold)
		defer timer.Stop()
		select {
		case <-held:
		case <-timer.C:
		case <-ctx.Done():
		case <-d.ctx.Done():
		}
	}
	if d.terminalAllowed(name) {
		return d.terminalValue(home, name)
	}
	if rec := d.request(id); rec != nil && rec.State == wire.RequestStateOpen {
		words := "Waiting for a person to allow " + name + " in Needs you (Allow Once, Allow for 1 Hour or Deny)."
		return wire.SecretTerminalValue{Request: &id, Words: &words}, nil
	}
	return wire.SecretTerminalValue{}, Invalid("A person denied %s to this terminal.", name)
}

// terminalValue is name's value, with the read recorded: no session, the place terminal.
func (d *Daemon) terminalValue(home, name string) (wire.SecretTerminalValue, error) {
	v, ok := d.sealedLocalSecret(home, name)
	if !ok {
		v, ok = skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)).Value(name)
	}
	if !ok {
		return wire.SecretTerminalValue{}, Invalid("%s is not set on this machine.", name)
	}
	log.Printf("agents-secret: %s read by a caller with no session", name)
	d.secretRead("", name, wire.SecretOperationUseCommand, terminalPlace)
	return wire.SecretTerminalValue{Value: &v}, nil
}

// terminalAllowed is whether a person allowed a call with no grant for name now: for the hour,
// or once (which this call takes).
func (d *Daemon) terminalAllowed(name string) bool {
	d.secretUseMu.Lock()
	defer d.secretUseMu.Unlock()
	if until, ok := d.terminalUntil[name]; ok {
		if nowFunc().Before(until) {
			return true
		}
		delete(d.terminalUntil, name)
	}
	if d.terminalOnceLeft[name] > 0 {
		d.terminalOnceLeft[name]--
		if d.terminalOnceLeft[name] == 0 {
			delete(d.terminalOnceLeft, name)
		}
		return true
	}
	return false
}

// openTerminalRequest is the open request for a terminal's use of name: the one opened before
// for the same name and command, when it is still open, so a call made again does not ask
// twice. It has no session; its folder is the personal home.
func (d *Daemon) openTerminalRequest(home string, ask wire.RequestSecretUse) wire.UUID {
	d.requests.mu.Lock()
	for _, r := range d.requests.byID {
		if s := r.Detail.SecretUse; s != nil && r.State == wire.RequestStateOpen && r.AskedBy == nil &&
			s.Use == wire.SecretUseTerminal && s.Name == ask.Name && s.Place == ask.Place {
			id := r.ID
			d.requests.mu.Unlock()
			return id
		}
	}
	at := now()
	r := &wire.Request{ID: store.NewUUID(), Kind: wire.RequestKindApprove, Source: wire.RequestSourceSecretUse,
		State: wire.RequestStateOpen, Title: "Print " + ask.Name + " in a terminal (" + ask.Place + ")",
		Detail: wire.RequestDetail{SecretUse: &ask}, Folder: string(fileURL(home, true)),
		Waiters: []wire.RequestWaiter{}, AskedAt: at}
	if d.requests.byID == nil {
		d.requests.byID = map[wire.UUID]*wire.Request{}
	}
	d.requests.byID[r.ID] = r
	d.saveRequestLocked(r)
	c := copyRequest(r)
	d.requests.mu.Unlock()
	log.Printf("secret use: a caller with no session (%s) asks to read %s", ask.Place, ask.Name)
	Broadcast(d, wire.NotifyRequestsChanged, wire.RequestUpdate{Request: c})
	d.raiseRequestEvent("request.opened", c, nil, nil)
	d.reconsider() // its banner
	return r.ID
}

// answerTerminalUse is requests/answer for a terminal's use: once, hour or deny.
func (d *Daemon) answerTerminalUse(rec wire.Request, a *wire.RequestSecretUseAnswer, by *wire.AuditActor) (wire.RequestUpdate, error) {
	ask := *rec.Detail.SecretUse
	summary := map[string]string{secretUseOnce: "Allowed once", secretUseHour: "Allowed for 1 hour", secretUseDeny: "Denied"}[a.Action]
	if summary == "" {
		return wire.RequestUpdate{}, Invalid("A terminal's request takes once, hour or deny.")
	}
	d.secretUseMu.Lock()
	switch a.Action {
	case secretUseOnce:
		if d.terminalOnceLeft == nil {
			d.terminalOnceLeft = map[string]int{}
		}
		d.terminalOnceLeft[ask.Name]++
	case secretUseHour:
		if d.terminalUntil == nil {
			d.terminalUntil = map[string]time.Time{}
		}
		d.terminalUntil[ask.Name] = nowFunc().Add(terminalHour)
	}
	d.secretUseMu.Unlock()
	if a.Action == secretUseDeny {
		use, place := wire.SecretOperationUseCommand, terminalPlace
		d.noteSecretOp(wire.SecretOperation{Name: ask.Name, What: wire.SecretOperationWhatDenied, Use: &use, Place: &place}, true)
	}
	if !d.endRequest(rec.ID, wire.RequestStateAnswered, &summary, "", by) {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already."}
	}
	log.Printf("secret use: %s for a caller with no session (%s): %s", ask.Name, ask.Place, a.Action)
	d.secretUseEnded(rec.ID)
	after := d.request(rec.ID)
	if after == nil {
		after = &rec
	}
	return wire.RequestUpdate{Request: *after}, nil
}

// terminalEnded wakes every call held on a terminal's request that ended.
func (d *Daemon) terminalEnded(id wire.UUID) {
	d.secretUseMu.Lock()
	defer d.secretUseMu.Unlock()
	for _, c := range d.terminalHeld[id] {
		select {
		case c <- struct{}{}:
		default:
		}
	}
}

// terminalSecretCommand is `agentsd secret NAME` with no session's grant: it asks agentsd on
// socket, and waits while a person has not answered, saying so once on errOut.
func terminalSecretCommand(socket, name string, out, errOut io.Writer) int {
	params := wire.SecretTerminalRequest{Name: name}
	if c := parentCommand(); c != "" {
		params.Command = &c
	}
	said := false
	for {
		var got wire.SecretTerminalValue
		if err := callSocketFor(socket, wire.CallSecretsTerminalValue.Name, params, &got, formHoldLimit+30*time.Second); err != nil {
			fmt.Fprintln(errOut, "agents-secret: "+name+": "+err.Error())
			return 1
		}
		if got.Value != nil {
			_, _ = io.WriteString(out, *got.Value)
			return 0
		}
		if got.Request == nil {
			fmt.Fprintln(errOut, "agents-secret: "+name+": agentsd gave no value")
			return 1
		}
		if !said && got.Words != nil {
			fmt.Fprintln(errOut, "agents-secret: "+*got.Words)
			said = true
		}
	}
}

// parentCommand is the name of the process that ran agents-secret: the shim execs agentsd, so
// it is this process's parent. agentsd cannot check it; the request says it as told.
var parentCommand = func() string {
	ppid := os.Getppid()
	if ppid <= 1 {
		return ""
	}
	if b, err := os.ReadFile("/proc/" + strconv.Itoa(ppid) + "/comm"); err == nil {
		return strings.TrimSpace(string(b))
	}
	b, err := exec.Command("/bin/ps", "-o", "comm=", "-p", strconv.Itoa(ppid)).Output()
	if err != nil {
		return ""
	}
	return filepath.Base(strings.TrimSpace(string(b)))
}

// callSocketFor makes one call on daemon.sock and decodes its result into result.
func callSocketFor(path, method string, params, result any, wait time.Duration) error {
	c, err := net.DialTimeout("unix", path, 5*time.Second)
	if err != nil {
		return fmt.Errorf("agentsd is not answering on %s: %w", path, err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(wait))
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	if _, err := c.Write(append(b, '\n')); err != nil {
		return err
	}
	r := bufio.NewReaderSize(c, 1<<20)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return err
		}
		var reply struct {
			ID     *json.RawMessage `json:"id"`
			Result json.RawMessage  `json:"result"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(line, &reply) != nil || reply.ID == nil {
			continue // a notification
		}
		if reply.Error != nil {
			return fmt.Errorf("%s", reply.Error.Message)
		}
		return json.Unmarshal(reply.Result, result)
	}
}
