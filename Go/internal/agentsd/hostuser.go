package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"regexp"
	goruntime "runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The user this machine belongs to (#1761, spec 736 US6): host/user, which the control
// plane sends on channel 0 at each join and when the user changes. It says whether the
// user is a person or a bot, and the labels runs-on: matches (FR-034). On a bot's machine
// nobody answers: an agent has no ask tools, a permission is answered by its policy alone,
// and at the bot's spend cap no workflow starts (FR-032, FR-033).

// kindBot is host/user's kind for a bot.
const kindBot = "bot"

// hostUserFile keeps the last host/user, so a machine started with its control plane away
// is still a bot's.
const hostUserFile = "host-user.json"

type hostUserState struct {
	hostUserMu   sync.Mutex
	hostUserRead bool
	hostUser     *wire.MachineUser
}

func (d *Daemon) hostUserPath() string { return filepath.Join(d.Store.Loc.Root, hostUserFile) }

// user is the last host/user, read from the root the first time; nil before any.
func (d *Daemon) user() *wire.MachineUser {
	d.hostUserMu.Lock()
	defer d.hostUserMu.Unlock()
	if !d.hostUserRead {
		d.hostUserRead = true
		var kept wire.MachineUser
		if b, err := os.ReadFile(d.hostUserPath()); err == nil && json.Unmarshal(b, &kept) == nil && kept.User != "" {
			d.hostUser = &kept
		}
	}
	return d.hostUser
}

// toldHostUser is host/user.
func (d *Daemon) toldHostUser(params json.RawMessage) {
	var u wire.MachineUser
	if err := json.Unmarshal(params, &u); err != nil || u.User == "" {
		log.Printf("host/user: %v", err)
		return
	}
	d.user()
	d.hostUserMu.Lock()
	was := d.hostUser
	d.hostUser = &u
	d.hostUserMu.Unlock()
	if b, err := json.Marshal(u); err == nil {
		if err := os.WriteFile(d.hostUserPath(), b, 0o600); err != nil {
			log.Printf("host/user: %v", err)
		}
	}
	if was == nil || was.Kind != u.Kind || strings.Join(was.Labels, ",") != strings.Join(u.Labels, ",") ||
		strings.Join(was.Bots, ",") != strings.Join(u.Bots, ",") {
		log.Printf("host/user: %s %s, labels %s", u.Kind, u.Name, strings.Join(u.Labels, ", "))
		// Which workflows run here may have changed.
		d.tellEveryWorkflow()
	}
}

// isBot says this machine is a bot's: nobody answers here.
func (d *Daemon) isBot() bool {
	u := d.user()
	return u != nil && u.Kind == kindBot
}

// capped says a bot's machine is at its spend cap now, and until when.
func (d *Daemon) capped(at time.Time) (time.Time, bool) {
	u := d.user()
	if u == nil || u.Kind != kindBot || u.CapReachedUntil == nil {
		return time.Time{}, false
	}
	until := u.CapReachedUntil.Time()
	return until, at.Before(until)
}

// osLabel is the os label: macos or linux.
func osLabel() string {
	if goruntime.GOOS == "darwin" {
		return "macos"
	}
	return goruntime.GOOS
}

// machineLabels are what runs-on: matches here, in lower case: the machine's id, its os,
// and what the control plane said (its provider, its user's or bot's name).
func (d *Daemon) machineLabels() map[string]bool {
	labels := map[string]bool{strings.ToLower(d.machineID()): true, osLabel(): true}
	if u := d.user(); u != nil {
		for _, l := range u.Labels {
			labels[strings.ToLower(strings.TrimSpace(l))] = true
		}
		if u.Name != "" {
			labels[strings.ToLower(u.Name)] = true
		}
	}
	return labels
}

// runsOnHere says this machine matches a runs-on: list (#2064). Its machine ids are a
// choice: one of them is this machine's. Every other label (an os, a provider, a user's or
// bot's name) this machine has. A machine has one id, so two ids that all had to match
// would run nowhere, and the clients' Runs on, one switch per machine, names several.
func (d *Daemon) runsOnHere(runsOn []string) bool {
	labels := d.machineLabels()
	own := strings.ToLower(d.machineID())
	named, here := false, false
	for _, l := range runsOn {
		l = strings.ToLower(strings.TrimSpace(l))
		if l == own || isMachineID(l) {
			named = true
			here = here || l == own
			continue
		}
		if !labels[l] {
			return false
		}
	}
	return !named || here
}

// isMachineID says a label is a machine's id, as the clients tell it: a UUID, or 32 hex
// digits (Linux /etc/machine-id).
func isMachineID(label string) bool { return machineIDPattern.MatchString(label) }

var machineIDPattern = regexp.MustCompile(`^(?i:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{32})$`)

// hearsFor is the bot a person's machine hears a workflow for (#2027): a runs-on: workflow
// that does not run here, names a bot of the person's groups, and has a server trigger.
// Once approved here, its server triggers are heard with this machine's servers, and each
// match goes to the control plane (workflows/trigger), which runs it on one of the bot's
// machines. Nothing of it runs here; "" for any other.
func (d *Daemon) hearsFor(w wire.Workflow) string {
	u := d.user()
	if u == nil || u.Kind == kindBot || len(u.Bots) == 0 || len(w.RunsOn) == 0 || d.runsHere(w) {
		return ""
	}
	hasServer := false
	for _, t := range w.Triggers {
		if _, ok := serverTrigger(t); ok {
			hasServer = true
			break
		}
	}
	if !hasServer {
		return ""
	}
	for _, l := range w.RunsOn {
		l = strings.ToLower(strings.TrimSpace(l))
		for _, b := range u.Bots {
			if strings.ToLower(b) == l {
				return b
			}
		}
	}
	return ""
}

