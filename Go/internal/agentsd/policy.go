package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// The organisation's policy on this machine (#998, spec 998 slice 2a). The control plane
// sends it on channel 0 (host/policy) to a machine that says host.policy/1. The machine
// keeps the newest copy whose signature its control key checks, in <root>/policy.json,
// and applies it as a ceiling above the person's and the folder's own settings: it caps
// their effect, and never changes what they wrote (FR-011). A copy with a lower version
// is refused. The machine also keeps the highest version it applied, in
// <root>/policy-seen.json, so that a machine that had a policy and lost it (the file
// deleted or edited) starts no work until the control plane sends it one again (FR-013).
//
// This is no boundary against the machine's own user, who runs agentsd (spec 998,
// Clarifications): the signature makes an edit to the file useless, nothing more.

const (
	orgPolicyFile     = "policy.json"
	orgPolicySeenFile = "policy-seen.json"
	// orgOldKeyFor is how long a policy signed by the control key before a rotation is
	// still trusted (T4 keeps the old key 30 days).
	orgOldKeyFor = 30 * 24 * time.Hour
)

// The words the clients show under "Set by your organisation" (contracts/policy-api.md).
const (
	orgSetBy          = "Set by your organisation."
	orgStopAllWords   = "Your organisation has stopped all agent work."
	orgNoPolicyWords  = "Agents Host has no policy from your organisation. Connect to the network."
	orgUpdateWords    = "Update Agents Host to follow your organisation's policy."
	orgUnmeteredWords = "Your organisation cannot measure this runtime's use."
)

// unmeteredRuntimes report neither a cost nor tokens (docs/how-to/limit-spending.md), so
// a budget cannot hold them (FR-018). It is known before the first turn, when a start is
// decided.
var unmeteredRuntimes = map[string]bool{"cursor": true, "antigravity": true, "grok": true}

// orgModeNames are the clients' names of the ModeLooseness ranks, for the words.
var orgModeNames = map[string]string{"ask": "Ask", "default": "Default", "acceptEdits": "Accept Edits", "auto": "Auto",
	"bypassPermissions": "Bypass Permissions"}

type orgPolicyState struct {
	orgMu   sync.Mutex
	orgRead bool
	// orgKey is the control key this machine trusts; nil when it has no control plane,
	// and then no policy applies.
	orgKey []byte
	orgNow *keptOrgPolicy
	orgWas orgPolicySeen
	// orgLost is a machine that had a policy and has none it can trust now.
	orgLost bool
	// orgStopped is the kill switch's state as last applied, so a turn is stopped once.
	orgStopped bool
	// orgHeld is the line each agent's waiting turn was given, so it is said once.
	orgHeld map[wire.UUID]string
}

// keptOrgPolicy is <root>/policy.json: the document's own bytes, as they were signed.
type keptOrgPolicy struct {
	Policy    json.RawMessage      `json:"policy"`
	Signature wire.PolicySignature `json:"signature"`
	policy    wire.OrgPolicy
}

// orgPolicySeen is <root>/policy-seen.json: the highest version applied, and the control
// key before a rotation, trusted until previousUntil.
type orgPolicySeen struct {
	Version       int64      `json:"version"`
	PreviousKey   []byte     `json:"previousKey,omitempty"`
	PreviousUntil *time.Time `json:"previousUntil,omitempty"`
}

// SetControlKey is the control key of the control plane this machine joined. A machine
// with no control plane follows no policy.
func (d *Daemon) SetControlKey(key []byte) {
	d.orgMu.Lock()
	d.orgKey = append([]byte(nil), key...)
	d.orgRead = false
	d.orgMu.Unlock()
	d.tellPolicyState()
}

// ControlKeyRotated is the control plane's new key (#997): a policy signed by the old one
// is trusted for 30 days, until the control plane sends it signed again.
func (d *Daemon) ControlKeyRotated(key []byte) {
	d.orgMu.Lock()
	d.readOrgPolicyLocked()
	if len(d.orgKey) > 0 && !bytes.Equal(d.orgKey, key) {
		until := nowFunc().Add(orgOldKeyFor)
		d.orgWas.PreviousKey, d.orgWas.PreviousUntil = d.orgKey, &until
		d.saveOrgSeenLocked()
	}
	d.orgKey = append([]byte(nil), key...)
	d.orgMu.Unlock()
}

func (d *Daemon) orgPath(name string) string { return filepath.Join(d.Store.Loc.Root, name) }

// readOrgPolicyLocked reads the kept policy the first time, and checks it.
func (d *Daemon) readOrgPolicyLocked() {
	if d.orgRead {
		return
	}
	d.orgRead = true
	d.orgNow, d.orgLost = nil, false
	d.orgWas = orgPolicySeen{}
	if b, err := os.ReadFile(d.orgPath(orgPolicySeenFile)); err == nil {
		json.Unmarshal(b, &d.orgWas)
	}
	if len(d.orgKey) == 0 {
		return
	}
	b, err := os.ReadFile(d.orgPath(orgPolicyFile))
	if err != nil {
		d.orgLost = d.orgWas.Version > 0
		if d.orgLost {
			log.Printf("policy: %s is gone; no work starts until the control plane sends the policy again", orgPolicyFile)
		}
		return
	}
	var kept keptOrgPolicy
	if json.Unmarshal(b, &kept) != nil || !d.trustsLocked(&kept) {
		log.Printf("policy: %s fails the signature check; no work starts until the control plane sends the policy again", orgPolicyFile)
		d.orgLost = true
		return
	}
	if kept.policy.Version < d.orgWas.Version {
		log.Printf("policy: %s is version %d, older than the %d applied here; no work starts until the control plane sends the policy again",
			orgPolicyFile, kept.policy.Version, d.orgWas.Version)
		d.orgLost = true
		return
	}
	d.orgNow = &kept
}

// trustsLocked checks a policy's signature with the control key, or the key before a
// rotation in its 30 days, and decodes it.
func (d *Daemon) trustsLocked(k *keptOrgPolicy) bool {
	if len(k.Policy) == 0 || k.Signature.Alg != controllink.PolicyAlg {
		return false
	}
	if json.Unmarshal(k.Policy, &k.policy) != nil || k.policy.Version < 1 || k.Signature.Version != k.policy.Version {
		return false
	}
	if controllink.VerifyPolicy(d.orgKey, k.Policy, k.Signature.Sig) {
		return true
	}
	old := d.orgWas
	return len(old.PreviousKey) > 0 && old.PreviousUntil != nil && nowFunc().Before(*old.PreviousUntil) &&
		controllink.VerifyPolicy(old.PreviousKey, k.Policy, k.Signature.Sig)
}

func (d *Daemon) saveOrgSeenLocked() {
	b, _ := json.Marshal(d.orgWas)
	if err := store.WriteAtomically(d.orgPath(orgPolicySeenFile), b, 0o600); err != nil {
		log.Printf("policy: keep %s: %v", orgPolicySeenFile, err)
	}
}

