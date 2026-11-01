package agentsd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/policylayers"
	"github.com/alexec/agents/Go/internal/safe"
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
	// yoursUntrusted is whether policy-yours.json is on disk but fails the check (signed on
	// another Mac, or by a key this machine has not pinned, #3122): the next write keeps it
	// aside first (keepUntrustedAsideLocked), never writes over it.
	yoursUntrusted bool
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
	d.yoursUntrusted = false
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
		log.Printf("policy: %s fails the signature check (signed on another Mac?); the last good copy applies, and the next change keeps the file aside as %s.untrusted-<time>", yourPolicyFile, yourPolicyFile)
		d.yoursUntrusted = true
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

// trustsYoursLocked checks a layer's signature: against this machine's own person key when
// the layer names this machine as keeper, or against the key this machine has pinned
// otherwise (#2957, research R3/R4). A non-keeper machine with no pin yet trusts nothing on
// disk here: FR-011's "keep the last good copy" has no copy to keep until one is pinned, by
// a join code, policy/applyYours, or the control plane's first push (applySignedYours).
func (d *Daemon) trustsYoursLocked(k *keptYourPolicy) bool {
	if len(k.Policy) == 0 || k.Signature.Alg != controllink.PolicyAlg {
		return false
	}
	if json.Unmarshal(k.Policy, &k.policy) != nil || k.policy.Revision < 1 || k.Signature.Version != k.policy.Revision {
		return false
	}
	var public []byte
	if k.policy.Keeper == d.machineID() {
		public = d.yoursPublicKeyLocked()
	} else if pinned, err := controllink.LoadPinnedPersonKey(d.Store.Loc.Root); err == nil && pinned != nil {
		public = pinned.Key
	}
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

// keepUntrustedAsideLocked renames a policy-yours.json that fails the check to
// policy-yours.json.untrusted-<time> before a new layer is written (#3122): after the root
// moves to another Mac, that file holds the person's rules, signed by a key this Mac does
// not have, and an edit here must not write over it. An error means nothing may be
// written. Called with yoursMu held.
func (d *Daemon) keepUntrustedAsideLocked() error {
	if !d.yoursUntrusted {
		return nil
	}
	path := d.yourPolicyPath()
	aside := fmt.Sprintf("%s.untrusted-%d", path, nowFunc().Unix())
	if err := os.Rename(path, aside); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("keep the untrusted %s aside: %w", yourPolicyFile, err)
	}
	log.Printf("policy: %s was signed by a key this machine does not trust; kept as %s", yourPolicyFile, filepath.Base(aside))
	d.yoursUntrusted = false
	return nil
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
	if err := d.keepUntrustedAsideLocked(); err != nil {
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
	d.pushYoursAsync(kept)
	return nil
}

// pushYoursAsync tells this machine's control plane that your layer changed (#2957,
// research R11, user/setPolicy): best effort, and never while yoursMu is held, since it is
// a network call. The control plane checks the revision goes up, keeps it as the part
// policy of the user settings, and pushes it on to the person's other machines within 5
// seconds (SC-005). Nothing here blocks a save: with no control plane, or one that cannot
// be reached, the layer stays local to this machine, as it always has.
func (d *Daemon) pushYoursAsync(kept keptYourPolicy) {
	ask := d.askControl.Load()
	if ask == nil {
		return
	}
	signed := wire.SignedYourPolicy{Policy: base64.StdEncoding.EncodeToString(kept.Policy), Signature: kept.Signature, Key: d.yoursPublicKeyLocked()}
	safe.Go("user/setPolicy", func() {
		ctx, cancel := context.WithTimeout(d.ctx, 15*time.Second)
		defer cancel()
		if _, err := (*ask)(ctx, wire.CallUserSetPolicy.Name, signed); err != nil {
			log.Printf("user/setPolicy: kept on this machine only: %v", err)
		}
	})
}

// applySignedYours applies a copy of your layer this machine did not sign itself: the
// control plane's push to a non-keeper machine, or the Mac window's direct link
// (policy/applyYours, research R3 paths 2 and 3). It pins the person key on first use when
// none is pinned yet, moves the pin on a rotation that checks against it, and refuses
// signature (no trusted key, or the signature does not check) or older (not a higher
// revision than the one already here). This machine's own writes (editYoursLocked,
// setYourPolicy, firstStartMoveLocked) go through saveYoursLocked directly, never here.
func (d *Daemon) applySignedYours(signed wire.SignedYourPolicy, source string) (int64, error) {
	revision, rules, err := d.takeSignedYours(signed, source)
	if rules != nil {
		// Done after yoursMu is let go: setPreferences takes settingsMu (#3161).
		d.mirrorYoursToDisplay(*rules)
	}
	return revision, err
}

// takeSignedYours is applySignedYours's check and save: the new rules when it kept them,
// else nil.
func (d *Daemon) takeSignedYours(signed wire.SignedYourPolicy, source string) (int64, *wire.PolicyRules, error) {
	raw, err := base64.StdEncoding.DecodeString(signed.Policy)
	if err != nil {
		return 0, nil, &Error{Code: wire.FailureSignature, Message: "The policy is not base64."}
	}
	var policy wire.YourPolicy
	if json.Unmarshal(raw, &policy) != nil || policy.Revision < 1 {
		return 0, nil, &Error{Code: wire.FailureSignature, Message: "Not a signed policy."}
	}
	if signed.Signature.Alg != controllink.PolicyAlg || signed.Signature.Version != policy.Revision {
		return 0, nil, &Error{Code: wire.FailureSignature, Message: "The signature does not match the policy."}
	}
	d.yoursMu.Lock()
	defer d.yoursMu.Unlock()
	d.readYoursLocked()
	if policy.Keeper == d.machineID() {
		// This machine is the keeper: its own write is the truth. A copy of it, such as an
		// echo of what this machine itself just sent, changes nothing.
		current := int64(0)
		if d.yoursNow != nil {
			current = d.yoursNow.policy.Revision
		}
		return current, nil, nil
	}
	public, err := d.resolveTrustedPersonKeyLocked(signed, source)
	if err != nil {
		return 0, nil, err
	}
	if !controllink.VerifyPolicy(public, raw, signed.Signature.Sig) {
		return 0, nil, &Error{Code: wire.FailureSignature, Message: "The signature does not check."}
	}
	current := int64(0)
	if d.yoursNow != nil {
		current = d.yoursNow.policy.Revision
	}
	if policy.Revision <= current {
		return current, nil, &Error{Code: wire.FailureOlder, Message: "This copy is not newer than the one already here."}
	}
	kept := keptYourPolicy{Policy: raw, Signature: signed.Signature, policy: policy}
	b, err := json.Marshal(kept)
	if err != nil {
		return 0, nil, err
	}
	if err := d.keepUntrustedAsideLocked(); err != nil {
		return 0, nil, err
	}
	if err := store.WriteAtomically(d.yourPolicyPath(), b, 0o600); err != nil {
		return 0, nil, err
	}
	d.yoursNow = &kept
	rules := policy.Rules
	d.yoursRulesCache.Store(&rules)
	d.yoursWas = yourPolicySeen{Revision: policy.Revision, Moved: true}
	d.saveYoursSeenLocked()
	d.policyChanged()
	return policy.Revision, &rules, nil
}

// resolveTrustedPersonKeyLocked is the public key to check signed's signature against: the
// key this machine already has pinned (moved first by a rotation that checks against it),
// or, with no pin yet, signed's own key field, pinned now from source (research R3 paths 2
// and 3: the window's direct link, or trust on first use from the control plane). Called
// with yoursMu held.
func (d *Daemon) resolveTrustedPersonKeyLocked(signed wire.SignedYourPolicy, source string) ([]byte, error) {
	root := d.Store.Loc.Root
	pinned, err := controllink.LoadPinnedPersonKey(root)
	if err != nil {
		return nil, err
	}
	if pinned != nil {
		if signed.Rotation != nil && controllink.PersonKeyRotationValid(pinned.Key, *signed.Rotation) {
			moved, err := controllink.AcceptPersonKeyRotation(root, *signed.Rotation, nowFunc())
			if err != nil {
				return nil, err
			}
			return moved.Key, nil
		}
		return pinned.Key, nil
	}
	if len(signed.Key) == 0 || controllink.KeyID(signed.Key) != signed.Signature.KeyID {
		return nil, &Error{Code: wire.FailureSignature, Message: "No person key is pinned yet, and this copy carries none to pin."}
	}
	newlyPinned, err := controllink.PinPersonKey(root, signed.Key, source, nowFunc())
	if err != nil {
		return nil, err
	}
	return newlyPinned.Key, nil
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
	state := wire.YourPolicyState{Policy: policy, Keeper: wire.PolicyKeeper{Host: policy.Keeper, Name: policy.Keeper}, PinnedKeyID: pinnedKeyID}
	// The signed copy, for the Mac window to pass to a server over its direct link
	// (policy/applyYours, research R3 path 2).
	if d.yoursNow != nil && len(d.yoursNow.Policy) > 0 {
		state.Signed = &wire.SignedYourPolicy{Policy: base64.StdEncoding.EncodeToString(d.yoursNow.Policy),
			Signature: d.yoursNow.Signature, Key: d.yoursPublicKeyLocked()}
	}
	return state
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
	d.mirrorYoursToDisplay(next.Rules)
	return next, nil
}

func (d *Daemon) registerPolicyYours() {
	On(d, wire.CallPolicyYours, func(context.Context, *Client, wire.Empty) (wire.YourPolicyState, error) {
		return d.yourPolicyState(), nil
	})
	On(d, wire.CallPolicySetYours, func(_ context.Context, c *Client, r wire.SetYourPolicyRequest) (wire.YourPolicy, error) {
		return d.setYourPolicy(c, r)
	})
	On(d, wire.CallPolicyApplyYours, func(_ context.Context, c *Client, r wire.SignedYourPolicy) (wire.PolicyApplyYoursResult, error) {
		if err := forbiddenCallerRefusal(c); err != nil {
			return wire.PolicyApplyYoursResult{}, err
		}
		revision, err := d.applySignedYours(r, controllink.PinFromWindow)
		if err != nil {
			return wire.PolicyApplyYoursResult{}, err
		}
		return wire.PolicyApplyYoursResult{Revision: revision}, nil
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