// listedHere says a workflow is this machine's to show and approve: it runs here, or it is
// heard here for a bot.
func (d *Daemon) listedHere(w wire.Workflow) bool { return d.runsHere(w) || d.hearsFor(w) != "" }

// claimsRuns says a run of this workflow is claimed first: a bot's machine, with runs-on:,
// runs a trigger once across all of that bot's machines (FR-034).
func (d *Daemon) claimsRuns(w wire.Workflow) bool { return len(w.RunsOn) > 0 && d.isBot() }

// triggerID is the same words for the same trigger on every machine that heard it: a
// schedule's due time, or the event's name and details. Run now has none.
func triggerID(fr fireRequest, event *wire.Event) string {
	if fr.dueAt != nil {
		return "schedule:" + fr.dueAt.UTC().Format(time.RFC3339)
	}
	if event == nil {
		return ""
	}
	keys := make([]string, 0, len(event.Details))
	for k := range event.Details {
		// A server's event is the same on every machine by its server, event and id (#2011):
		// when it was heard, what was missed before it, its subscription and what each
		// machine's credentials were shown of it (a bot's, a person's heard for it, #2027)
		// are each machine's own.
		if event.Details["mcp_event_id"] != "" && k != "server" && k != "event" && k != "mcp_event_id" {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	h := sha256.New()
	h.Write([]byte(event.Name))
	for _, k := range keys {
		h.Write([]byte{0})
		h.Write([]byte(k + "=" + event.Details[k]))
	}
	return "event:" + event.Name + ":" + hex.EncodeToString(h.Sum(nil))[:24]
}

// claimRun asks the control plane to run this trigger here. True when this machine runs it:
// it won, or there is nothing to claim. A control plane that cannot be asked runs nothing,
// so two machines never both run it.
func (d *Daemon) claimRun(folder, id, trigger string) bool {
	if trigger == "" {
		return true
	}
	ask := d.askControl.Load()
	if ask == nil {
		return true
	}
	out, err := (*ask)(d.ctx, wire.CallWorkflowsClaimRun.Name, wire.WorkflowClaim{Workflow: workflowName(folder, id), Trigger: trigger})
	if err != nil {
		log.Printf("workflow %s: the claim for %s was not answered: %v", id, trigger, err)
		return false
	}
	var claimed wire.WorkflowClaimed
	if json.Unmarshal(out, &claimed) != nil {
		return false
	}
	if !claimed.Won {
		log.Printf("workflow %s: another machine runs %s", id, trigger)
	}
	return claimed.Won
}

// linkCheckWait is how long a link check waits for the control plane: a message is not
// held up behind one that does not answer for the uplink's whole wait (#2060).
const linkCheckWait = 10 * time.Second

// senderChecks is what links/check said of each sender in one poll, so a burst of
// messages from one sender asks once, not once a message (#2060). Only for a poll: a link
// made a minute later is heard at the next.
type senderChecks map[string]senderCheck

type senderCheck struct {
	linked wire.ChannelLinkChecked
	ok     bool
}

// linked is senderLinked, asked once a sender for c; a nil c asks every time.
func (c senderChecks) linked(d *Daemon, sender wire.ChannelSender) (wire.ChannelLinkChecked, bool) {
	if c == nil {
		return d.senderLinked(sender)
	}
	// The whole sender is the key: its DKIM result is checked too.
	key, _ := json.Marshal(sender)
	if got, asked := c[string(key)]; asked {
		return got.linked, got.ok
	}
	linked, ok := d.senderLinked(sender)
	c[string(key)] = senderCheck{linked, ok}
	return linked, ok
}

// senderLinked asks the control plane whether a channel message's sender is linked to a
// person (#1762, FR-037). False, so nothing starts, when it is not, when it names no one,
// when it is refused (an email that fails DKIM), and when there is no control plane to ask or it does not answer.
func (d *Daemon) senderLinked(sender wire.ChannelSender) (wire.ChannelLinkChecked, bool) {
	if strings.TrimSpace(sender.Identity) == "" {
		log.Printf("channel message from %s names no one: nothing started", sender.Channel)
		return wire.ChannelLinkChecked{}, false
	}
	ask := d.askControl.Load()
	if ask == nil {
		log.Printf("channel message from %s: no control plane to say whom it is from", sender.Channel)
		return wire.ChannelLinkChecked{}, false
	}
	ctx, cancel := context.WithTimeout(d.ctx, linkCheckWait)
	defer cancel()
	out, err := (*ask)(ctx, wire.CallLinksCheck.Name, sender)
	if err != nil {
		log.Printf("channel message from %s: the link check was not answered: %v", sender.Channel, err)
		return wire.ChannelLinkChecked{}, false
	}
	var checked wire.ChannelLinkChecked
	if json.Unmarshal(out, &checked) != nil || checked.User == nil || *checked.User == "" {
		if checked.Refused != nil {
			log.Printf("channel message from %s refused: %s", sender.Channel, *checked.Refused)
		}
		return wire.ChannelLinkChecked{}, false
	}
	return checked, true
}

// noOneAnswersWords is said in an agent's transcript on a bot's machine, where a question
// or a permission has no one to answer it.
const noOneAnswersWords = "No one answers on a bot's machine: the bot's policy refused it, and the agent carries on."