// toldPolicy is host/policy: a signed policy, or none when the control plane never had one.
func (d *Daemon) toldPolicy(params json.RawMessage) {
	var line struct {
		Policy    json.RawMessage       `json:"policy"`
		Signature *wire.PolicySignature `json:"signature"`
		None      bool                  `json:"none"`
	}
	if err := json.Unmarshal(params, &line); err != nil {
		log.Printf("host/policy: %v", err)
		return
	}
	d.orgMu.Lock()
	d.readOrgPolicyLocked()
	if line.None {
		// The control plane has no policy. One this machine holds is kept: only a newer
		// signed policy changes it (a policy is never deleted, data-model.md).
		if d.orgNow != nil {
			log.Printf("host/policy: the control plane sends none; keeping version %d", d.orgNow.policy.Version)
			d.orgMu.Unlock()
			return
		}
		was := d.orgLost
		d.orgLost = false
		d.orgWas = orgPolicySeen{}
		os.Remove(d.orgPath(orgPolicySeenFile))
		os.Remove(d.orgPath(orgPolicyFile))
		d.orgMu.Unlock()
		if was {
			log.Printf("host/policy: the control plane has no policy")
			d.tellPolicyState()
		}
		return
	}
	if line.Signature == nil {
		d.orgMu.Unlock()
		log.Printf("host/policy: no signature")
		return
	}
	kept := keptOrgPolicy{Policy: line.Policy, Signature: *line.Signature}
	if !d.trustsLocked(&kept) {
		d.orgMu.Unlock()
		log.Printf("host/policy: the signature does not check; the policy is refused")
		return
	}
	held := d.orgWas.Version
	if d.orgNow != nil {
		held = max(held, d.orgNow.policy.Version)
	}
	if kept.policy.Version < held {
		d.orgMu.Unlock()
		log.Printf("host/policy: version %d is older than the %d kept here; refused", kept.policy.Version, held)
		d.tellControlPolicyApplied(held)
		return
	}
	b, _ := json.Marshal(kept)
	if err := store.WriteAtomically(d.orgPath(orgPolicyFile), b, 0o600); err != nil {
		d.orgMu.Unlock()
		log.Printf("host/policy: keep %s: %v", orgPolicyFile, err)
		return
	}
	same := d.orgNow != nil && bytes.Equal(d.orgNow.Policy, kept.Policy)
	d.orgNow, d.orgLost = &kept, false
	d.orgWas.Version = kept.policy.Version
	d.saveOrgSeenLocked()
	d.orgMu.Unlock()
	d.tellControlPolicyApplied(kept.policy.Version)
	if same {
		return
	}
	log.Printf("host/policy: applied version %d", kept.policy.Version)
	d.policyChanged()
}

func (d *Daemon) tellControlPolicyApplied(version int64) {
	if version < 1 {
		return
	}
	if tell := d.tellControl.Load(); tell != nil {
		(*tell)(wire.CallHostPolicyApplied.Name, wire.PolicyApplied{Version: version})
	}
}

// policyChanged is a new policy in force: the kill switch is acted on, the marks on each
// agent's choices drawn again, and the clients told.
func (d *Daemon) policyChanged() {
	p := d.orgPolicy()
	on := p != nil && p.StopAll != nil && p.StopAll.On
	d.orgMu.Lock()
	flipped := on != d.orgStopped
	d.orgStopped = on
	d.orgMu.Unlock()
	if on && flipped {
		d.stopAllForPolicy()
	}
	d.markEveryAgent()
	d.tellPolicyState()
	d.tellCost()
	// An org account's mark, and the default account, follow the policy's reach (#999).
	d.tellAccountProfiles()
}

// orgPolicy is the policy in force here, or nil when none applies.
func (d *Daemon) orgPolicy() *wire.OrgPolicy {
	d.orgMu.Lock()
	defer d.orgMu.Unlock()
	d.readOrgPolicyLocked()
	if d.orgNow == nil {
		return nil
	}
	p := d.orgNow.policy
	return &p
}

// missingCapabilities is what the policy requires that this machine lacks (FR-014).
func (d *Daemon) missingCapabilities(p *wire.OrgPolicy) []string {
	if p == nil {
		return nil
	}
	have := d.Capabilities()
	var missing []string
	for _, c := range p.Requires {
		if !slices.Contains(have, c) {
			missing = append(missing, c)
		}
	}
	return missing
}

// policyRefusal is a policyRefused error, with the words the clients show (FR-010).
func policyRefusal(reason, rule, words string, until *time.Time) error {
	r := wire.PolicyRefusal{Reason: reason, Words: words}
	if rule != "" {
		r.Rule = &rule
	}
	if until != nil {
		u := wire.DateOf(*until)
		r.Until = &u
	}
	message := words
	switch reason {
	case "policy", "budget", "stopAll":
		message = orgSetBy + " " + words
	}
	return &Error{Code: wire.FailurePolicyRefused, Message: message, Data: r}
}

// setBy is the mark on a choice the policy refuses or caps.
func setBy(rule, words string) *wire.PolicySetBy {
	return &wire.PolicySetBy{By: "organisation", Rule: rule, Words: words}
}

// workRefusal is why this machine starts no work at all now: no policy it can trust
// (FR-013), a capability it lacks (FR-014), the kill switch (FR-015), its person
// suspended (#1002, FR-018), or a control plane it must join and has not (FR-028). Nil
// otherwise.
func (d *Daemon) workRefusal() error {
	if err := d.suspensionRefusal(); err != nil {
		return err
	}
	if err := d.pinRefusal(); err != nil {
		return err
	}
	d.orgMu.Lock()
	d.readOrgPolicyLocked()
	lost := d.orgLost
	d.orgMu.Unlock()
	if lost {
		return policyRefusal("noPolicy", "", orgNoPolicyWords, nil)
	}
	p := d.orgPolicy()
	if p == nil {
		return nil
	}
	if missing := d.missingCapabilities(p); len(missing) > 0 {
		return policyRefusal("update", "requires", orgUpdateWords, nil)
	}
	if p.StopAll != nil && p.StopAll.On {
		return policyRefusal("stopAll", "stopAll", orgStopAllWords, nil)
	}
	return nil
}

// MARK: runtimes and models

// runtimeRefusal is why the policy does not allow a runtime here, or nil.
func (d *Daemon) runtimeRefusal(p *wire.OrgPolicy, runtimeID string) error {
	if p == nil {
		return nil
	}
	if p.Runtimes != nil {
		if _, ok := p.Runtimes[runtimeID]; !ok {
			return policyRefusal("policy", "runtimes", "Your organisation does not allow "+runtimeName(runtimeID)+".", nil)
		}
	}
	if err := noticeRefusal(p, runtimeID); err != nil {
		return err
	}
	if b := p.Budgets; b != nil && budgetSet(b) && unmeteredRuntimes[runtimeID] && !slices.Contains(b.AllowUnmetered, runtimeID) {
		return policyRefusal("policy", "budgets.allowUnmetered", orgUnmeteredWords, nil)
	}
	return nil
}

