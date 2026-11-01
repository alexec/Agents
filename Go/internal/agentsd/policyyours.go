package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/policylayers"
	"github.com/alexec/agents/Go/wire"
)

// Your layer (#2957, FR-009 to FR-013): the person's own rules, kept on the keeper (research
// R4) at <settings>/policy-yours.json, signed with the person key, and folded into the
// effective policy (policy.go) above a folder and below the organisation. This file is that
// layer's whole lifecycle on one machine: the first-start move from the person's old settings
// files (FR-012, research R9), signing a change on the keeper, verifying a copy on a machine
// that is not the keeper, and the refusals of policy/setYours (FR-010, FR-011). Its shape
// mirrors policy.go's org-policy keep/verify/apply pattern exactly, keyed on the person key
// instead of the control key, and policy-yours.json/policy-yours-seen.json instead of
// policy.json/policy-seen.json.

const (
	yourPolicyFile     = "policy-yours.json"
	yourPolicySeenFile = "policy-yours-seen.json"
)

// yourPolicyBook is the Daemon's state for your layer, embedded in Daemon (daemon.go).
type yourPolicyBook struct {
	yoursMu   sync.Mutex
	yoursRead bool
	// yoursNow is the signed document this machine trusts, nil when it has none it can
	// trust (an untrusted file, or none at all before the first-start move runs).
	yoursNow *keptYourPolicy
	// yoursWas is the highest revision ever saved here, and whether the first-start move
	// has already run, kept across a lost or untrusted file (FR-012: it runs at most once).
	yoursWas yourPolicySeen
	// yoursRulesCache is the current trusted layer's rules, kept for lock-free reads from
	// another lock's critical section (cost.go's costMu, in particular, T019): stored under
	// yoursMu whenever yoursNow changes, read without any lock by yourPolicyRules. The last
	// good value stays when a later read or write fails (FR-011's "keep the last good copy").
	yoursRulesCache atomic.Pointer[wire.PolicyRules]
}

// WarmYourPolicy reads or makes your layer once, before any connection is accepted
// (cmd/agentsd/main.go, after PersonKey is set to its real store): yourPolicyRules then
// never has to take yoursMu from inside another lock's critical section (cost.go's costMu
// reads your layer's budgets, for one), which could risk a lock-order deadlock with a
// concurrent policy/setYours.
func (d *Daemon) WarmYourPolicy() { d.yourPolicyRules() }

// yourPolicyRules is your layer's rules, for policy.go's effective() and every rule this
// slice reads from your layer (T019); lock-free, so it is safe to call from inside another
// lock's critical section without risking a lock-order deadlock with yoursMu.
func (d *Daemon) yourPolicyRules() wire.PolicyRules {
	if v := d.yoursRulesCache.Load(); v != nil {
		return *v
	}
	d.yoursMu.Lock()
	d.readYoursLocked()
	d.yoursMu.Unlock()
	if v := d.yoursRulesCache.Load(); v != nil {
		return *v
	}
	return wire.PolicyRules{}
}

// keptYourPolicy is policy-yours.json: the document's own bytes, as signed.
type keptYourPolicy struct {
	Policy    json.RawMessage      `json:"policy"`
	Signature wire.PolicySignature `json:"signature"`
	policy    wire.YourPolicy
}

// yourPolicySeen is policy-yours-seen.json.
type yourPolicySeen struct {
	Revision int64 `json:"revision"`
	Moved    bool  `json:"moved"`
}

func (d *Daemon) yourPolicyPath() string     { return filepath.Join(d.SettingsDir, yourPolicyFile) }
func (d *Daemon) yourPolicySeenPath() string { return filepath.Join(d.SettingsDir, yourPolicySeenFile) }

// readYoursLocked reads the kept layer the first time: the first-start move (FR-012) when
// none has ever been saved here, otherwise the file on disk, checked. Called with yoursMu
// held.
func (d *Daemon) readYoursLocked() {
	if d.yoursRead {
		return
	}
	d.yoursRead = true
	d.yoursNow = nil
	d.yoursWas = yourPolicySeen{}
	if b, err := os.ReadFile(d.yourPolicySeenPath()); err == nil {
		json.Unmarshal(b, &d.yoursWas)
	}
	b, err := os.ReadFile(d.yourPolicyPath())
	if err != nil {
		if !d.yoursWas.Moved {
			d.firstStartMoveLocked()
		}
		return
	}
	var kept keptYourPolicy
	if json.Unmarshal(b, &kept) != nil || !d.trustsYoursLocked(&kept) {
		log.Printf("policy: %s fails the signature check; the last good copy applies", yourPolicyFile)
		return
	}
	if kept.policy.Revision < d.yoursWas.Revision {
		log.Printf("policy: %s is revision %d, older than the %d applied here; kept", yourPolicyFile, kept.policy.Revision, d.yoursWas.Revision)
		return
	}
	d.yoursNow = &kept
	rules := kept.policy.Rules
	d.yoursRulesCache.Store(&rules)
}

