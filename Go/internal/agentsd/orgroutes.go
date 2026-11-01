package agentsd

import (
	"crypto/ecdh"
	"crypto/hpke"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// Org routes on the machine (#999, spec 999 slice 2). The control plane sends each machine
// the routes its person (or bot) may use, on channel 0 (host/orgRoutes), each secret sealed
// with HPKE to this machine's own key. The machine keeps each route as it came, still
// sealed, in <root>/org-routes/<id>.json (0600), and opens a secret in memory only when the
// model relay (modelrelay.go) sends a request with it. A route is one more account of each
// runtime it serves (#840), id org:<route id>, made here from the delivery and never kept
// in runtime-accounts.json: the person cannot remove it. The runtime never gets the secret
// (spec D4): it is started with the relay's address and a stand-in (orglaunch.go).
//
// An offline machine keeps the routes it has (D11) until a newer delivery takes one away.
// A file that does not open with this machine's key (copied from another machine, or
// edited) is deleted, and the control plane is asked for the delivery again.

const (
	orgRoutesFolder = "org-routes"
	// orgRoutePurpose is HPKE's info, as the control plane seals with (FR-005).
	orgRoutePurpose = controllink.OrgRoutePurpose
	// orgAccountPrefix starts an org account's id: org:<route id>.
	orgAccountPrefix = "org:"
	// mostOrgRoutes bounds a delivery, as the control plane bounds routes.
	mostOrgRoutes = 50
)

var orgRouteIDPattern = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)

// orgRouteRows is each runtime's kinds that the machine builds (spec "What each runtime
// can use", research R2, measured 2026-10-22 against each CLI with a fake provider).
// OpenCode's Bedrock and Vertex need its cloud SDK's own signing, so they are left out
// (docs/reference/runtimes.md).
var orgRouteRows = map[string][]wire.OrgRouteKind{
	"claude":   {wire.OrgRouteKindKey, wire.OrgRouteKindBedrock, wire.OrgRouteKindVertex, wire.OrgRouteKindAzure, wire.OrgRouteKindBaseURL},
	"codex":    {wire.OrgRouteKindKey, wire.OrgRouteKindAzure, wire.OrgRouteKindBaseURL},
	"opencode": {wire.OrgRouteKindKey, wire.OrgRouteKindAzure, wire.OrgRouteKindBaseURL},
}

// orgRouteVendors is the API each runtime speaks, for a key, an Azure or a base-URL route.
var orgRouteVendors = map[string][]wire.OrgRouteVendor{
	"claude":   {wire.OrgRouteVendorAnthropic},
	"codex":    {wire.OrgRouteVendorOpenai},
	"opencode": {wire.OrgRouteVendorAnthropic, wire.OrgRouteVendorOpenai},
}

type orgRouteState struct {
	orgRouteMu     sync.Mutex
	orgRoutesRead  bool
	orgRoutesHeld  map[string]heldRoute
	orgIdentity    *machineIdentity
	orgDefaultRead bool
	orgDefaults    map[string]string
	// relay is the model relay, started with the first launch on an org account.
	relayMu    sync.Mutex
	modelRelay *modelRelay
}

// heldRoute is a route this machine keeps, and when it got it.
type heldRoute struct {
	route wire.DeliveredRoute
	at    wire.Date
}

// machineIdentity is what a route is sealed to: this machine's id and private key.
type machineIdentity struct {
	host    string
	private []byte
}

func (d *Daemon) orgRoutesDir() string { return filepath.Join(d.Store.Loc.Root, orgRoutesFolder) }

// identity is this machine's id and key, from the root it joined with; nil before it joined.
func (d *Daemon) identityLocked() *machineIdentity {
	if d.orgIdentity != nil {
		return d.orgIdentity
	}
	root := d.Store.Loc.Root
	member, err := controllink.LoadMembership(root)
	if err != nil || member.Host == "" {
		return nil
	}
	private, ok, err := d.HostKey.Load()
	if err != nil || !ok {
		return nil
	}
	d.orgIdentity = &machineIdentity{host: member.Host, private: private}
	return d.orgIdentity
}