// antigravityTermsWords is why Antigravity is refused under notices.antigravityTerms
// refuse (#999, US6), with the terms.
const antigravityTermsWords = "Your organisation does not allow Antigravity, because of Google's terms on third-party tools: https://antigravity.google/terms"

// noticeRefusal is Antigravity refused for its terms (FR-017), or nil. Under accepted the
// clients draw no notice: they read the rule from daemon/policyState.
func noticeRefusal(p *wire.OrgPolicy, runtimeID string) error {
	if runtimeID != "antigravity" || p == nil || p.Notices == nil || p.Notices.AntigravityTerms == nil ||
		*p.Notices.AntigravityTerms != "refuse" {
		return nil
	}
	return policyRefusal("policy", "notices.antigravityTerms", antigravityTermsWords, nil)
}

func budgetSet(b *wire.PolicyBudgets) bool {
	return b.Daily != nil || b.DailyTokens != nil || b.PerAgent != nil || b.PerAgentTokens != nil
}

// nameMatches is a policy name: the same, or a prefix with * at the end. A prefix that ends
// in "-" also takes the name without it: claude-sonnet-* takes the family claude-sonnet.
func nameMatches(pattern, name string) bool {
	if prefix, ok := strings.CutSuffix(pattern, "*"); ok {
		return strings.HasPrefix(name, prefix) || (strings.HasSuffix(prefix, "-") && name == strings.TrimSuffix(prefix, "-"))
	}
	return pattern == name
}

// modelChoice is one value of a runtime's model option, with its name and description.
type modelChoice struct {
	Value       string `json:"value"`
	Name        string `json:"name"`
	Description string `json:"description"`
}

// modelChoices is the model option's values, flat or in groups, or nil.
func modelChoices(options []wire.ConfigOption) []modelChoice {
	id := modelOptionID(options)
	for _, o := range options {
		if o.ID != id {
			continue
		}
		var items []struct {
			modelChoice
			Options []modelChoice `json:"options"`
		}
		if json.Unmarshal(o.Options, &items) != nil {
			return nil
		}
		var out []modelChoice
		for _, it := range items {
			if it.Value != "" {
				out = append(out, it.modelChoice)
			}
			out = append(out, it.Options...)
		}
		return out
	}
	return nil
}

// claudeAliases is the Claude adapter's aliases for a family of models (#2274).
var claudeAliases = map[string]bool{"sonnet": true, "opus": true, "haiku": true, "fable": true}

// bareModel is a model value without its context suffix: opus[1m] is opus.
func bareModel(v string) string {
	if i := strings.IndexByte(v, '['); i > 0 {
		return v[:i]
	}
	return v
}

// modelSlug is a model's name as an id: "Sonnet 5" is sonnet-5, "Opus 5.5" opus-5-5.
func modelSlug(name string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			if dash && b.Len() > 0 {
				b.WriteByte('-')
			}
			b.WriteRune(r)
			dash = false
		} else {
			dash = true
		}
	}
	return b.String()
}

// modelNames is every name a policy's model pattern can match for a value (#2274): the
// value, the value without its context suffix and, for Claude, the model id that an alias
// stands for (from the option's name, such as Sonnet 5, and its family claude-sonnet).
// Claude's default goes by its description (Opus (1M context)) to the alias it names.
// It is nil when the value is default and the options do not say what it is. choices is
// the model option's values (modelChoices), read only for Claude.
func modelNames(runtimeID, value string, choices []modelChoice) []string {
	if runtimeID == "claude" && value == "default" {
		words := ""
		for _, c := range choices {
			if c.Value == value {
				words = c.Description
			}
		}
		alias, _, _ := strings.Cut(strings.ToLower(strings.TrimSpace(words)), " ")
		for _, c := range choices {
			if c.Value != value && bareModel(c.Value) == alias {
				return append([]string{value}, modelNames(runtimeID, c.Value, choices)...)
			}
		}
		if !claudeAliases[alias] {
			return nil
		}
		return []string{value, "claude-" + alias}
	}
	names := []string{value}
	bare := bareModel(value)
	if bare != value {
		names = append(names, bare)
	}
	if runtimeID != "claude" {
		return names
	}
	if claudeAliases[bare] {
		names = append(names, "claude-"+bare)
	}
	for _, c := range choices {
		if c.Value != value {
			continue
		}
		if slug := modelSlug(c.Name); slug != "" && claudeAliases[strings.SplitN(slug, "-", 2)[0]] {
			names = append(names, "claude-"+slug)
		}
	}
	return names
}

// modelRefusal is why the policy does not allow a model on a runtime, or nil. A model is
// matched by its value and the names it stands for (modelNames), with the runtime's
// options; "" is the runtime's own choice, which the turn checks once it is known.
func (d *Daemon) modelRefusal(p *wire.OrgPolicy, runtimeID, model string, options []wire.ConfigOption) error {
	if !hasModelRule(p, runtimeID) {
		return nil
	}
	return d.modelRefusalIn(p, runtimeID, model, runtimeModelChoices(runtimeID, options))
}

// hasModelRule is whether the policy limits the models of a runtime.
func hasModelRule(p *wire.OrgPolicy, runtimeID string) bool {
	if p == nil || p.Runtimes == nil {
		return false
	}
	rule, ok := p.Runtimes[runtimeID]
	return ok && rule.Models != nil
}

// runtimeModelChoices is modelChoices for Claude, the one runtime whose names come from
// them, and nil for the rest, which so never decode the list (#2426).
func runtimeModelChoices(runtimeID string, options []wire.ConfigOption) []modelChoice {
	if runtimeID != "claude" {
		return nil
	}
	return modelChoices(options)
}

// modelRefusalIn is modelRefusal with the model option's values already decoded, so a
// list of V models is decoded once, not V times (#2426).
func (d *Daemon) modelRefusalIn(p *wire.OrgPolicy, runtimeID, model string, choices []modelChoice) error {
	if !hasModelRule(p, runtimeID) || model == "" {
		return nil
	}
	rule := p.Runtimes[runtimeID]
	names := modelNames(runtimeID, model, choices)
	if names == nil {
		return nil
	}
	if slices.ContainsFunc(rule.Models, func(m string) bool {
		return slices.ContainsFunc(names, func(n string) bool { return nameMatches(m, n) })
	}) {
		return nil
	}
	return policyRefusal("policy", "runtimes."+runtimeID+".models",
		"Your organisation does not allow the model "+model+" on "+runtimeName(runtimeID)+".", nil)
}