// trustsYoursLocked checks a layer's signature against this machine's own person key
// (slice 2's scope: this machine is always its own keeper, research R4's "a person with no
// Mac" case included). A non-keeper machine verifying a copy against a pinned key of
// another machine's is slice 3's work (research R3, T030).
func (d *Daemon) trustsYoursLocked(k *keptYourPolicy) bool {
	if len(k.Policy) == 0 || k.Signature.Alg != controllink.PolicyAlg {
		return false
	}
	if json.Unmarshal(k.Policy, &k.policy) != nil || k.policy.Revision < 1 || k.Signature.Version != k.policy.Revision {
		return false
	}
	public := d.yoursPublicKeyLocked()
	if public == nil {
		return false
	}
	return controllink.VerifyPolicy(public, k.Policy, k.Signature.Sig)
}

// yoursPublicKeyLocked is this machine's own person key's public half, making the key the
// first time, as the keeper of a new layer does.
func (d *Daemon) yoursPublicKeyLocked() []byte {
	private, err := controllink.PersonPrivateKey(d.PersonKey)
	if err != nil {
		log.Printf("policy: the person key: %v", err)
		return nil
	}
	public, err := controllink.PublicKey(private)
	if err != nil {
		log.Printf("policy: the person key: %v", err)
		return nil
	}
	return public
}

// saveYoursLocked signs next with this machine's person key and keeps it. Called with
// yoursMu held.
func (d *Daemon) saveYoursLocked(next wire.YourPolicy) error {
	raw, err := json.Marshal(next)
	if err != nil {
		return err
	}
	private, err := controllink.PersonPrivateKey(d.PersonKey)
	if err != nil {
		return err
	}
	public, err := controllink.PublicKey(private)
	if err != nil {
		return err
	}
	sig, err := controllink.SignPolicy(private, raw)
	if err != nil {
		return err
	}
	kept := keptYourPolicy{Policy: raw, Signature: wire.PolicySignature{
		Version: next.Revision, KeyID: controllink.KeyID(public), Alg: controllink.PolicyAlg, Sig: sig,
	}, policy: next}
	b, err := json.Marshal(kept)
	if err != nil {
		return err
	}
	if err := store.WriteAtomically(d.yourPolicyPath(), b, 0o600); err != nil {
		return err
	}
	d.yoursNow = &kept
	rules := next.Rules
	d.yoursRulesCache.Store(&rules)
	d.yoursWas = yourPolicySeen{Revision: next.Revision, Moved: true}
	d.saveYoursSeenLocked()
	return nil
}

func (d *Daemon) saveYoursSeenLocked() {
	b, err := json.Marshal(d.yoursWas)
	if err != nil {
		return
	}
	if err := store.WriteAtomically(d.yourPolicySeenPath(), b, 0o600); err != nil {
		log.Printf("policy: keep %s: %v", yourPolicySeenFile, err)
	}
}

// personIDLocked is the person's id for YourPolicy.person: the user scope's user, or
// "local" for a person with no control plane (data-model.md "YourPolicy").
func (d *Daemon) personIDLocked() string {
	if u := d.user(); u != nil && u.User != "" {
		return u.User
	}
	return "local"
}

// yourPolicyState is policy/yours.
func (d *Daemon) yourPolicyState() wire.YourPolicyState {
	d.yoursMu.Lock()
	defer d.yoursMu.Unlock()
	d.readYoursLocked()
	policy := wire.YourPolicy{Person: d.personIDLocked(), Keeper: d.machineID()}
	if d.yoursNow != nil {
		policy = d.yoursNow.policy
	}
	var pinnedKeyID *string
	if public := d.yoursPublicKeyLocked(); public != nil {
		id := controllink.KeyID(public)
		pinnedKeyID = &id
	}
	return wire.YourPolicyState{Policy: policy, Keeper: wire.PolicyKeeper{Host: policy.Keeper, Name: policy.Keeper}, PinnedKeyID: pinnedKeyID}
}

