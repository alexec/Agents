package agentsd

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
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
	hostUser     *wire.HostUser
}

func (d *Daemon) hostUserPath() string { return filepath.Join(d.Store.Loc.Root, hostUserFile) }

// user is the last host/user, read from the root the first time; nil before any.
func (d *Daemon) user() *wire.HostUser {
	d.hostUserMu.Lock()
	defer d.hostUserMu.Unlock()
	if !d.hostUserRead {
		d.hostUserRead = true
		var kept wire.HostUser
		if b, err := os.ReadFile(d.hostUserPath()); err == nil && json.Unmarshal(b, &kept) == nil && kept.User != "" {
			d.hostUser = &kept
		}
	}
	return d.hostUser
}

// toldHostUser is host/user.
func (d *Daemon) toldHostUser(params json.RawMessage) {
	var u wire.HostUser
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
	if was == nil || was.Kind != u.Kind || strings.Join(was.Labels, ",") != strings.Join(u.Labels, ",") {
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

// runsOnHere says this machine has every label of a runs-on: list.
func (d *Daemon) runsOnHere(runsOn []string) bool {
	labels := d.machineLabels()
	for _, l := range runsOn {
		if !labels[strings.ToLower(strings.TrimSpace(l))] {
			return false
		}
	}
	return true
}

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
	// By the project folder's name: each machine keeps its own copy of the project, at a path of its own.
	out, err := (*ask)(d.ctx, wire.CallWorkflowsClaimRun.Name, wire.WorkflowClaim{Workflow: filepath.Base(folder) + "/" + id, Trigger: trigger})
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

// noOneAnswersWords is said in an agent's transcript on a bot's machine, where a question
// or a permission has no one to answer it.
const noOneAnswersWords = "No one answers on a bot's machine: the bot's policy refused it, and the agent carries on."