// MARK: modes

// modeCeiling is the policy's loosest mode and its rank, when it sets one.
func modeCeiling(p *wire.OrgPolicy) (string, int, bool) {
	if p == nil || p.ModeCeiling == nil {
		return "", 0, false
	}
	r, ok := modeRanks[*p.ModeCeiling]
	if !ok {
		r = 0
	}
	return *p.ModeCeiling, r, true
}

// orgModeRank is a mode's rank; one this machine does not know counts as the loosest.
func orgModeRank(mode string) int {
	if r, ok := modeRank(mode); ok {
		return r
	}
	return 4
}

func modeWords(ceiling string) string {
	name := orgModeNames[ceiling]
	if name == "" {
		name = ceiling
	}
	return "Your organisation allows modes up to " + name + "."
}

// modeRefusal is why the policy does not allow a mode, or nil.
func modeRefusal(p *wire.OrgPolicy, mode string) error {
	ceiling, rank, ok := modeCeiling(p)
	if !ok || mode == "" || orgModeRank(mode) <= rank {
		return nil
	}
	return policyRefusal("policy", "modeCeiling", modeWords(ceiling), nil)
}

// approveAllID is the id of an option that approves every tool, path and web request
// without asking (Copilot's), when the runtime does not give it the permissions category.
const approveAllID = "allow_all"

// approveAllOption is the runtime's option that approves every request without asking:
// a select of the permissions category, or one of the known id. Nil when it has none.
func approveAllOption(options []wire.ConfigOption) *wire.ConfigOption {
	for _, o := range options {
		if o.Type == "select" && o.Category != nil && *o.Category == "permissions" {
			return &o
		}
	}
	for _, o := range options {
		if o.ID == approveAllID {
			return &o
		}
	}
	return nil
}

// approveAllOptionID is that option's id, or the known one before the runtime says its options.
func approveAllOptionID(options []wire.ConfigOption) string {
	if o := approveAllOption(options); o != nil {
		return o.ID
	}
	return approveAllID
}

// approvesAll is whether a value of that option is looser than a ceiling of this rank:
// a mode name by its rank, off and its like never, any other value (on) as bypass.
func approvesAll(v string, rank int) bool {
	if r, ok := modeRank(v); ok {
		return r > rank
	}
	switch strings.ToLower(v) {
	case "", "off", "false", "no", "0", "disabled", "never":
		return false
	}
	return rank < 4
}

// approveAllRefusal is why the policy does not allow this value of that option, or nil.
func approveAllRefusal(p *wire.OrgPolicy, value string) error {
	ceiling, rank, ok := modeCeiling(p)
	if !ok || !approvesAll(value, rank) {
		return nil
	}
	return policyRefusal("policy", "modeCeiling", modeWords(ceiling), nil)
}

// approveAllOff is the option's value within a ceiling of this rank: "off" when it lists none.
func approveAllOff(o *wire.ConfigOption, rank int) string {
	if o != nil {
		for _, v := range selectValues(o.Options) {
			if !approvesAll(v, rank) {
				return v
			}
		}
	}
	return "off"
}

// optionValue is one choice of a select option: its value, and its group's when grouped.
type optionValue struct {
	Value string `json:"value"`
}

// selectValues is a select option's values, flat or in groups.
func selectValues(raw wire.JSONValue) []string {
	var items []json.RawMessage
	if json.Unmarshal(raw, &items) != nil {
		return nil
	}
	var out []string
	for _, it := range items {
		var v struct {
			Value   *string           `json:"value"`
			Options []json.RawMessage `json:"options"`
		}
		if json.Unmarshal(it, &v) != nil {
			continue
		}
		if v.Value != nil {
			out = append(out, *v.Value)
		}
		for _, o := range v.Options {
			var ov optionValue
			if json.Unmarshal(o, &ov) == nil && ov.Value != "" {
				out = append(out, ov.Value)
			}
		}
	}
	return out
}

// cappedMode is the loosest mode the runtime offers within the ceiling, for an agent
// whose mode is looser: "" when it offers none.
func cappedMode(options []wire.ConfigOption, rank int) (string, string) {
	o := modeOption(options)
	if o == nil {
		return "", ""
	}
	best, bestRank := "", -1
	for _, v := range selectValues(o.Options) {
		if r, ok := modeRank(v); ok && r <= rank && r > bestRank {
			best, bestRank = v, r
		}
	}
	return o.ID, best
}

// agentMode is the mode an agent runs in: its chosen value, or its runtime's current one.
func agentMode(a *wire.Agent) (string, string) {
	o := modeOption(a.AdvertisedOptions)
	id := "mode"
	if o != nil {
		id = o.ID
	}
	if v := stringValue(a.StartOptions.Values[id]); v != "" {
		return id, v
	}
	if o != nil {
		return id, stringValue(o.CurrentValue)
	}
	return id, ""
}

// modelOptionID is the agent's model option's id.
func modelOptionID(options []wire.ConfigOption) string {
	for _, o := range options {
		if o.Type == "select" && o.Category != nil && *o.Category == "model" {
			return o.ID
		}
	}
	return "model"
}

// agentModel is the model an agent runs on: its chosen value, or its runtime's current one.
func agentModel(a *wire.Agent) string {
	id := modelOptionID(a.AdvertisedOptions)
	if v := stringValue(a.StartOptions.Values[id]); v != "" {
		return v
	}
	for _, o := range a.AdvertisedOptions {
		if o.ID == id {
			return stringValue(o.CurrentValue)
		}
	}
	return ""
}

// MARK: sandbox

func sandboxRequired(p *wire.OrgPolicy) bool {
	return p != nil && p.Sandbox != nil && *p.Sandbox == "required"
}

const sandboxRequiredWords = "Your organisation requires the command sandbox."

// requiredSandbox is the choice a required sandbox gives an agent: on, where the app can
// set it. ok is false where it cannot.
func requiredSandbox(runtimeID string) (wire.SandboxChoice, bool) {
	if slices.Contains(sandboxChoices(runtimeID), wire.SandboxChoiceOn) {
		return wire.SandboxChoiceOn, true
	}
	if r, ok := sandboxCatalog[runtimeID]; ok && r.codexMode {
		return wire.SandboxChoiceOn, true
	}
	return wire.SandboxChoiceRuntime, false
}

// MARK: marketplaces

// marketplaceAllowed is whether the policy allows a marketplace: named by its id, or by
// its address alone, so that an admin names a marketplace once for every person and
// folder that lists it. An id of "" is a marketplace not named, which an allowlist refuses.
func (d *Daemon) marketplaceAllowed(id, url string) bool {
	p := d.orgPolicy()
	if p == nil || p.Marketplaces == nil {
		return true
	}
	if id == "" && url == "" {
		return false
	}
	if url == "" {
		if _, rest, ok := strings.Cut(id, ":"); ok {
			url = rest
		}
	}
	return slices.ContainsFunc(p.Marketplaces.Allowed, func(a string) bool {
		return a == id || url != "" && strings.TrimRight(a, "/") == strings.TrimRight(url, "/")
	})
}