// openSealed opens one of a route's secrets with this machine's key. The associated data
// is the machine and the whole route as kept (controllink.OrgRouteAD): a file whose
// address, header or kind differs from what was delivered does not open.
func openSealed(id *machineIdentity, r wire.DeliveredRoute, sealed wire.SealedEnvelope) ([]byte, error) {
	if id == nil {
		return nil, errors.New("this machine has not joined a control plane")
	}
	ad, err := controllink.OrgRouteAD(r, id.host)
	if err != nil {
		return nil, err
	}
	private, err := ecdh.P256().NewPrivateKey(id.private)
	if err != nil {
		return nil, err
	}
	key, err := hpke.NewDHKEMPrivateKey(private)
	if err != nil {
		return nil, err
	}
	recipient, err := hpke.NewRecipient(sealed.Encapsulated, key, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(orgRoutePurpose))
	if err != nil {
		return nil, err
	}
	return recipient.Open(ad, sealed.Ciphertext)
}

// opens says each of a route's secrets opens here; the values are dropped at once.
func opens(id *machineIdentity, r wire.DeliveredRoute) error {
	for field, sealed := range r.Sealed {
		v, err := openSealed(id, r, sealed)
		clear(v)
		if err != nil {
			return fmt.Errorf("%s: %w", field, err)
		}
	}
	return nil
}

// routeWellFormed bounds a delivered route before anything is kept of it.
func routeWellFormed(r wire.DeliveredRoute) error {
	if !orgRouteIDPattern.MatchString(r.ID) {
		return fmt.Errorf("%q is not a route's id", r.ID)
	}
	if r.Version < 1 || r.Name == "" || len([]rune(r.Name)) > 60 {
		return fmt.Errorf("route %s has no version or name", r.ID)
	}
	if len(r.Sealed) > 10 {
		return fmt.Errorf("route %s has too many secrets", r.ID)
	}
	return nil
}

// orgRoutesLocked reads the kept routes the first time: a file that does not open is
// deleted, and the control plane is asked again.
func (d *Daemon) orgRoutesLocked() map[string]heldRoute {
	if d.orgRoutesRead {
		return d.orgRoutesHeld
	}
	d.orgRoutesRead = true
	d.orgRoutesHeld = map[string]heldRoute{}
	entries, err := os.ReadDir(d.orgRoutesDir())
	if err != nil {
		return d.orgRoutesHeld
	}
	id := d.identityLocked()
	again := false
	for _, e := range entries {
		name := e.Name()
		file := filepath.Join(d.orgRoutesDir(), name)
		routeID, ok := strings.CutSuffix(name, ".json")
		if !ok || e.IsDir() {
			continue
		}
		var r wire.DeliveredRoute
		b, err := os.ReadFile(file)
		if err == nil {
			err = json.Unmarshal(b, &r)
		}
		if err == nil {
			err = routeWellFormed(r)
		}
		if err == nil && r.ID != routeID {
			err = errors.New("the file's name is not its route")
		}
		if err == nil {
			err = opens(id, r)
		}
		if err != nil {
			log.Printf("org routes: %s does not open here (%v); deleted, and asked for again", name, err)
			os.Remove(file)
			again = true
			continue
		}
		at := wire.DateOf(time.Now())
		if fi, err := e.Info(); err == nil {
			at = wire.DateOf(fi.ModTime())
		}
		d.orgRoutesHeld[r.ID] = heldRoute{route: r, at: at}
	}
	if again {
		go d.askOrgRoutesAgain()
	}
	return d.orgRoutesHeld
}

// heldOrgRoute is a route this machine keeps, or false.
func (d *Daemon) heldOrgRoute(id string) (wire.DeliveredRoute, bool) {
	d.orgRouteMu.Lock()
	defer d.orgRouteMu.Unlock()
	h, ok := d.orgRoutesLocked()[id]
	return h.route, ok
}

// orgSecret opens one of a route's secrets, in memory, for one request.
func (d *Daemon) orgSecret(r wire.DeliveredRoute, field string) ([]byte, bool) {
	sealed, ok := r.Sealed[field]
	if !ok {
		return nil, false
	}
	d.orgRouteMu.Lock()
	id := d.identityLocked()
	d.orgRouteMu.Unlock()
	v, err := openSealed(id, r, sealed)
	if err != nil {
		log.Printf("org routes: %s's %s did not open: %v", r.ID, field, err)
		return nil, false
	}
	return v, true
}

func (d *Daemon) askOrgRoutesAgain() {
	if tell := d.tellControl.Load(); tell != nil {
		(*tell)(wire.NewMethodName(wire.CallHostOrgRoutesAgain.Name), wire.Empty{})
	}
}

