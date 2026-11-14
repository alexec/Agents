package agentsd

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/policylayers"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Untrusted copies of your layer (#3230). After the root moves to another Mac,
// policy-yours.json is signed with a person key this Mac does not have, so its rules stop
// applying; a change here keeps it aside as policy-yours.json.untrusted-<time> (#3122).
// policy/yours tells the clients about the newest such copy, with its rules in words, and
// policy/settleUntrustedYours does what the person chose: sign those rules with this Mac's
// person key, or set the copy aside. Nothing here signs a copy without the person: that
// would make the signature check worthless.

// untrustedAsideName is a copy keepUntrustedAsideLocked kept aside and nobody settled yet.
// A settled copy gets settledSuffix, so it is kept on disk but not shown again.
var untrustedAsideName = regexp.MustCompile(`^` + regexp.QuoteMeta(yourPolicyFile) + `\.untrusted-(\d+)$`)

const settledSuffix = ".settled"

// untrustedFilesLocked is every unsettled untrusted copy, newest first: policy-yours.json
// itself while it fails the check, then the copies kept aside, by the time they were kept.
// Called with yoursMu held.
func (d *Daemon) untrustedFilesLocked() []string {
	var names []string
	if d.yoursUntrusted {
		names = append(names, yourPolicyFile)
	}
	entries, _ := os.ReadDir(d.SettingsDir)
	type aside struct {
		name string
		at   int64
	}
	var kept []aside
	for _, e := range entries {
		if m := untrustedAsideName.FindStringSubmatch(e.Name()); m != nil {
			at, _ := strconv.ParseInt(m[1], 10, 64)
			kept = append(kept, aside{e.Name(), at})
		}
	}
	sort.Slice(kept, func(i, j int) bool { return kept[i].at > kept[j].at })
	for _, k := range kept {
		names = append(names, k.name)
	}
	return names
}

// untrustedYoursLocked is the newest untrusted copy that can be read, or nil when there is
// none. Its signature is not checked: the rules are only shown. Called with yoursMu held.
func (d *Daemon) untrustedYoursLocked() *wire.UntrustedYourPolicy {
	for _, name := range d.untrustedFilesLocked() {
		b, err := os.ReadFile(filepath.Join(d.SettingsDir, name))
		if err != nil {
			continue
		}
		var kept keptYourPolicy
		if json.Unmarshal(b, &kept) != nil || json.Unmarshal(kept.Policy, &kept.policy) != nil {
			continue
		}
		p := kept.policy
		return &wire.UntrustedYourPolicy{File: name, Rules: p.Rules, Revision: p.Revision, Changed: p.Changed,
			Keeper: p.Keeper, KeyID: kept.Signature.KeyID, Lines: ruleLines(p.Rules)}
	}
	return nil
}

// ruleLines is each rule that rules sets, in the Policy pane's words and order.
func ruleLines(rules wire.PolicyRules) []wire.PolicyRuleLine {
	lines := []wire.PolicyRuleLine{}
	for _, r := range policylayers.Resolve([]policylayers.Layer{{Ref: youLayerRef(), Rules: rules}}).Rules {
		if r.Decides != nil {
			lines = append(lines, wire.PolicyRuleLine{Rule: r.Rule, Title: policylayers.RuleTitle(r.Rule), Words: r.Words})
		}
	}
	return lines
}

// settleUntrustedYours is policy/settleUntrustedYours: with sign, the shown copy's rules
// become the next revision of your layer, signed with this machine's person key; then every
// untrusted copy is set aside, so none is shown again.
func (d *Daemon) settleUntrustedYours(c *Client, r wire.SettleUntrustedYourPolicyRequest) (wire.YourPolicyState, error) {
	if err := forbiddenCallerRefusal(c); err != nil {
		return wire.YourPolicyState{}, err
	}
	changedElsewhere := &Error{Code: wire.FailureChangedElsewhere,
		Message: "Your policy changed elsewhere. Load it again before choosing."}
	d.yoursMu.Lock()
	d.readYoursLocked()
	shown := d.untrustedYoursLocked()
	if shown == nil || shown.File != r.File {
		d.yoursMu.Unlock()
		return wire.YourPolicyState{}, changedElsewhere
	}
	me := d.machineID()
	var currentRevision int64
	if d.yoursNow != nil {
		currentRevision = d.yoursNow.policy.Revision
	}
	if r.Revision != currentRevision {
		d.yoursMu.Unlock()
		return wire.YourPolicyState{}, changedElsewhere
	}
	if r.Sign {
		if d.yoursNow != nil && d.yoursNow.policy.Keeper != me {
			d.yoursMu.Unlock()
			return wire.YourPolicyState{}, &Error{Code: wire.FailureNotKeeper,
				Message: "Only " + d.yoursNow.policy.Keeper + " keeps your policy. Sign these rules there."}
		}
		raw, err := json.Marshal(shown.Rules)
		if err == nil {
			_, err = policylayers.Validate(raw)
		}
		if err != nil {
			d.yoursMu.Unlock()
			return wire.YourPolicyState{}, Invalid("Your policy: %v", err)
		}
		next := wire.YourPolicy{
			Rules: shown.Rules, Revision: max(currentRevision, shown.Revision) + 1, Changed: wire.DateOf(nowFunc()),
			ChangedFrom: changedFromFor(c), Person: d.personIDLocked(), Keeper: me,
		}
		// saveYoursLocked keeps an untrusted policy-yours.json aside before it writes.
		if err := d.saveYoursLocked(next); err != nil {
			d.yoursMu.Unlock()
			return wire.YourPolicyState{}, &Error{Code: wire.FailureCouldNotSave, Message: yourPolicyFile + ": " + err.Error()}
		}
		log.Printf("policy: the person signed the rules of %s again with this machine's person key, as revision %d", shown.File, next.Revision)
	} else if err := d.keepUntrustedAsideLocked(); err != nil {
		d.yoursMu.Unlock()
		return wire.YourPolicyState{}, &Error{Code: wire.FailureCouldNotSave, Message: err.Error()}
	}
	d.settleUntrustedLocked()
	d.yoursMu.Unlock()
	// Tells every client to load your layer again, so none still shows the copy.
	d.policyChanged()
	if r.Sign {
		d.mirrorYoursToDisplay(shown.Rules)
	}
	return d.yourPolicyState(), nil
}

// settleUntrustedLocked marks every copy kept aside as settled. Called with yoursMu held,
// after keepUntrustedAsideLocked, so policy-yours.json is not one of them.
func (d *Daemon) settleUntrustedLocked() {
	for _, name := range d.untrustedFilesLocked() {
		if !strings.HasPrefix(name, yourPolicyFile+".") {
			continue
		}
		path := filepath.Join(d.SettingsDir, name)
		if err := os.Rename(path, path+settledSuffix); err != nil {
			log.Printf("policy: settle %s: %v", name, err)
		}
	}
}