func marketplaceRefusalWords() string { return "Your organisation does not allow this marketplace." }

// customServerRefusal is why an MCP server added by hand is refused, or nil.
func (d *Daemon) customServerRefusal() error {
	p := d.orgPolicy()
	if p == nil || p.Marketplaces == nil || p.Marketplaces.CustomServers != "refuse" {
		return nil
	}
	return policyRefusal("policy", "marketplaces.customServers", "Your organisation does not allow MCP servers added by hand.", nil)
}

// MARK: helpers

// helperCaps caps a folder's helper limits by the policy's, and marks them when it does.
func (d *Daemon) helperCaps(running, notArchived int64) (int64, int64, *wire.PolicySetBy) {
	p := d.orgPolicy()
	if p == nil || p.Helpers == nil {
		return running, notArchived, nil
	}
	var mark *wire.PolicySetBy
	if h := p.Helpers.MostRunning; h != nil && *h < running {
		running = *h
		mark = setBy("helpers.mostRunning", helperWords(p.Helpers))
	}
	if h := p.Helpers.MostNotArchived; h != nil && *h < notArchived {
		notArchived = *h
		mark = setBy("helpers.mostNotArchived", helperWords(p.Helpers))
	}
	return running, notArchived, mark
}

func helperWords(h *wire.PolicyHelpers) string {
	var parts []string
	if h.MostRunning != nil {
		parts = append(parts, fmt.Sprintf("%d running", *h.MostRunning))
	}
	if h.MostNotArchived != nil {
		parts = append(parts, fmt.Sprintf("%d not archived", *h.MostNotArchived))
	}
	return "Your organisation allows at most " + strings.Join(parts, " and ") + " helper sessions in a folder."
}

// markHelperLimits marks a folder whose helper limits the policy caps.
func (d *Daemon) markHelperLimits(s *wire.FolderSummary) {
	s.HelperLimitsSetBy = nil
	running, notArchived := int64(defaultHelpersRunning), int64(defaultHelpersNotArchived)
	if l := s.Folder.HelperLimits; l != nil {
		if l.Running != nil {
			running = *l.Running
		}
		if l.NotArchived != nil {
			notArchived = *l.NotArchived
		}
	}
	_, _, s.HelperLimitsSetBy = d.helperCaps(running, notArchived)
}

// helperLimitsRefusal is why the folder's own helper limits may not be set this high.
func (d *Daemon) helperLimitsRefusal(l wire.HelperLimits) error {
	p := d.orgPolicy()
	if p == nil || p.Helpers == nil {
		return nil
	}
	if h := p.Helpers.MostRunning; h != nil && l.Running != nil && *l.Running > *h {
		return policyRefusal("policy", "helpers.mostRunning", helperWords(p.Helpers), nil)
	}
	if h := p.Helpers.MostNotArchived; h != nil && l.NotArchived != nil && *l.NotArchived > *h {
		return policyRefusal("policy", "helpers.mostNotArchived", helperWords(p.Helpers), nil)
	}
	return nil
}

// MARK: environment

const passThroughWords = "Your organisation does not allow this variable to be passed to runtimes."

// passThroughAllowed is whether the policy lets a person's own pass-through name through.
func passThroughAllowed(p *wire.OrgPolicy, name string) bool {
	if p == nil || p.Environment == nil {
		return true
	}
	return slices.ContainsFunc(p.Environment.PassThrough, func(allowed string) bool {
		// A person's prefix is allowed when the policy allows the same prefix or a wider one.
		if prefix, ok := strings.CutSuffix(name, "*"); ok {
			wide, isPrefix := strings.CutSuffix(allowed, "*")
			return isPrefix && strings.HasPrefix(prefix, wide)
		}
		return nameMatches(allowed, name)
	})
}

// MARK: budgets

// orgBudgets is the policy's budgets for this machine's person today (UTC), with their
// raise, as CostLimits in US dollars; nil when it sets none.
func (d *Daemon) orgBudgets(p *wire.OrgPolicy) *wire.CostLimits {
	if p == nil || p.Budgets == nil || !budgetSet(p.Budgets) {
		return nil
	}
	b := p.Budgets
	l := wire.CostLimits{PerAgentTokens: b.PerAgentTokens, DailyTokens: b.DailyTokens}
	daily, perAgent := b.Daily, b.PerAgent
	if u := d.user(); u != nil {
		today := nowFunc().UTC().Format(time.DateOnly)
		for _, r := range b.Raises {
			if r.User == u.User && r.Day == today {
				if r.Daily != nil {
					daily = r.Daily
				}
				if r.DailyTokens != nil {
					l.DailyTokens = r.DailyTokens
				}
			}
		}
	}
	if daily != nil {
		l.Daily = &wire.Cost{Amount: *daily, Currency: "USD"}
	}
	if perAgent != nil {
		l.PerAgent = &wire.Cost{Amount: *perAgent, Currency: "USD"}
	}
	return &l
}

// budgetWords says the organisation's budgets, for the mark on cost/state.
func budgetWords(l wire.CostLimits) string {
	var parts []string
	if l.Daily != nil {
		parts = append(parts, costWords(l.Daily.Amount, "USD")+" a day")
	}
	if l.DailyTokens != nil {
		parts = append(parts, fmt.Sprintf("%d tokens a day", *l.DailyTokens))
	}
	if l.PerAgent != nil {
		parts = append(parts, costWords(l.PerAgent.Amount, "USD")+" an agent")
	}
	if l.PerAgentTokens != nil {
		parts = append(parts, fmt.Sprintf("%d tokens an agent", *l.PerAgentTokens))
	}
	return "Your organisation allows you " + strings.Join(parts, ", ") + "."
}

// endOfUTCDay is when a day's budget starts again.
func endOfUTCDay(t time.Time) time.Time {
	y, m, dd := t.UTC().Date()
	return time.Date(y, m, dd+1, 0, 0, 0, 0, time.UTC)
}

// personCapped is the control plane saying this machine's person is at a budget, across
// their machines (FR-017), until when.
func (d *Daemon) personCapped(at time.Time) (time.Time, bool) {
	u := d.user()
	if u == nil || u.Kind == kindBot || u.CapReachedUntil == nil {
		return time.Time{}, false
	}
	until := u.CapReachedUntil.Time()
	return until, at.Before(until)
}