// toldOrgRoutes is host/orgRoutes: the routes this machine may use now. Each new one that
// opens here is kept; one that does not is not, and the delivery is asked for again; one
// that is no longer in it goes, and the sessions on it stop (FR-009, FR-018).
func (d *Daemon) toldOrgRoutes(params json.RawMessage) {
	var delivery wire.OrgRouteDelivery
	if err := json.Unmarshal(params, &delivery); err != nil {
		log.Printf("host/orgRoutes: %v", err)
		return
	}
	if len(delivery.Routes) > mostOrgRoutes {
		log.Printf("host/orgRoutes: %d routes is more than %d; refused", len(delivery.Routes), mostOrgRoutes)
		return
	}
	d.orgRouteMu.Lock()
	held := d.orgRoutesLocked()
	id := d.identityLocked()
	again := false
	next := map[string]heldRoute{}
	for _, r := range delivery.Routes {
		if err := routeWellFormed(r); err != nil {
			log.Printf("host/orgRoutes: %v", err)
			continue
		}
		if err := opens(id, r); err != nil {
			log.Printf("host/orgRoutes: %s version %d does not open here (%v); asked for again", r.ID, r.Version, err)
			again = true
			if old, ok := held[r.ID]; ok {
				next[r.ID] = old
			}
			continue
		}
		if old, ok := held[r.ID]; ok && sameJSON(old.route, r) {
			next[r.ID] = old
			continue
		}
		if err := d.keepOrgRoute(r); err != nil {
			log.Printf("host/orgRoutes: keep %s: %v", r.ID, err)
			if old, ok := held[r.ID]; ok {
				next[r.ID] = old
			}
			continue
		}
		next[r.ID] = heldRoute{route: r, at: delivery.At}
	}
	var gone []heldRoute
	for routeID, h := range held {
		if _, ok := next[routeID]; !ok {
			gone = append(gone, h)
			os.Remove(filepath.Join(d.orgRoutesDir(), routeID+".json"))
		}
	}
	d.orgRoutesHeld = next
	applied := wire.OrgRoutesApplied{Routes: []wire.OrgRouteVersion{}}
	for _, h := range next {
		applied.Routes = append(applied.Routes, wire.OrgRouteVersion{ID: h.route.ID, Version: h.route.Version})
	}
	d.orgRouteMu.Unlock()
	sort.Slice(applied.Routes, func(i, j int) bool { return applied.Routes[i].ID < applied.Routes[j].ID })
	log.Printf("host/orgRoutes: %d kept, %d removed", len(next), len(gone))
	d.stopRemovedOrgSessions(gone)
	d.dropStandInsOfGoneRoutes()
	if len(gone) > 0 {
		d.sweepOrgAccountFolders()
	}
	if tell := d.tellControl.Load(); tell != nil {
		(*tell)(wire.NewMethodName(wire.CallHostOrgRoutesApplied.Name), applied)
	}
	if again {
		d.askOrgRoutesAgain()
	}
	d.tellAccountProfiles()
	d.tellAllowances()
}