// forbiddenCallerRefusal is why policy/setYours refuses this caller (FR-010, SC-004): only
// the person's own clients may change your layer. The agent socket role, an MCP tool (which
// has no tool that reaches this method) and a workflow (which runs as the agent socket
// role too) are all refused by the same gate.
func forbiddenCallerRefusal(c *Client) error {
	if c != nil && (c.Role == RoleControl || c.Role == RoleDevice) {
		return nil
	}
	return &Error{Code: CodeNotPermitted, Message: "Only your own clients can change your policy."}
}

// changedFromFor is YourPolicy.changedFrom, a best effort from the connection's role; a
// fuller client identity (which device, which browser) is a later client-side concern.
func changedFromFor(c *Client) *wire.YourPolicyChangedFrom {
	kind := "mac"
	if c != nil && c.Role == RoleDevice {
		kind = "remote"
	}
	return &wire.YourPolicyChangedFrom{Client: "this machine", Kind: kind}
}

// setYourPolicy is policy/setYours (FR-010, FR-011; contracts/policy-layers-api.md).
// editYoursLocked reads your layer, lets edit change its rules in place, and saves a new
// revision, unless edit returns an error, in which case nothing is changed: the shared
// shape of every old write path that still changes your layer directly (notify.go's
// setYourNoticeLimits/setYourArchiveMyChats, cost/setLimits, workflows/setLimit),
// bypassing policy/setYours's own caller and revision checks, since these are host-side
// mirrors of an older client call, not a client's own direct edit.
func (d *Daemon) editYoursLocked(edit func(*wire.PolicyRules) error) error {
	d.yoursMu.Lock()
	d.readYoursLocked()
	rules := wire.PolicyRules{}
	revision := int64(0)
	if d.yoursNow != nil {
		rules = d.yoursNow.policy.Rules
		revision = d.yoursNow.policy.Revision
	}
	if err := edit(&rules); err != nil {
		d.yoursMu.Unlock()
		return err
	}
	next := wire.YourPolicy{Rules: rules, Revision: revision + 1, Changed: wire.DateOf(nowFunc()),
		ChangedFrom: changedFromFor(nil), Person: d.personIDLocked(), Keeper: d.machineID()}
	err := d.saveYoursLocked(next)
	d.yoursMu.Unlock()
	if err == nil {
		d.policyChanged()
	}
	return err
}

func (d *Daemon) setYourPolicy(c *Client, r wire.SetYourPolicyRequest) (wire.YourPolicy, error) {
	if err := forbiddenCallerRefusal(c); err != nil {
		return wire.YourPolicy{}, err
	}
	raw, err := json.Marshal(r.Rules)
	if err != nil {
		return wire.YourPolicy{}, Invalid("your policy: %v", err)
	}
	if _, err := policylayers.Validate(raw); err != nil {
		return wire.YourPolicy{}, Invalid("Your policy: %v", err)
	}
	d.yoursMu.Lock()
	d.readYoursLocked()
	me := d.machineID()
	var current *wire.YourPolicy
	if d.yoursNow != nil {
		current = &d.yoursNow.policy
	}
	if current != nil && current.Keeper != me {
		d.yoursMu.Unlock()
		return wire.YourPolicy{}, &Error{Code: wire.FailureNotKeeper,
			Message: "Only " + current.Keeper + " keeps your policy. Change it there."}
	}
	var currentRevision int64
	if current != nil {
		currentRevision = current.Revision
	}
	if r.Revision != currentRevision {
		d.yoursMu.Unlock()
		return wire.YourPolicy{}, &Error{Code: wire.FailureChangedElsewhere,
			Message: "Your policy changed elsewhere. Load it again before saving."}
	}
	next := wire.YourPolicy{
		Rules: r.Rules, Revision: currentRevision + 1, Changed: wire.DateOf(nowFunc()),
		ChangedFrom: changedFromFor(c), Person: d.personIDLocked(), Keeper: me,
	}
	err = d.saveYoursLocked(next)
	d.yoursMu.Unlock()
	if err != nil {
		return wire.YourPolicy{}, &Error{Code: wire.FailureCouldNotSave, Message: yourPolicyFile + ": " + err.Error()}
	}
	// policyChanged re-marks every agent and tells clients; done after the lock is let go.
	d.policyChanged()
	return next, nil
}

func (d *Daemon) registerPolicyYours() {
	On(d, wire.CallPolicyYours, func(context.Context, *Client, wire.Empty) (wire.YourPolicyState, error) {
		return d.yourPolicyState(), nil
	})
	On(d, wire.CallPolicySetYours, func(_ context.Context, c *Client, r wire.SetYourPolicyRequest) (wire.YourPolicy, error) {
		return d.setYourPolicy(c, r)
	})
}