// dayBudgetRefusal is why no new turn starts today for the organisation's budget, or nil.
func (d *Daemon) dayBudgetRefusal() error {
	p := d.orgPolicy()
	if p == nil || p.Budgets == nil {
		return nil
	}
	if until, capped := d.personCapped(nowFunc()); capped {
		return policyRefusal("budget", "budgets", "You have used today's budget, set by your organisation, on your machines. It starts again at 00:00 UTC.", &until)
	}
	b := d.orgBudgets(p)
	if b == nil {
		return nil
	}
	st := d.costState()
	until := endOfUTCDay(nowFunc())
	if b.Daily != nil && st.Today["USD"] >= b.Daily.Amount {
		return policyRefusal("budget", "budgets.daily", "You have used today's "+costWords(b.Daily.Amount, "USD")+
			" budget, set by your organisation. It starts again at 00:00 UTC.", &until)
	}
	if b.DailyTokens != nil && st.TokensToday >= *b.DailyTokens {
		return policyRefusal("budget", "budgets.dailyTokens", fmt.Sprintf("You have used today's budget of %d tokens, set by your organisation. "+
			"It starts again at 00:00 UTC.", *b.DailyTokens), &until)
	}
	return nil
}

// agentBudgetRefusal is why this agent takes no new turn for the organisation's budget for
// each agent, or nil.
func (d *Daemon) agentBudgetRefusal(a *wire.Agent) error {
	b := d.orgBudgets(d.orgPolicy())
	if b == nil {
		return nil
	}
	if b.PerAgent != nil && a.CostToDate["USD"] >= b.PerAgent.Amount {
		return policyRefusal("budget", "budgets.perAgent", "This agent has used the "+costWords(b.PerAgent.Amount, "USD")+
			" your organisation allows each agent.", nil)
	}
	if b.PerAgentTokens != nil && a.TokensToDate != nil && *a.TokensToDate >= *b.PerAgentTokens {
		return policyRefusal("budget", "budgets.perAgentTokens", fmt.Sprintf("This agent has used the %d tokens your organisation allows each agent.",
			*b.PerAgentTokens), nil)
	}
	return nil
}

// MARK: starts and turns

// policyStart applies the policy to a start (FR-009): what it refuses, it refuses; a
// helper's or a workflow's mode looser than the ceiling falls to the ceiling, and note
// says so in the new agent's chat. A person's own looser choice is refused.
func (d *Daemon) policyStart(r *wire.StartRequest, by startedBy, client *wire.ClientPermissionMode) (note string, _ *wire.ClientPermissionMode, err error) {
	note, err = d.policyStartNote(r, by)
	if err != nil {
		return "", nil, err
	}
	// Yes to all, the agent's own answer to permission requests, is under the ceiling too:
	// a person who asked for it is refused; a helper, a workflow, or Auto's Approve for me
	// cell starts asking.
	if client != nil && *client == wire.ClientPermissionModeAlwaysApprove {
		if ceiling, _, capped := d.alwaysApproveCeiling(); capped {
			asked := r.Levels != nil && r.Levels.PermissionRequests != nil && *r.Levels.PermissionRequests == wire.ClientPermissionModeAlwaysApprove
			if asked && by.owner == wire.SessionLabelOwnerPerson && by.agent == nil {
				return "", nil, d.alwaysApproveRefusal()
			}
			client = requestCards
			note = strings.TrimSpace(note + " It asked to answer Yes to all requests. " + orgSetBy + " " + modeWords(ceiling) + " It asks.")
		}
	}
	return note, client, nil
}

// policyStartNote is policyStart for everything but the answer to permission requests.
func (d *Daemon) policyStartNote(r *wire.StartRequest, by startedBy) (note string, err error) {
	if err := d.workRefusal(); err != nil {
		return "", err
	}
	p := d.orgPolicy()
	if p == nil {
		return "", nil
	}
	if err := d.runtimeRefusal(p, r.RuntimeID); err != nil {
		return "", err
	}
	if err := d.modelRefusal(p, r.RuntimeID, stringValue(r.StartOptions.Values["model"]), d.runtimeOffers(r.RuntimeID)); err != nil {
		return "", err
	}
	if err := d.dayBudgetRefusal(); err != nil {
		return "", err
	}
	if b := d.orgBudgets(p); b != nil && (b.PerAgent != nil && b.PerAgent.Amount <= 0 || b.PerAgentTokens != nil && *b.PerAgentTokens <= 0) {
		return "", policyRefusal("budget", "budgets.perAgent", "Your organisation allows each agent nothing, so no agent can start.", nil)
	}
	mode := stringValue(r.StartOptions.Values["mode"])
	if err := modeRefusal(p, mode); err != nil {
		if by.owner == wire.SessionLabelOwnerPerson && by.agent == nil {
			return "", err
		}
		// A helper or a workflow: its mode goes down to the ceiling, which the runtime's
		// first turn sets from the options it offers (policyTurn).
		values := make(map[string]wire.JSONValue, len(r.StartOptions.Values))
		for k, v := range r.StartOptions.Values {
			if k != "mode" {
				values[k] = v
			}
		}
		r.StartOptions.Values = values
		ceiling, _, _ := modeCeiling(p)
		note = "It asked for the mode " + mode + ". " + orgSetBy + " " + modeWords(ceiling) + " It runs within that."
	}
	if v := stringValue(r.StartOptions.Values[approveAllID]); approveAllRefusal(p, v) != nil {
		if by.owner == wire.SessionLabelOwnerPerson && by.agent == nil {
			return "", approveAllRefusal(p, v)
		}
		// A helper or a workflow: it starts asking, as the ceiling allows.
		values := make(map[string]wire.JSONValue, len(r.StartOptions.Values))
		for k, v := range r.StartOptions.Values {
			if k != approveAllID {
				values[k] = v
			}
		}
		r.StartOptions.Values = values
		ceiling, _, _ := modeCeiling(p)
		note = strings.TrimSpace(note + " It asked to approve all requests. " + orgSetBy + " " + modeWords(ceiling) + " It asks.")
	}
	if sandboxRequired(p) {
		if r.Sandbox != nil && *r.Sandbox == wire.SandboxChoiceOff {
			return "", policyRefusal("policy", "sandbox", sandboxRequiredWords, nil)
		}
		if _, ok := requiredSandbox(r.RuntimeID); !ok {
			return "", policyRefusal("policy", "sandbox", sandboxRequiredWords+" "+runtimeName(r.RuntimeID)+" has no command sandbox that the app can turn on.", nil)
		}
		if r.RuntimeID == "codex" && mode == codexFullAccess {
			return "", policyRefusal("policy", "sandbox", sandboxRequiredWords, nil)
		}
	}
	return note, nil
}