// keepOrgRoute writes a route as it came, still sealed, readable by this user only.
func (d *Daemon) keepOrgRoute(r wire.DeliveredRoute) error {
	if err := os.MkdirAll(d.orgRoutesDir(), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return store.WriteAtomically(filepath.Join(d.orgRoutesDir(), r.ID+".json"), b, 0o600)
}

// stopRemovedOrgSessions stops each running session on an org account that is no longer
// here, with a line in its chat; the session is kept (FR-018, US4).
func (d *Daemon) stopRemovedOrgSessions(gone []heldRoute) {
	names := map[string]string{}
	for _, h := range gone {
		names[h.route.ID] = h.route.Name
	}
	for _, a := range d.Store.Agents() {
		route := orgRouteOf(a.AccountID)
		if route == "" || !holdsRuntime(a.State) {
			continue
		}
		if d.orgAccount(a.RuntimeID, *a.AccountID) != nil {
			continue
		}
		name := names[route]
		if name == "" {
			name = "this way to the model"
		}
		d.record(a.ID, notice("error", "Your organisation removed "+name+".",
			"Continue in New to move this session to another account."))
		if l := d.live(a.ID); l != nil {
			l.cancel()
		}
		d.dropLeases(a.ID, "holderStopped")
		d.endWait(a.ID, "stopped", false)
	}
}

// orgRouteOf is the route of an org account's id, or "".
func orgRouteOf(accountID *string) string {
	if accountID == nil {
		return ""
	}
	route, _ := strings.CutPrefix(*accountID, orgAccountPrefix)
	if route == *accountID {
		return ""
	}
	return route
}

// routeServes says whether this machine builds a route for a runtime (orgRouteRows).
func routeServes(r wire.DeliveredRoute, runtimeID string) bool {
	if !slices.Contains(r.Runtimes, runtimeID) || !slices.Contains(orgRouteRows[runtimeID], r.Kind) {
		return false
	}
	switch r.Kind {
	case wire.OrgRouteKindKey, wire.OrgRouteKindAzure, wire.OrgRouteKindBaseURL:
		return r.Vendor != nil && slices.Contains(orgRouteVendors[runtimeID], *r.Vendor)
	}
	return true
}

// orgAccountFor is a route as one runtime's account (FR-010).
func orgAccountFor(h heldRoute, runtimeID string) wire.AccountProfile {
	r := h.route
	p := wire.AccountProfile{ID: orgAccountPrefix + r.ID, RuntimeID: runtimeID, Name: r.Name, AddedAt: h.at, SignedIn: true,
		Source: new("organisation")}
	if r.Kind == wire.OrgRouteKindKey {
		p.Reach.OrgKey = &wire.AccountReachOrgKey{Route: r.ID}
	} else {
		p.Reach.Gateway = &wire.AccountReachGateway{Route: r.ID, Kind: r.Kind}
	}
	return p
}

// orgAccounts is every route here as an account of each runtime it serves, by name.
func (d *Daemon) orgAccounts() []wire.AccountProfile {
	d.orgRouteMu.Lock()
	held := d.orgRoutesLocked()
	var out []wire.AccountProfile
	for _, h := range held {
		for _, runtimeID := range h.route.Runtimes {
			if routeServes(h.route, runtimeID) {
				out = append(out, orgAccountFor(h, runtimeID))
			}
		}
	}
	d.orgRouteMu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		if out[i].RuntimeID != out[j].RuntimeID {
			return out[i].RuntimeID < out[j].RuntimeID
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// orgAccount is one runtime's org account, or nil.
func (d *Daemon) orgAccount(runtimeID, id string) *wire.AccountProfile {
	route, ok := strings.CutPrefix(id, orgAccountPrefix)
	if !ok {
		return nil
	}
	d.orgRouteMu.Lock()
	h, held := d.orgRoutesLocked()[route]
	d.orgRouteMu.Unlock()
	if !held || !routeServes(h.route, runtimeID) {
		return nil
	}
	p := orgAccountFor(h, runtimeID)
	return &p
}

// isOrgAccount says an account is an organisation's.
func isOrgAccount(p *wire.AccountProfile) bool {
	return p != nil && (p.Reach.OrgKey != nil || p.Reach.Gateway != nil)
}

// accountRoute is an org account's route id, or "".
func accountRoute(p *wire.AccountProfile) string {
	switch {
	case p == nil:
		return ""
	case p.Reach.OrgKey != nil:
		return p.Reach.OrgKey.Route
	case p.Reach.Gateway != nil:
		return p.Reach.Gateway.Route
	}
	return ""
}

// MARK: Reaches the Model By (FR-016)

const defaultAccountsFile = "default-accounts.json"

// ownSignIn is the id a person names the runtime's own sign-in by.
const ownSignIn = "default"

func (d *Daemon) defaultAccountsPath() string {
	return filepath.Join(d.SettingsDir, defaultAccountsFile)
}

func (d *Daemon) defaultsLocked() map[string]string {
	if !d.orgDefaultRead {
		d.orgDefaultRead = true
		d.orgDefaults = map[string]string{}
		if d.SettingsDir != "" {
			readStore(d.defaultAccountsPath(), &d.orgDefaults, "each runtime starts on its default account")
		}
	}
	return d.orgDefaults
}

// chosenDefault is the account the person chose for a runtime's new sessions: an id,
// ownSignIn, or "" when they chose none.
func (d *Daemon) chosenDefault(runtimeID string) string {
	d.orgRouteMu.Lock()
	defer d.orgRouteMu.Unlock()
	return d.defaultsLocked()[runtimeID]
}

// writeDefaultAccounts keeps the person's choices, on this machine. Carrying them in the
// runtimes part of the person's settings (#1760, FR-016) is the team area's.
func (d *Daemon) writeDefaultAccounts(m map[string]string) error {
	d.orgRouteMu.Lock()
	d.orgDefaultRead = true
	d.orgDefaults = cloneDefaults(m)
	d.orgRouteMu.Unlock()
	if d.SettingsDir == "" {
		return nil
	}
	if err := os.MkdirAll(d.SettingsDir, 0o755); err != nil {
		return err
	}
	return writeStore(d.defaultAccountsPath(), m)
}

func (d *Daemon) defaultAccounts() map[string]string {
	d.orgRouteMu.Lock()
	defer d.orgRouteMu.Unlock()
	return cloneDefaults(d.defaultsLocked())
}

// cloneDefaults is a copy of the person's choices, never nil.
func cloneDefaults(m map[string]string) map[string]string {
	out := make(map[string]string, len(m))
	maps.Copy(out, m)
	return out
}

// defaultAccount is the account a new session of a runtime uses when it names none: the
// person's choice, when there is one and the policy allows it; else the org route that is
// the default for the runtime; else the runtime's own sign-in (nil). Each org route that
// is defaultFor the runtime is taken in name order, so every machine takes the same.
func (d *Daemon) defaultAccount(runtimeID string) *wire.AccountProfile {
	p := d.orgPolicy()
	if chosen := d.chosenDefault(runtimeID); chosen != "" {
		var account *wire.AccountProfile
		if chosen != ownSignIn {
			account = d.accountProfile(runtimeID, chosen)
		}
		if (chosen == ownSignIn || account != nil) && reachRefusal(p, runtimeID, account, nil) == nil {
			return account
		}
	}
	for _, a := range d.orgAccounts() {
		route, ok := d.heldOrgRoute(accountRoute(&a))
		if a.RuntimeID == runtimeID && ok && slices.Contains(route.DefaultFor, runtimeID) && reachRefusal(p, runtimeID, &a, nil) == nil {
			return &a
		}
	}
	// The own sign-in, or under "the org path only" any org account there is.
	if reachRefusal(p, runtimeID, nil, nil) != nil {
		for _, a := range d.orgAccounts() {
			if a.RuntimeID == runtimeID && reachRefusal(p, runtimeID, &a, nil) == nil {
				return &a
			}
		}
	}
	return nil
}

// setDefaultAccount is runtimes/setDefaultAccount.
func (d *Daemon) setDefaultAccount(r wire.DefaultAccountRequest) error {
	rt := runtimeByID(r.RuntimeID)
	if rt == nil {
		return &Error{Code: CodeRuntimeNotFound, Message: "There is no runtime called " + r.RuntimeID + "."}
	}
	id := ownSignIn
	var account *wire.AccountProfile
	if r.AccountID != nil && *r.AccountID != "" && *r.AccountID != ownSignIn {
		id = *r.AccountID
		if account = d.accountProfile(r.RuntimeID, id); account == nil {
			return Invalid("%s has no such account. It may have been removed.", rt.Name)
		}
	}
	if err := reachRefusal(d.orgPolicy(), r.RuntimeID, account, d.reachWordsFor(r.RuntimeID)); err != nil {
		return err
	}
	m := d.defaultAccounts()
	m[r.RuntimeID] = id
	if err := d.writeDefaultAccounts(m); err != nil {
		return err
	}
	d.tellAccountProfiles()
	return nil
}

// MARK: the policy's reach (FR-015)

// accountReach is the way an account reaches the model, as the policy names it.
func accountReach(p *wire.AccountProfile) wire.PolicyReach {
	switch {
	case p != nil && p.Reach.OrgKey != nil:
		return wire.PolicyReachOrgKey
	case p != nil && p.Reach.Gateway != nil:
		return wire.PolicyReachGateway
	}
	return wire.PolicyReachSignIn
}

// reachAllows says the policy lets a runtime reach the model this way.
func reachAllows(p *wire.OrgPolicy, runtimeID string, reach wire.PolicyReach) bool {
	if p == nil || p.Runtimes == nil {
		return true
	}
	rule, ok := p.Runtimes[runtimeID]
	if !ok || rule.Reach == nil {
		return true
	}
	return slices.Contains(rule.Reach, reach)
}

// reachRefusal is why the policy does not let a session of a runtime use this account
// (nil for the own sign-in), or nil. words is the line, from reachWordsFor.
func reachRefusal(p *wire.OrgPolicy, runtimeID string, account *wire.AccountProfile, words *string) error {
	if reachAllows(p, runtimeID, accountReach(account)) {
		return nil
	}
	line := "Your organisation does not allow " + runtimeName(runtimeID) + " to reach the model this way."
	if words != nil {
		line = *words
	}
	return policyRefusal("policy", "runtimes."+runtimeID+".reach", line, nil, orgLayerRef(p))
}

// reachWordsFor is the line of a refused account: the org route the person must use, by
// name, when there is one here (contract "Errors").
func (d *Daemon) reachWordsFor(runtimeID string) *string {
	p := d.orgPolicy()
	for _, a := range d.orgAccounts() {
		if a.RuntimeID == runtimeID && reachRefusal(p, runtimeID, &a, nil) == nil {
			s := "Your organisation requires " + runtimeName(runtimeID) + " to use " + a.Name + "."
			return &s
		}
	}
	if !reachAllows(p, runtimeID, wire.PolicyReachSignIn) {
		s := "Your organisation requires " + runtimeName(runtimeID) + " to use its own way to the model."
		return &s
	}
	return nil
}

// orgRouteMissingError is the org path required and no route for it on this machine
// (US3 scenario 2, D11).
func orgRouteMissingError() error {
	return &Error{Code: wire.FailureOrgRouteMissing,
		Message: "Your organisation's way to this model has not reached this machine. Connect to the network."}
}

// accountRefusal is the policy's reach applied to a session's account: a refusal with the
// route to use, or orgRouteMissing when the org path is required and none is here.
func (d *Daemon) accountRefusal(runtimeID string, account *wire.AccountProfile) error {
	p := d.orgPolicy()
	if reachRefusal(p, runtimeID, account, nil) == nil {
		return nil
	}
	words := d.reachWordsFor(runtimeID)
	if account == nil && !slices.ContainsFunc(d.orgAccounts(), func(a wire.AccountProfile) bool {
		return a.RuntimeID == runtimeID && reachRefusal(p, runtimeID, &a, nil) == nil
	}) {
		return orgRouteMissingError()
	}
	return reachRefusal(p, runtimeID, account, words)
}

// runtimeVariables are the names a runtime's own way to the model is set by, beyond its
// passed names: what a person's pass-through or login environment could point it with
// (D9, FR-013).
var runtimeVariables = []string{"ANTHROPIC_", "CLAUDE_CODE_USE_", "CLAUDE_CODE_SKIP_", "CLAUDE_CONFIG_DIR", "CLOUD_ML_REGION",
	"AWS_", "OPENAI_", "AZURE_", "CODEX_HOME", "CODEX_CA_CERTIFICATE", "GEMINI_", "GOOGLE_", "OPENCODE_CONFIG", "XAI_",
	"VERTEX_", "NODE_EXTRA_CA_CERTS"}

// withoutRuntimeVariables takes each of runtimeVariables out of env.
func withoutRuntimeVariables(env []string) []string {
	return slices.DeleteFunc(env, func(kv string) bool {
		name, _, _ := strings.Cut(kv, "=")
		return slices.ContainsFunc(runtimeVariables, func(v string) bool {
			return name == v || strings.HasSuffix(v, "_") && strings.HasPrefix(name, v)
		})
	})
}

// markAccounts marks each account the policy refuses, and the default (FR-015, FR-016).
func (d *Daemon) markAccounts(list []wire.AccountProfile) []wire.AccountProfile {
	p := d.orgPolicy()
	defaults := map[string]string{}
	for _, a := range list {
		if _, ok := defaults[a.RuntimeID]; !ok {
			defaults[a.RuntimeID] = ""
			if def := d.defaultAccount(a.RuntimeID); def != nil {
				defaults[a.RuntimeID] = def.ID
			}
		}
	}
	for i := range list {
		list[i].SetBy, list[i].IsDefault = nil, nil
		if err := reachRefusal(p, list[i].RuntimeID, &list[i], d.reachWordsFor(list[i].RuntimeID)); err != nil {
			r := err.(*Error).Data.(wire.PolicyRefusal)
			layer := orgLayerRef(p)
			if r.Layer != nil {
				layer = *r.Layer
			}
			list[i].SetBy = setBy(layer, *r.Rule, r.Words)
		}
		if defaults[list[i].RuntimeID] == list[i].ID {
			list[i].IsDefault = new(true)
		}
	}
	return list
}