// MARK: the first-start move (FR-012, research R9)

// moveAsideLocked renames an old settings file so nothing reads it again, logging the one
// failure worth knowing about: it could not be moved, so it could be read again by mistake.
func moveAsideLocked(path string) {
	if err := os.Rename(path, path+".moved"); err != nil && !os.IsNotExist(err) {
		log.Printf("policy: move %s aside: %v", filepath.Base(path), err)
	}
}

// firstStartMoveLocked makes your layer once from the person's old settings files
// (FR-012, research R9): limits.json -> budgets; workflow-limit.json's total ->
// workflows.mostOn, only when the file exists; display.json's noticeBurst and
// noticeCooldownMinutes -> noticeLimits, only when set; agentsMayArchiveMyChats: false ->
// archiveMyChats: false; runtime-environment.json -> environment. Each old file is renamed
// <name>.moved (or its moved keys removed from display.json) so nothing reads it again
// (SC-001). permissionMode, permissionRequests and sandbox are not moved: today "unset"
// already means no limit (R5, R7). Called with yoursMu held, at most once.
func (d *Daemon) firstStartMoveLocked() {
	rules := wire.PolicyRules{}

	if b, err := os.ReadFile(d.limitsPath()); err == nil {
		var l wire.CostLimits
		json.Unmarshal(b, &l)
		budgets := wire.PolicyRuleBudgets{PerAgentTokens: l.PerAgentTokens, DailyTokens: l.DailyTokens}
		if l.Daily != nil {
			daily := *l.Daily
			budgets.Daily = &daily
		}
		if l.PerAgent != nil {
			perAgent := *l.PerAgent
			budgets.PerAgent = &perAgent
		}
		if budgets != (wire.PolicyRuleBudgets{}) {
			rules.Budgets = &budgets
		}
		moveAsideLocked(d.limitsPath())
	}

	workflowLimitPath := filepath.Join(d.SettingsDir, "workflow-limit.json")
	if b, err := os.ReadFile(workflowLimitPath); err == nil {
		var l struct {
			Total *int64 `json:"total"`
		}
		json.Unmarshal(b, &l)
		if l.Total != nil {
			rules.Workflows = &wire.PolicyWorkflows{MostOn: l.Total}
		}
		moveAsideLocked(workflowLimitPath)
	}

	displayPath := d.displayFile()
	if b, err := os.ReadFile(displayPath); err == nil {
		var fields map[string]json.RawMessage
		if json.Unmarshal(b, &fields) == nil {
			changed := false
			if raw, ok := fields[noticeBurstKey]; ok {
				var v int64
				if json.Unmarshal(raw, &v) == nil {
					if rules.NoticeLimits == nil {
						rules.NoticeLimits = &wire.PolicyNoticeLimits{}
					}
					rules.NoticeLimits.Burst = &v
				}
				delete(fields, noticeBurstKey)
				changed = true
			}
			if raw, ok := fields[noticeCooldownKey]; ok {
				var minutes float64
				if json.Unmarshal(raw, &minutes) == nil {
					if rules.NoticeLimits == nil {
						rules.NoticeLimits = &wire.PolicyNoticeLimits{}
					}
					wait := int64(minutes)
					rules.NoticeLimits.WaitMinutes = &wait
				}
				delete(fields, noticeCooldownKey)
				changed = true
			}
			if raw, ok := fields[agentsMayArchiveMyChatsKey]; ok {
				var v bool
				if json.Unmarshal(raw, &v) == nil {
					rules.ArchiveMyChats = &v
				}
				delete(fields, agentsMayArchiveMyChatsKey)
				changed = true
			}
			if changed {
				if nb, err := json.Marshal(fields); err == nil {
					store.WriteAtomically(displayPath, nb, 0o644)
				}
			}
		}
	}

	envPath := filepath.Join(d.SettingsDir, passThroughFile)
	if b, err := os.ReadFile(envPath); err == nil {
		var l passThroughList
		json.Unmarshal(b, &l)
		if len(l.Names) > 0 || len(l.Runtimes) > 0 {
			rules.Environment = &wire.PolicyEnvironment{PassThrough: l.Names, Runtimes: l.Runtimes}
		}
		moveAsideLocked(envPath)
	}

	next := wire.YourPolicy{Rules: rules, Revision: 1, Changed: wire.DateOf(nowFunc()), Person: d.personIDLocked(), Keeper: d.machineID()}
	if err := d.saveYoursLocked(next); err != nil {
		log.Printf("policy: the first-start move: %v", err)
	}
}