// policyTurn is the policy at the start of each turn (FR-012, FR-013, FR-015): no turn
// while the machine starts no work, or on a runtime or model now refused, or at a budget;
// a mode looser than the ceiling goes down to it first. It is the line for the chat when
// the turn waits, "" when it goes.
func (d *Daemon) policyTurn(l *live, a *wire.Agent) string {
	if err := d.workRefusal(); err != nil {
		return policyWords(err)
	}
	p := d.orgPolicy()
	if p == nil {
		return ""
	}
	if err := d.runtimeRefusal(p, a.RuntimeID); err != nil {
		return policyWords(err)
	}
	if err := d.sessionReachRefusal(a); err != nil {
		return policyWords(err)
	}
	if err := d.modelRefusal(p, a.RuntimeID, agentModel(a), a.AdvertisedOptions); err != nil {
		return policyWords(err)
	}
	if err := d.dayBudgetRefusal(); err != nil {
		return policyWords(err)
	}
	if err := d.agentBudgetRefusal(a); err != nil {
		return policyWords(err)
	}
	if sandboxRequired(p) {
		if _, ok := requiredSandbox(a.RuntimeID); !ok {
			return policyWords(policyRefusal("policy", "sandbox", sandboxRequiredWords, nil))
		}
	}
	d.capAgentMode(l, a, p)
	d.capApproveAll(l, a, p)
	return ""
}

// capAgentMode lowers an agent's mode to the ceiling, with a line in its chat, before
// its turn. The person's own setting elsewhere (modes.json) is not changed.
func (d *Daemon) capAgentMode(l *live, a *wire.Agent, p *wire.OrgPolicy) {
	ceiling, rank, ok := modeCeiling(p)
	if !ok {
		return
	}
	id, mode := agentMode(a)
	if mode == "" || orgModeRank(mode) <= rank {
		return
	}
	optionID, lower := cappedMode(a.AdvertisedOptions, rank)
	if optionID == "" {
		optionID = id
	}
	if lower == "" {
		// The runtime has not said its modes yet: the ceiling's own name, which each
		// runtime with a mode option of the shared names takes.
		lower = ceiling
	}
	v, _ := json.Marshal(lower)
	l.mu.Lock()
	s := l.session
	l.mu.Unlock()
	if s != nil {
		ctx, cancel := context.WithTimeout(d.ctx, 30*time.Second)
		err := s.SetConfig(ctx, optionID, lower)
		cancel()
		if err != nil {
			log.Printf("agent %s: policy: set %s=%s: %v", a.ID, optionID, lower, err)
		}
	}
	d.change(a.ID, func(a *wire.Agent) { keepMode(a, optionID, v) })
	d.record(a.ID, runtimeNote("The mode is now "+lower+", not "+mode+". "+orgSetBy+" "+modeWords(ceiling)))
}

// capApproveAll turns off an agent's approval of every request, with a line in its chat,
// before its turn, when the ceiling is below bypass: that option is a mode by another name.
func (d *Daemon) capApproveAll(l *live, a *wire.Agent, p *wire.OrgPolicy) {
	ceiling, rank, ok := modeCeiling(p)
	if !ok {
		return
	}
	o := approveAllOption(a.AdvertisedOptions)
	id := approveAllOptionID(a.AdvertisedOptions)
	value := stringValue(a.StartOptions.Values[id])
	if value == "" && o != nil {
		value = stringValue(o.CurrentValue)
	}
	if !approvesAll(value, rank) {
		return
	}
	off := approveAllOff(o, rank)
	v, _ := json.Marshal(off)
	l.mu.Lock()
	s := l.session
	l.mu.Unlock()
	if s != nil {
		ctx, cancel := context.WithTimeout(d.ctx, 30*time.Second)
		err := s.SetConfig(ctx, id, off)
		cancel()
		if err != nil {
			log.Printf("agent %s: policy: set %s=%s: %v", a.ID, id, off, err)
		}
	}
	d.change(a.ID, func(a *wire.Agent) { keepMode(a, id, v) })
	d.record(a.ID, runtimeNote("It no longer approves every request without asking. "+orgSetBy+" "+modeWords(ceiling)))
}

// optionRefusal is why agents/setOption may not set this value (FR-009): a mode above the
// ceiling (approving every request among them), a model not allowed, or Codex's full
// access while the sandbox is required.
func (d *Daemon) optionRefusal(a *wire.Agent, optionID, value string) error {
	p := d.orgPolicy()
	if p == nil || value == "" {
		return nil
	}
	modeID := "mode"
	if o := modeOption(a.AdvertisedOptions); o != nil {
		modeID = o.ID
	}
	switch optionID {
	case modeID:
		if err := modeRefusal(p, value); err != nil {
			return err
		}
		if sandboxRequired(p) && a.RuntimeID == "codex" && value == codexFullAccess {
			return policyRefusal("policy", "sandbox", sandboxRequiredWords, nil)
		}
	case modelOptionID(a.AdvertisedOptions):
		return d.modelRefusal(p, a.RuntimeID, value, a.AdvertisedOptions)
	case approveAllOptionID(a.AdvertisedOptions):
		return approveAllRefusal(p, value)
	}
	return nil
}

// promptRefusal is why a new prompt (or a branch, which takes one) is refused now: the
// machine starts no work, or the agent's runtime is not allowed (FR-015, FR-012).
func (d *Daemon) promptRefusal(a *wire.Agent) error {
	if err := d.workRefusal(); err != nil {
		return err
	}
	if err := d.runtimeRefusal(d.orgPolicy(), a.RuntimeID); err != nil {
		return err
	}
	return d.sessionReachRefusal(a)
}

// sessionReachRefusal is why a session's account may no longer reach the model, the
// policy's reach having changed since it started (#999, US3): its next turn is refused,
// and Continue in New moves it.
func (d *Daemon) sessionReachRefusal(a *wire.Agent) error {
	account, err := d.accountFor(a)
	if e, ok := err.(*Error); ok && e.Code == wire.FailureOrgRouteRemoved {
		return err
	}
	if err != nil || d.orgPolicy() == nil {
		return nil
	}
	if err := d.accountRefusal(a.RuntimeID, account); err != nil {
		e := err.(*Error)
		e.Message += " Continue in New to move this session."
		return e
	}
	return nil
}

// policyWords is a refusal's words for the chat.
func policyWords(err error) string {
	if e, ok := err.(*Error); ok {
		return e.Message
	}
	return err.Error()
}

// holdsForPolicy is the turn's hold: what is queued waits while the policy refuses the
// turn, said once (as holdsForLimit is).
func (d *Daemon) holdsForPolicy(l *live) bool {
	a := d.Store.Agent(l.id)
	if a == nil {
		return false
	}
	note := d.policyTurn(l, a)
	d.orgMu.Lock()
	if d.orgHeld == nil {
		d.orgHeld = map[wire.UUID]string{}
	}
	was := d.orgHeld[l.id]
	if note == "" {
		delete(d.orgHeld, l.id)
	} else {
		d.orgHeld[l.id] = note
	}
	d.orgMu.Unlock()
	if note != "" && note != was {
		d.record(l.id, runtimeNote("What you sent is waiting. "+note))
	}
	return note != ""
}

// stopAllForPolicy is the kill switch turned on: every running turn stops, as Stop does.
// Agents and their queues are kept; nothing starts again by itself when it is turned off.
func (d *Daemon) stopAllForPolicy() {
	log.Printf("policy: the kill switch is on; stopping every turn")
	d.stopEveryTurn("Stopped. " + orgSetBy + " " + orgStopAllWords)
}

// stopEveryTurn stops every running turn, as Stop does, with this line in its chat: the
// kill switch, and a suspended person (#1002). Agents and their queues are kept.
func (d *Daemon) stopEveryTurn(line string) {
	d.mu.Lock()
	ls := make([]*live, 0, len(d.lives))
	for _, l := range d.lives {
		ls = append(ls, l)
	}
	d.mu.Unlock()
	for _, l := range ls {
		l.mu.Lock()
		in := l.inTurn
		l.mu.Unlock()
		if in {
			d.record(l.id, runtimeNote(line))
			l.cancel()
		}
	}
}

// MARK: marks on the lists the clients draw (FR-010)

// markOptions marks each mode, approve-all value and model a policy refuses, in the options' own JSON.
func (d *Daemon) markOptions(runtimeID string, options []wire.ConfigOption) []wire.ConfigOption {
	p := d.orgPolicy()
	if p == nil || len(options) == 0 {
		return options
	}
	mode := modeOption(options)
	modelID := modelOptionID(options)
	approveAll := approveAllOption(options)
	out := make([]wire.ConfigOption, len(options))
	for i, o := range options {
		out[i] = o
		var refuse func(v string) *wire.PolicySetBy
		switch {
		case mode != nil && o.ID == mode.ID:
			ceiling, rank, ok := modeCeiling(p)
			if !ok {
				continue
			}
			refuse = func(v string) *wire.PolicySetBy {
				if orgModeRank(v) > rank {
					return setBy("modeCeiling", modeWords(ceiling))
				}
				return nil
			}
		case o.ID == modelID:
			if !hasModelRule(p, runtimeID) {
				continue
			}
			choices := runtimeModelChoices(runtimeID, options)
			refuse = func(v string) *wire.PolicySetBy {
				if err := d.modelRefusalIn(p, runtimeID, v, choices); err != nil {
					return setBy("runtimes."+runtimeID+".models", err.(*Error).Data.(wire.PolicyRefusal).Words)
				}
				return nil
			}
		case approveAll != nil && o.ID == approveAll.ID:
			ceiling, rank, ok := modeCeiling(p)
			if !ok {
				continue
			}
			refuse = func(v string) *wire.PolicySetBy {
				if approvesAll(v, rank) {
					return setBy("modeCeiling", modeWords(ceiling))
				}
				return nil
			}
		default:
			continue
		}
		out[i].Options = markValues(o.Options, refuse)
	}
	return out
}

// markValues puts setBy on each value refuse refuses, flat or in groups; the rest as it was.
func markValues(raw wire.JSONValue, refuse func(string) *wire.PolicySetBy) wire.JSONValue {
	var items []map[string]json.RawMessage
	if json.Unmarshal(raw, &items) != nil {
		return raw
	}
	mark := func(item map[string]json.RawMessage) {
		var v string
		if json.Unmarshal(item["value"], &v) != nil {
			return
		}
		delete(item, "setBy")
		if m := refuse(v); m != nil {
			item["setBy"], _ = json.Marshal(m)
		}
	}
	for _, it := range items {
		if inner, ok := it["options"]; ok {
			var group []map[string]json.RawMessage
			if json.Unmarshal(inner, &group) == nil {
				for _, g := range group {
					mark(g)
				}
				it["options"], _ = json.Marshal(group)
			}
			continue
		}
		mark(it)
	}
	b, err := json.Marshal(items)
	if err != nil {
		return raw
	}
	return b
}

// markEveryAgent draws the marks on each agent's options again, for a new policy.
func (d *Daemon) markEveryAgent() {
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateArchived || len(a.AdvertisedOptions) == 0 {
			continue
		}
		before := a.AdvertisedOptions
		marked := d.markOptions(a.RuntimeID, before)
		if sameJSON(marked, before) {
			continue
		}
		// The marks just drawn, unless the options changed in between (#2426).
		d.change(a.ID, func(a *wire.Agent) {
			if sameJSON(a.AdvertisedOptions, before) {
				a.AdvertisedOptions = marked
				return
			}
			a.AdvertisedOptions = d.markOptions(a.RuntimeID, a.AdvertisedOptions)
		})
	}
}

// markRuntimes marks each runtime the policy does not allow here.
func (d *Daemon) markRuntimes(list []wire.RuntimeStatus) []wire.RuntimeStatus {
	p := d.orgPolicy()
	for i := range list {
		list[i].SetBy = nil
		if err := d.runtimeRefusal(p, list[i].Runtime.ID); err != nil {
			r := err.(*Error).Data.(wire.PolicyRefusal)
			list[i].SetBy = setBy(*r.Rule, r.Words)
		}
	}
	return list
}

// MARK: daemon/policyState

func (d *Daemon) policyState() wire.PolicyState {
	st := wire.PolicyState{}
	d.orgMu.Lock()
	d.readOrgPolicyLocked()
	st.NoPolicy = d.orgLost
	d.orgMu.Unlock()
	if p := d.orgPolicy(); p != nil {
		v := p.Version
		st.Version = &v
		mine := *p
		if mine.Budgets != nil {
			b := *mine.Budgets
			b.Raises = []wire.BudgetRaise{}
			if u := d.user(); u != nil {
				for _, r := range p.Budgets.Raises {
					if r.User == u.User {
						b.Raises = append(b.Raises, r)
					}
				}
			}
			mine.Budgets = &b
		}
		st.Policy = &mine
		st.StopAll = p.StopAll != nil && p.StopAll.On
		st.Update = d.missingCapabilities(p)
	}
	if err := d.workRefusal(); err != nil {
		// A suspension is no policy's refusal: its clients are cut off.
		if r, ok := err.(*Error).Data.(wire.PolicyRefusal); ok {
			st.Refusal = &r
		}
	}
	return st
}

func (d *Daemon) tellPolicyState() {
	Broadcast(d, wire.NotifyDaemonPolicyStateChanged, d.policyState())
}

func (d *Daemon) registerPolicy() {
	On(d, wire.CallDaemonPolicyState, func(context.Context, *Client, wire.Empty) (wire.PolicyState, error) {
		return d.policyState(), nil
	})
	On(d, wire.CallSettingsPassThrough, func(context.Context, *Client, wire.Empty) (wire.PassThroughState, error) {
		return d.passThroughState(), nil
	})
}
