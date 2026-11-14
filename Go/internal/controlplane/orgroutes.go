package controlplane

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/audit"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Org routes (#999, spec 999 slice 1; #3397): an organisation's way to the model, an org
// key or a gateway, that an admin keeps here. The record is plain JSON with no secret. Its
// secrets are one record beside it, of envelopes that an admin's client sealed with HPKE
// to each machine that may use the route and to each admin's client
// (specs/3397-client-sealing). The control plane keeps and sends those envelopes, and
// never opens one: it holds no key that does. Each machine that says host.org-routes/2 is
// sent the routes its person (or bot) may use, on channel 0, with its own copies; a
// machine with no copy yet gets the route as waiting, and the admins' clients are asked to
// seal for it (sealing.go). A cloud credential goes to the machine as it is, and the
// machine makes its own token (Go/internal/orgtoken).

// CapHostOrgRoutes is what a machine says when it keeps org routes as clients seal them.
// A machine that does not say it is sent nothing.
const CapHostOrgRoutes = wire.CapHostOrgRoutes2

const (
	orgRoutesPrefix = "v1/org/routes/"
	orgSecretSuffix = ".secret.json"
	// The bounds of data-model.md.
	mostOrgRoutes    = 50
	mostRouteSecrets = 10
	mostRouteSecret  = 16 << 10
	mostRouteName    = 60
	mostRouteSetting = 500
	mostRouteModels  = 200
	// mostRecipients bounds the machines and clients one value is sealed to, and
	// mostSealedRecord one route's sealed record (#3397).
	mostRecipients     = 200
	mostSealedRecord   = 4 << 20
	orgRouteRetries    = 5
	orgRoutesApplied   = "orgRoutes"
	orgDeliveryTimeout = 30 * time.Second
	// orgCheckPatience is how long orgRoutes/check waits for a machine's answer.
	orgCheckPatience = 30 * time.Second
)

var (
	orgRouteID       = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)
	routeHeaderName  = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)
	routeRegion      = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)
	routeWord        = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,100}$`)
	routeModel       = regexp.MustCompile(`^\S{1,200}$`)
	routeFingerprint = regexp.MustCompile(`^[0-9a-f]{8}$`)
)

// orgRouteKinds is the spec's table "What each runtime can use": the kinds each runtime's
// model traffic can take through the machine's relay. Grok, Copilot, Cursor and Antigravity
// have none (spec D5).
var orgRouteKinds = map[string][]wire.OrgRouteKind{
	"claude":   {wire.OrgRouteKindKey, wire.OrgRouteKindBedrock, wire.OrgRouteKindVertex, wire.OrgRouteKindAzure, wire.OrgRouteKindBaseURL},
	"codex":    {wire.OrgRouteKindKey, wire.OrgRouteKindAzure, wire.OrgRouteKindBaseURL},
	"opencode": {wire.OrgRouteKindKey, wire.OrgRouteKindBedrock, wire.OrgRouteKindVertex, wire.OrgRouteKindAzure, wire.OrgRouteKindBaseURL},
}

// orgRouteVendors is the API each runtime speaks, for a key, an Azure or a base-URL route.
var orgRouteVendors = map[string][]wire.OrgRouteVendor{
	"claude":   {wire.OrgRouteVendorAnthropic},
	"codex":    {wire.OrgRouteVendorOpenai},
	"opencode": {wire.OrgRouteVendorAnthropic, wire.OrgRouteVendorOpenai},
}

// routeSecretFields is each kind's secret fields. A cloud credential (Bedrock's access
// keys, Vertex's service account, Azure's Entra secret) is made into a token on the machine.
var routeSecretFields = map[wire.OrgRouteKind][]string{
	wire.OrgRouteKindKey:     {"apiKey"},
	wire.OrgRouteKindBaseURL: {"apiKey"},
	wire.OrgRouteKindBedrock: {"apiKey", "awsAccessKeyId", "awsSecretAccessKey", "awsRoleArn", "externalId"},
	wire.OrgRouteKindVertex:  {"serviceAccount"},
	wire.OrgRouteKindAzure:   {"apiKey", "entraClientSecret"},
}

// orgRouteBook is what this copy holds of the routes: what each machine here was last sent,
// by a digest of what went into it.
type orgRouteBook struct {
	mu   sync.Mutex
	told map[string][sha256.Size]byte
	// resending is a resend running; again is another asked for while it ran (#2424).
	resending, again bool
}

// orgSecretRecord is a route's secrets as stored: each recipient's envelopes, by field, at
// one seal version. Nothing in it opens here.
type orgSecretRecord struct {
	ID          string                                    `json:"id"`
	SealVersion int64                                     `json:"sealVersion"`
	Sealed      map[string]map[string]wire.SealedEnvelope `json:"sealed"`
}

// keptRoute is a route as the store has it.
type keptRoute struct {
	route wire.OrgRoute
	rev   string
}

func orgRouteKey(id string) string  { return orgRoutesPrefix + id + ".json" }
func orgSecretKey(id string) string { return orgRoutesPrefix + id + orgSecretSuffix }

// sameBinding says two routes send their keys to the same place: the kind, the vendor and
// the settings that the secrets' associated data binds (#3397).
func sameBinding(a, b wire.OrgRoute) bool {
	return a.Kind == b.Kind && deref(a.Vendor) == deref(b.Vendor) &&
		controllink.OrgRouteBinding(a.Settings) == controllink.OrgRouteBinding(b.Settings)
}

// MARK: The methods

// orgRoutesSelfAudited are the methods that write their own audit entry, with the fields
// that changed, and so are not written again from their params (FR-004).
var orgRoutesSelfAudited = methodSet("orgRoutes/check", "orgRoutes/remove", "orgRoutes/replaceKey", "orgRoutes/set")

func (m *Methods) orgRoutesMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	user := m.callerPerson(from)
	if method == "orgRoutes/mine" {
		routes, err := m.s.readOrgRoutes(ctx)
		if err != nil {
			return nil, err
		}
		out := wire.OrgRoutesMine{Routes: []wire.OrgRouteMine{}}
		for _, r := range routes {
			if m.s.mayUseRoute(user, r.route) {
				mine := wire.OrgRouteMine{ID: r.route.ID, Name: r.route.Name, Kind: r.route.Kind,
					Runtimes: r.route.Runtimes, DefaultFor: nonNil(r.route.DefaultFor)}
				if m.s.routeWaitsFor(ctx, r.route, func(owner string) bool { return owner == user }) > 0 {
					mine.Waiting = optional(true)
				}
				out.Routes = append(out.Routes, mine)
			}
		}
		return out, nil
	}
	if !m.s.isAdmin(user) {
		return nil, fail(notPermitted, "Only an admin can see or change the organisation's routes to the model.")
	}
	actor := m.s.actorFor(from.Client)
	switch method {
	case "orgRoutes/list":
		routes, err := m.s.readOrgRoutes(ctx)
		if err != nil {
			return nil, err
		}
		held := m.s.routesHeld()
		out := wire.OrgRouteList{Routes: []wire.OrgRouteKept{}}
		for _, r := range routes {
			route := r.route
			count := int64(held[route.ID+"|"+fmt.Sprint(deref(route.Version))])
			waiting := int64(m.s.routeWaitsFor(ctx, route, nil))
			route.Machines, route.Waiting = &count, &waiting
			out.Routes = append(out.Routes, wire.OrgRouteKept{Route: route, Rev: r.rev})
		}
		return out, nil
	case "orgRoutes/recipients":
		request, err := require[wire.OrgRouteRecipientsRequest](params, "OrgRouteRecipientsRequest")
		if err != nil {
			return nil, err
		}
		for _, group := range request.Groups {
			if m.s.records.Group(group) == nil {
				return nil, fail(invalidParams, "There is no group %q.", group)
			}
		}
		return wire.SealRecipients{Recipients: m.s.routeRecipients(request.Groups)}, nil
	case "orgRoutes/sealed":
		request, err := require[wire.OrgRouteRequest](params, "OrgRouteRequest")
		if err != nil {
			return nil, err
		}
		kept, err := m.s.readOrgRoute(ctx, request.ID)
		if err != nil {
			return nil, err
		}
		if kept == nil {
			return nil, fail(invalidParams, "There is no route %q.", request.ID)
		}
		record, _, err := m.s.readRouteSecrets(ctx, kept.route.ID)
		if err != nil {
			return nil, err
		}
		mine := record.Sealed[controllink.ClientRecipient(from.Client)]
		if record.SealVersion != deref(kept.route.SealVersion) || !hasFields(mine, kept.route.SecretFields) {
			return nil, fail(notSupported, "This app has no copy of the route's key yet. Wait for another admin's app to seal it for this one, or enter the key again.")
		}
		return routeItem(kept.route, mine, []wire.SealRecipient{}), nil
	case "orgRoutes/set":
		request, err := require[wire.OrgRouteSet](params, "OrgRouteSet")
		if err != nil {
			return nil, err
		}
		return m.s.setOrgRoute(ctx, actor, method, request.Route, request.Sealed, request.Rev, false)
	case "orgRoutes/replaceKey":
		request, err := require[wire.OrgRouteReplaceKey](params, "OrgRouteReplaceKey")
		if err != nil {
			return nil, err
		}
		return m.s.setOrgRoute(ctx, actor, method, wire.OrgRoute{ID: request.ID}, &request.Sealed, &request.Rev, true)
	case "orgRoutes/remove":
		request, err := require[wire.OrgRouteRequest](params, "OrgRouteRequest")
		if err != nil {
			return nil, err
		}
		return wire.Empty{}, m.s.removeOrgRoute(ctx, actor, method, request.ID, deref(request.Rev))
	case "orgRoutes/check":
		request, err := require[wire.OrgRouteRequest](params, "OrgRouteRequest")
		if err != nil {
			return nil, err
		}
		kept, err := m.s.readOrgRoute(ctx, request.ID)
		if err != nil {
			return nil, err
		}
		if kept == nil {
			return nil, fail(invalidParams, "There is no route %q.", request.ID)
		}
		m.s.auditRoute(actor, method, kept.route.ID, "")
		return m.s.checkOnMachine(kept.route), nil
	}
	return nil, notFound(method)
}

// auditRoute keeps an org route's change in the audit, with what changed and no value.
func (s *Service) auditRoute(actor wire.AuditActor, method, id, what string) {
	action, ok := audit.Action(method, false)
	if !ok {
		return
	}
	target := id
	if what != "" {
		target += ": " + what
	}
	s.auditTo(actor, method, action, target)
}

// checkOnMachine is orgRoutes/check (#3397): the control plane cannot open the route's
// credential, so it asks a machine here that holds the route's version, and gives its words.
func (s *Service) checkOnMachine(r wire.OrgRoute) wire.OrgRouteCheck {
	if len(r.SecretFields) == 0 && r.Kind != wire.OrgRouteKindBaseURL {
		return wire.OrgRouteCheck{Words: "The route has no key yet."}
	}
	version := deref(r.Version)
	for _, host := range s.router.HostsHeldHere() {
		h := s.records.Host(host)
		if h == nil || !s.takesOrgRoutes(host) {
			continue
		}
		if !slices.ContainsFunc(appliedOrgRoutes(*h), func(v wire.OrgRouteVersion) bool { return v.ID == r.ID && v.Version == version }) {
			continue
		}
		reply := s.router.Ask(host, wire.CallMachineOrgRouteCheck.Name, wire.OrgRouteRequest{ID: r.ID}, orgCheckPatience)
		if reply == nil || len(reply.Error) > 0 {
			continue
		}
		var check wire.OrgRouteCheck
		if json.Unmarshal(reply.Result, &check) != nil || check.Words == "" {
			continue
		}
		check.Words = fmt.Sprintf("%s, checked on %s.", strings.TrimSuffix(check.Words, "."), cmpOr(h.Name, host))
		return check
	}
	return wire.OrgRouteCheck{Words: "No machine that holds this route is online here to check it. Check again when one is."}
}

func cmpOr(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// setOrgRoute adds or changes a route, and its sealed secrets with it (FR-001 to FR-004,
// #3397). keyOnly is orgRoutes/replaceKey: only the secrets change. sealed is nil to keep
// the secrets as they are, which a change to where the key goes cannot.
func (s *Service) setOrgRoute(ctx context.Context, actor wire.AuditActor, method string, next wire.OrgRoute,
	sealed *wire.OrgRouteSealed, rev *string, keyOnly bool) (wire.OrgRouteKept, error) {
	if rev == nil && next.ID == "" {
		next.ID = routeIDFrom(next.Name)
	}
	if !orgRouteID.MatchString(next.ID) {
		return wire.OrgRouteKept{}, fail(invalidParams, "A route's id is 1 to 40 of a to z, 0 to 9 and -.")
	}
	for try := 0; ; try++ {
		kept, err := s.readOrgRoute(ctx, next.ID)
		if err != nil {
			return wire.OrgRouteKept{}, err
		}
		if rev == nil && kept != nil {
			return wire.OrgRouteKept{}, fail(changedElsewhere, "There is a route %q already. Load it, then save.", next.ID)
		}
		if rev != nil && (kept == nil || *rev != kept.rev) {
			return wire.OrgRouteKept{}, fail(changedElsewhere, "Another admin changed this route. Load it again, then save.")
		}
		if kept == nil {
			if all, err := s.readOrgRoutes(ctx); err != nil {
				return wire.OrgRouteKept{}, err
			} else if len(all) >= mostOrgRoutes {
				return wire.OrgRouteKept{}, fail(invalidParams, "Keep at most %d routes.", mostOrgRoutes)
			}
		}
		route := next
		if keyOnly {
			route = kept.route
		}
		// The secrets: those kept, or those the client sealed now.
		var fields []string
		fingerprint := map[string]string{}
		sealVersion := int64(0)
		if kept != nil {
			fields, sealVersion = kept.route.SecretFields, deref(kept.route.SealVersion)
			maps.Copy(fingerprint, kept.route.Fingerprint)
		}
		var record *orgSecretRecord
		secretTag := ""
		if sealed != nil {
			if record, err = s.checkSealedRoute(route, *sealed, sealVersion); err != nil {
				return wire.OrgRouteKept{}, err
			}
			fields, sealVersion, fingerprint = sealedFields(*sealed), sealed.SealVersion, maps.Clone(sealed.Fingerprint)
			if kept != nil {
				if _, tag, err := s.readRouteSecrets(ctx, next.ID); err != nil {
					return wire.OrgRouteKept{}, err
				} else {
					secretTag = tag
				}
			}
		} else if kept != nil && len(fields) > 0 && !sameBinding(kept.route, route) {
			return wire.OrgRouteKept{}, fail(invalidParams, "A change to the kind, the API or the settings seals the key again: save it from an admin's app that has a copy, or enter the key again.")
		}
		if err := s.boundOrgRoute(route, fields); err != nil {
			return wire.OrgRouteKept{}, err
		}
		now := time.Now().UTC()
		stamp := &wire.OrgRouteStamp{By: actor, At: wire.DateOf(now)}
		route.Version, route.Created, route.Changed, route.Machines, route.Waiting = optional(int64(1)), stamp, stamp, nil, nil
		if kept != nil {
			route.Version, route.Created = optional(deref(kept.route.Version)+1), kept.route.Created
		}
		route.SecretFields, route.SealVersion = slices.Sorted(slices.Values(fields)), nil
		if sealVersion > 0 {
			route.SealVersion = &sealVersion
		}
		route.Fingerprint = fingerprint
		route.DefaultFor, route.Groups = nonNil(route.DefaultFor), nonNil(route.Groups)
		// The secrets first, then the record (data-model.md): a record that names a secret
		// always finds one. Undone when the record's write loses.
		var undo func()
		if record != nil {
			record.ID = next.ID
			if undo, err = s.writeRouteSecrets(ctx, *record, secretTag); err != nil {
				if store.IsConflict(err) && try < orgRouteRetries && rev == nil {
					continue
				}
				if store.IsConflict(err) {
					return wire.OrgRouteKept{}, fail(changedElsewhere, "Another admin changed this route. Load it again, then save.")
				}
				return wire.OrgRouteKept{}, fail(storeUnavailable, "The route's key could not be kept: %v", err)
			}
		}
		data, err := records.Encode(route)
		if err != nil {
			return wire.OrgRouteKept{}, err
		}
		when := store.Absent
		if kept != nil {
			when = store.Matching(kept.rev)
		}
		tag, err := s.cfg.Store.Put(ctx, orgRouteKey(route.ID), data, when)
		if err != nil {
			if undo != nil {
				undo()
			}
			if store.IsConflict(err) {
				return wire.OrgRouteKept{}, fail(changedElsewhere, "Another admin changed this route. Load it again, then save.")
			}
			return wire.OrgRouteKept{}, fail(storeUnavailable, "The route could not be kept: %v", err)
		}
		var before *wire.OrgRoute
		if kept != nil {
			before = &kept.route
		}
		s.auditRoute(actor, method, route.ID, routeChanges(before, route, sealed != nil))
		s.log(fmt.Sprintf("org route %s is now version %d", route.ID, deref(route.Version)))
		s.orgRoutesChanged(route.ID, actor.User)
		return wire.OrgRouteKept{Route: route, Rev: tag}, nil
	}
}

// sealedFields is the fields a client sealed: those of its first recipient, which
// checkSealedRoute has made every recipient's.
func sealedFields(sealed wire.OrgRouteSealed) []string {
	for _, byField := range sealed.Values {
		return slices.Sorted(maps.Keys(byField))
	}
	return nil
}

// hasFields says a recipient's envelopes are those of every field.
func hasFields(mine map[string]wire.SealedEnvelope, fields []string) bool {
	if len(mine) != len(fields) || len(fields) == 0 {
		return false
	}
	for _, f := range fields {
		if _, ok := mine[f]; !ok {
			return false
		}
	}
	return true
}

// checkSealedRoute bounds what a client sealed for a route (#3397): one version more than
// kept, the same fields for every recipient, a fingerprint for each, each envelope bounded.
// A recipient that is not one now (a machine removed since the client asked) is left out.
func (s *Service) checkSealedRoute(r wire.OrgRoute, sealed wire.OrgRouteSealed, kept int64) (*orgSecretRecord, error) {
	if sealed.SealVersion != kept+1 {
		return nil, fail(changedElsewhere, "Another admin changed this route's key. Load it again, then save.")
	}
	if len(sealed.Values) == 0 {
		return nil, fail(invalidParams, "Seal the key to at least one machine or app.")
	}
	if len(sealed.Values) > mostRecipients {
		return nil, fail(invalidParams, "A key is sealed to at most %d machines and apps.", mostRecipients)
	}
	fields := sealedFields(sealed)
	if len(fields) > mostRouteSecrets {
		return nil, fail(invalidParams, "A route has at most %d secrets.", mostRouteSecrets)
	}
	allowed := map[string]bool{}
	for _, recipient := range s.routeRecipients(r.Groups) {
		allowed[recipient.ID] = true
	}
	out := &orgSecretRecord{SealVersion: sealed.SealVersion, Sealed: map[string]map[string]wire.SealedEnvelope{}}
	size := 0
	for recipient, byField := range sealed.Values {
		if !slices.Equal(slices.Sorted(maps.Keys(byField)), fields) {
			return nil, fail(invalidParams, "Every machine and app gets every one of the route's secrets.")
		}
		for _, e := range byField {
			if len(e.Encapsulated) != 65 || len(e.Ciphertext) > mostRouteSecret+16 || len(e.Ciphertext) < 17 {
				return nil, fail(invalidParams, "A secret is at most %d KiB.", mostRouteSecret>>10)
			}
			size += len(e.Encapsulated) + len(e.Ciphertext)
		}
		if allowed[recipient] {
			out.Sealed[recipient] = byField
		}
	}
	if size > mostSealedRecord/2 {
		return nil, fail(invalidParams, "The route's key, sealed to every machine, is over %d MiB.", mostSealedRecord>>21)
	}
	if len(sealed.Fingerprint) != len(fields) {
		return nil, fail(invalidParams, "Say a fingerprint for each secret.")
	}
	for _, f := range fields {
		if !routeFingerprint.MatchString(sealed.Fingerprint[f]) {
			return nil, fail(invalidParams, "A fingerprint is the first 8 hex digits of the value's SHA-256.")
		}
	}
	return out, nil
}

// writeRouteSecrets keeps a route's sealed record, conditional on the tag read ("" for
// none), and says how to put back what was there.
func (s *Service) writeRouteSecrets(ctx context.Context, record orgSecretRecord, tag string) (func(), error) {
	key := orgSecretKey(record.ID)
	var previous []byte
	if tag != "" {
		if object, err := s.cfg.Store.Get(ctx, key); err == nil && object != nil && object.ETag == tag {
			previous = object.Data
		}
	}
	data, err := records.Encode(record)
	if err != nil {
		return nil, err
	}
	when := store.Absent
	if tag != "" {
		when = store.Matching(tag)
	}
	written, err := s.cfg.Store.Put(ctx, key, data, when)
	if err != nil {
		return nil, err
	}
	return func() {
		if previous == nil {
			s.cfg.Store.Delete(context.Background(), key)
			return
		}
		if _, err := s.cfg.Store.Put(context.Background(), key, previous, store.Matching(written)); err != nil {
			s.log("org route " + record.ID + ": its secrets could not be put back: " + err.Error())
		}
	}, nil
}

// removeOrgRoute deletes a route and its secrets (FR-004), conditional on the rev read:
// a tombstone takes the record first, so a save that read it before loses.
func (s *Service) removeOrgRoute(ctx context.Context, actor wire.AuditActor, method, id, rev string) error {
	kept, err := s.readOrgRoute(ctx, id)
	if err != nil {
		return err
	}
	if kept == nil {
		return fail(invalidParams, "There is no route %q.", id)
	}
	if rev != kept.rev {
		return fail(changedElsewhere, "Another admin changed this route. Load it again, then remove it.")
	}
	if _, err := s.cfg.Store.Put(ctx, orgRouteKey(id), []byte(`{"removed":true}`), store.Matching(rev)); err != nil {
		if store.IsConflict(err) {
			return fail(changedElsewhere, "Another admin changed this route. Load it again, then remove it.")
		}
		return fail(storeUnavailable, "The route could not be removed: %v", err)
	}
	if err := s.cfg.Store.Delete(ctx, orgSecretKey(id)); err != nil {
		s.log("org route " + id + ": its secrets could not be deleted: " + err.Error())
	}
	if err := s.cfg.Store.Delete(ctx, orgRouteKey(id)); err != nil {
		s.log("org route " + id + ": its record could not be deleted: " + err.Error())
	}
	s.auditRoute(actor, method, id, kept.route.Name)
	s.log("org route " + id + " removed")
	s.orgRoutesChanged(id, actor.User)
	return nil
}

// routeChanges is what a save changed, in words for the audit: the fields, and "key
// replaced" for a secret, never its value.
func routeChanges(before *wire.OrgRoute, after wire.OrgRoute, sealed bool) string {
	if before == nil {
		return "added " + after.Name
	}
	var changed []string
	same := func(a, b any) bool { x, _ := json.Marshal(a); y, _ := json.Marshal(b); return bytes.Equal(x, y) }
	for _, f := range []struct {
		name string
		a, b any
	}{
		{"name", before.Name, after.Name}, {"kind", before.Kind, after.Kind}, {"vendor", before.Vendor, after.Vendor},
		{"runtimes", before.Runtimes, after.Runtimes}, {"settings", before.Settings, after.Settings},
		{"models", before.Models, after.Models}, {"groups", nonNil(before.Groups), nonNil(after.Groups)},
		{"defaultFor", nonNil(before.DefaultFor), nonNil(after.DefaultFor)},
	} {
		if !same(f.a, f.b) {
			changed = append(changed, f.name)
		}
	}
	if sealed && !slices.Equal(slices.Sorted(maps.Values(before.Fingerprint)), slices.Sorted(maps.Values(after.Fingerprint))) {
		changed = append(changed, "key replaced")
	}
	if len(changed) == 0 {
		return "saved as it was"
	}
	return strings.Join(changed, ", ")
}

// routeIDFrom is an id made from a name: Acme Bedrock is acme-bedrock.
func routeIDFrom(name string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
			dash = false
		} else if !dash && b.Len() > 0 {
			b.WriteByte('-')
			dash = true
		}
	}
	id := strings.TrimRight(b.String(), "-")
	if len(id) > 40 {
		id = strings.TrimRight(id[:40], "-")
	}
	return id
}

func nonNil(list []string) []string {
	if list == nil {
		return []string{}
	}
	return list
}

// MARK: The bounds

// boundOrgRoute refuses a route out of bounds or a kind a runtime cannot use, in words for
// the admin (FR-002, the spec's table). fields is the secret fields it has: their values
// are sealed, so the client checks what is in them.
func (s *Service) boundOrgRoute(r wire.OrgRoute, fields []string) error {
	name := strings.TrimSpace(r.Name)
	if name == "" || utf8.RuneCountInString(name) > mostRouteName || name != r.Name {
		return fail(invalidParams, "A route's name is 1 to %d characters, with no space at either end.", mostRouteName)
	}
	kindFields, ok := routeSecretFields[r.Kind]
	if !ok {
		return fail(invalidParams, "A route is a key, bedrock, vertex, azure or baseURL.")
	}
	if len(r.Runtimes) == 0 {
		return fail(invalidParams, "Say which runtimes the route is for.")
	}
	needsVendor := r.Kind == wire.OrgRouteKindKey || r.Kind == wire.OrgRouteKindAzure || r.Kind == wire.OrgRouteKindBaseURL
	if needsVendor && r.Vendor == nil {
		return fail(invalidParams, "Say whose API the route speaks: anthropic, openai or xai.")
	}
	seen := map[string]bool{}
	for _, runtime := range r.Runtimes {
		if seen[runtime] {
			return fail(invalidParams, "%s is named twice.", runtime)
		}
		seen[runtime] = true
		if !slices.Contains(orgRouteKinds[runtime], r.Kind) {
			return fail(invalidParams, "%s cannot reach the model by %s: its model traffic cannot go through the machine's relay.", runtime, r.Kind)
		}
		if needsVendor && !slices.Contains(orgRouteVendors[runtime], *r.Vendor) {
			return fail(invalidParams, "%s does not speak the %s API.", runtime, *r.Vendor)
		}
	}
	for _, runtime := range r.DefaultFor {
		if !seen[runtime] {
			return fail(invalidParams, "The route can be the default only for its own runtimes, not %s.", runtime)
		}
	}
	for _, group := range r.Groups {
		if s.records.Group(group) == nil {
			return fail(invalidParams, "There is no group %q.", group)
		}
	}
	if len(r.Models) > mostRouteModels {
		return fail(invalidParams, "Map at most %d models.", mostRouteModels)
	}
	for from, to := range r.Models {
		if !routeModel.MatchString(from) || !routeModel.MatchString(to) {
			return fail(invalidParams, "%q to %q is not a model id.", from, to)
		}
	}
	if err := checkRouteSettings(r); err != nil {
		return err
	}
	if len(fields) > mostRouteSecrets {
		return fail(invalidParams, "A route has at most %d secrets.", mostRouteSecrets)
	}
	for _, field := range fields {
		if !slices.Contains(kindFields, field) {
			return fail(invalidParams, "A %s route has no secret %q. It takes %s.", r.Kind, field, strings.Join(kindFields, ", "))
		}
	}
	has := func(f string) bool { return slices.Contains(fields, f) }
	settings := deref(r.Settings)
	switch r.Kind {
	case wire.OrgRouteKindKey:
		if !has("apiKey") {
			return fail(invalidParams, "Say the key.")
		}
	case wire.OrgRouteKindBedrock:
		keys := has("awsAccessKeyId") || has("awsSecretAccessKey")
		if has("apiKey") == keys || keys && !(has("awsAccessKeyId") && has("awsSecretAccessKey")) {
			return fail(invalidParams, "Say a Bedrock API key, or an AWS access key id and its secret, not both.")
		}
		if !keys && (has("awsRoleArn") || has("externalId")) {
			return fail(invalidParams, "A role is assumed with an AWS access key: say one.")
		}
		if settings.Region == nil {
			return fail(invalidParams, "Say the AWS region.")
		}
	case wire.OrgRouteKindVertex:
		if !has("serviceAccount") {
			return fail(invalidParams, "Say the service account's key, as Google gives it in JSON.")
		}
		if settings.Project == nil || settings.Location == nil {
			return fail(invalidParams, "Say the Google Cloud project and location.")
		}
	case wire.OrgRouteKindAzure:
		if has("apiKey") == has("entraClientSecret") {
			return fail(invalidParams, "Say an Azure key, or an Entra app's secret, not both.")
		}
		if has("entraClientSecret") && (settings.Tenant == nil || settings.ClientID == nil) {
			return fail(invalidParams, "Say the Entra app's tenant and client id.")
		}
		if settings.Resource == nil && settings.Address == nil {
			return fail(invalidParams, "Say the Azure resource, or its address.")
		}
	case wire.OrgRouteKindBaseURL:
		if settings.Address == nil {
			return fail(invalidParams, "Say the gateway's address.")
		}
	}
	return nil
}

// checkRouteSettings bounds the settings that are not secret. None holds a line break:
// each is one line of the binding the secrets are sealed with (#3397).
func checkRouteSettings(r wire.OrgRoute) error {
	if r.Settings == nil {
		return nil
	}
	st := *r.Settings
	for _, v := range []*string{st.Address, st.ApiVersion, st.ClientID, st.Header, st.Location, st.Project, st.Region, st.Resource, st.Tenant} {
		if v != nil && (len(*v) > mostRouteSetting || *v == "" || strings.ContainsAny(*v, "\r\n")) {
			return fail(invalidParams, "A setting is one line of 1 to %d characters.", mostRouteSetting)
		}
	}
	if st.Address != nil {
		u, err := url.Parse(*st.Address)
		if err != nil || u.Host == "" || u.User != nil || !(u.Scheme == "https" || u.Scheme == "http" && loopbackHost(u.Hostname())) {
			return fail(invalidParams, "The address is an https address, or http on this machine's loopback.")
		}
	}
	if st.Header != nil && !routeHeaderName.MatchString(*st.Header) {
		return fail(invalidParams, "%q is not a header name.", *st.Header)
	}
	if st.Region != nil && !routeRegion.MatchString(*st.Region) {
		return fail(invalidParams, "%q is not a region.", *st.Region)
	}
	for _, v := range []*string{st.ApiVersion, st.ClientID, st.Location, st.Project, st.Resource, st.Tenant} {
		if v != nil && !routeWord.MatchString(*v) {
			return fail(invalidParams, "%q is not a name the provider gives.", *v)
		}
	}
	return nil
}

func loopbackHost(host string) bool {
	return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

// MARK: The store

// readOrgRoute is one route, or nil. A route being removed is no route.
func (s *Service) readOrgRoute(ctx context.Context, id string) (*keptRoute, error) {
	if !orgRouteID.MatchString(id) {
		return nil, nil
	}
	object, err := s.cfg.Store.Get(ctx, orgRouteKey(id))
	if err != nil {
		return nil, fail(storeUnavailable, "The route could not be read: %v", err)
	}
	if object == nil {
		return nil, nil
	}
	var route wire.OrgRoute
	if err := json.Unmarshal(object.Data, &route); err != nil || route.ID != id {
		return nil, nil
	}
	return &keptRoute{route: route, rev: object.ETag}, nil
}

// readOrgRoutes is every route, by id.
func (s *Service) readOrgRoutes(ctx context.Context) ([]keptRoute, error) {
	keys, err := s.cfg.Store.List(ctx, orgRoutesPrefix)
	if err != nil {
		return nil, fail(storeUnavailable, "The routes could not be read: %v", err)
	}
	out := []keptRoute{}
	for _, k := range keys {
		id := strings.TrimPrefix(k.Key, orgRoutesPrefix)
		if strings.HasSuffix(id, orgSecretSuffix) || !strings.HasSuffix(id, ".json") {
			continue
		}
		kept, err := s.readOrgRoute(ctx, strings.TrimSuffix(id, ".json"))
		if err != nil {
			return nil, err
		}
		if kept != nil {
			out = append(out, *kept)
		}
	}
	return out, nil
}

// readRouteSecrets is a route's sealed record, and its tag ("" for none): ciphertext only,
// which nothing here opens.
func (s *Service) readRouteSecrets(ctx context.Context, id string) (orgSecretRecord, string, error) {
	key := orgSecretKey(id)
	object, err := s.cfg.Store.Get(ctx, key)
	if err != nil {
		return orgSecretRecord{}, "", fail(storeUnavailable, "The route's secrets could not be read: %v", err)
	}
	if object == nil {
		return orgSecretRecord{ID: id}, "", nil
	}
	var record orgSecretRecord
	if err := json.Unmarshal(object.Data, &record); err != nil {
		return orgSecretRecord{}, "", fmt.Errorf("%s: not a sealed record", key)
	}
	return record, object.ETag, nil
}

// MARK: Who gets which

// mayUseRoute says a person (or bot) may use a route: it names no group, or one of theirs
// (spec D6). A removed or suspended person may use none (D13).
func (s *Service) mayUseRoute(user string, r wire.OrgRoute) bool {
	return s.mayUseGroups(user, r.Groups)
}

func (s *Service) mayUseGroups(user string, groups []string) bool {
	if p := s.records.Person(user); (p != nil && p.IsRemoved()) || s.suspended(user) {
		return false
	}
	if len(groups) == 0 {
		return true
	}
	for _, g := range groups {
		if s.inGroup(user, g) {
			return true
		}
	}
	return false
}

// takesOrgRoutes says a machine keeps org routes.
func (s *Service) takesOrgRoutes(host string) bool {
	h := s.records.Host(host)
	return h != nil && slices.Contains(hostCapabilities(*h), CapHostOrgRoutes)
}

// routeItem is a route as sealing/work and orgRoutes/sealed give it: what makes its
// associated data, the caller's copy, and who has none.
func routeItem(r wire.OrgRoute, mine map[string]wire.SealedEnvelope, missing []wire.SealRecipient) wire.SealingItem {
	kind := r.Kind
	return wire.SealingItem{Item: wire.SealingItemKindOrgRoute, ID: r.ID, Version: deref(r.SealVersion), Kind: &kind,
		Vendor: r.Vendor, Settings: r.Settings, Mine: mine, Missing: missing}
}

// routeWaitsFor counts the machines that may use a route and have no copy of its
// secrets: those whose owner passes of, or all when of is nil.
func (s *Service) routeWaitsFor(ctx context.Context, r wire.OrgRoute, of func(owner string) bool) int {
	if len(r.SecretFields) == 0 {
		return 0
	}
	record, _, err := s.readRouteSecrets(ctx, r.ID)
	if err != nil {
		return 0
	}
	n := 0
	for _, recipient := range s.routeRecipients(r.Groups) {
		host, ok := strings.CutPrefix(recipient.ID, "m:")
		if !ok || of != nil && !of(s.ownerOf(host)) {
			continue
		}
		if record.SealVersion != deref(r.SealVersion) || !hasFields(record.Sealed[recipient.ID], r.SecretFields) {
			n++
		}
	}
	return n
}

// orgDelivery is machine/orgRoutes for one machine: each route its person may use, with this
// machine's own copies, or waiting when it has none; and a digest of what went in.
func (s *Service) orgDelivery(ctx context.Context, host string) (wire.OrgRouteDelivery, [sha256.Size]byte, []string, error) {
	out := wire.OrgRouteDelivery{Routes: []wire.DeliveredRoute{}, At: wire.DateOf(time.Now())}
	h := s.records.Host(host)
	if h == nil {
		return out, [sha256.Size]byte{}, nil, errors.New("no such machine")
	}
	user := s.ownerOf(host)
	routes, err := s.readOrgRoutes(ctx)
	if err != nil {
		return out, [sha256.Size]byte{}, nil, err
	}
	digest := sha256.New()
	fmt.Fprintf(digest, "%s|%s|%x\n", host, user, h.PublicKey)
	var waits []string
	recipient := controllink.MachineRecipient(host)
	for _, kept := range routes {
		r := kept.route
		if !s.mayUseRoute(user, r) {
			continue
		}
		d := wire.DeliveredRoute{ID: r.ID, Name: r.Name, Kind: r.Kind, Vendor: r.Vendor, Runtimes: r.Runtimes, Settings: r.Settings,
			Models: r.Models, DefaultFor: nonNil(r.DefaultFor), SecretFields: nonNil(r.SecretFields), Version: deref(r.Version),
			SealVersion: deref(r.SealVersion), Sealed: map[string]wire.SealedEnvelope{}}
		if len(r.SecretFields) > 0 {
			record, _, err := s.readRouteSecrets(ctx, r.ID)
			if err != nil {
				s.log(fmt.Sprintf("org route %s was not sent to %s: %v", r.ID, host, err))
				continue
			}
			mine := record.Sealed[recipient]
			if record.SealVersion == d.SealVersion && hasFields(mine, r.SecretFields) {
				d.Sealed = maps.Clone(mine)
			} else {
				d.Waiting, waits = optional(true), append(waits, routeAsk(r, recipient))
			}
		}
		fmt.Fprintf(digest, "%s|%d|%d|%t\n", r.ID, d.Version, d.SealVersion, d.Waiting != nil)
		out.Routes = append(out.Routes, d)
	}
	var sum [sha256.Size]byte
	copy(sum[:], digest.Sum(nil))
	return out, sum, waits, nil
}

// sendOrgRoutes sends a machine its routes on its channel 0 (FR-005). always sends even
// what it was sent last (a hello, or the machine asked again). A route the machine waits
// for asks the admins' clients to seal it (#3397).
func (s *Service) sendOrgRoutes(host string, always bool) {
	if !s.takesOrgRoutes(host) {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), orgDeliveryTimeout)
	defer cancel()
	user := s.ownerOf(host)
	delivery, sum, waits, err := s.orgDelivery(ctx, host)
	if err != nil {
		s.log("org routes for " + host + " could not be made: " + err.Error())
		return
	}
	s.orgRoutes.mu.Lock()
	if s.orgRoutes.told == nil {
		s.orgRoutes.told = map[string][sha256.Size]byte{}
	}
	same := s.orgRoutes.told[host] == sum
	s.orgRoutes.mu.Unlock()
	if same && !always {
		return
	}
	// The machine may have changed hands while its routes were read.
	if s.records.Host(host) == nil || s.ownerOf(host) != user || !s.router.Tell(host, wire.NotifyMachineOrgRoutes.Name, delivery) {
		s.orgRoutes.mu.Lock()
		delete(s.orgRoutes.told, host)
		s.orgRoutes.mu.Unlock()
		return
	}
	s.orgRoutes.mu.Lock()
	s.orgRoutes.told[host] = sum
	s.orgRoutes.mu.Unlock()
	s.log(fmt.Sprintf("org routes sent to %s (%d)", host, len(delivery.Routes)))
	s.wantSealingByAdmins(waits...)
}

// orgRoutesChanged is a route changed here: the other copies are told, then this copy's.
func (s *Service) orgRoutesChanged(id, by string) {
	s.announce("orgRoutesChanged", id, by)
	s.orgRoutesChangedHere()
}

// orgRoutesChangedHere is a change's effect on this copy: each machine here whose delivery
// differs is sent it, and every client reads its accounts again.
func (s *Service) orgRoutesChangedHere() {
	s.resendOrgRoutes()
	s.router.BroadcastControl(wire.NotifyControlOrgRoutesChanged.Name, wire.Empty{})
}

// resendOrgRoutes sends each machine here its routes, where they differ: a route, a group
// or a person changed.
// One resend runs at a time, over at most orgResendWorkers machines at once; those asked
// for while it runs are one more run after it (#2424).
func (s *Service) resendOrgRoutes() {
	s.orgRoutes.mu.Lock()
	if s.orgRoutes.resending {
		s.orgRoutes.again = true
		s.orgRoutes.mu.Unlock()
		return
	}
	s.orgRoutes.resending = true
	s.orgRoutes.mu.Unlock()
	go func() {
		for {
			s.resendTo(s.router.HostsHeldHere())
			s.orgRoutes.mu.Lock()
			if !s.orgRoutes.again {
				s.orgRoutes.resending = false
				s.orgRoutes.mu.Unlock()
				return
			}
			s.orgRoutes.again = false
			s.orgRoutes.mu.Unlock()
		}
	}()
}

// resendTo sends each of hosts, every machine here, its routes.
func (s *Service) resendTo(hosts []string) { s.sendOrgRoutesTo(hosts) }

// orgResendWorkers is how many machines a resend sends to at once.
const orgResendWorkers = 8

// sendOrgRoutesTo sends each of hosts its routes where they differ, orgResendWorkers at once.
func (s *Service) sendOrgRoutesTo(hosts []string) {
	next := make(chan string)
	var wg sync.WaitGroup
	for range min(orgResendWorkers, len(hosts)) {
		wg.Go(func() {
			for host := range next {
				s.sendOrgRoutes(host, false)
			}
		})
	}
	for _, host := range hosts {
		next <- host
	}
	close(next)
	wg.Wait()
}

// orgRoutesAgain is machine/orgRoutesAgain: a sealed route did not open on the machine.
func (s *Service) orgRoutesAgain(host string) {
	s.orgRoutes.mu.Lock()
	delete(s.orgRoutes.told, host)
	s.orgRoutes.mu.Unlock()
	go s.sendOrgRoutes(host, true)
}

// orgRoutesApplied is machine/orgRoutesApplied: what the machine keeps, noted on its record
// for orgRoutes/list and for when it is removed.
func (s *Service) orgRoutesApplied(ctx context.Context, host string, applied wire.OrgRoutesApplied) error {
	if len(applied.Routes) > mostOrgRoutes {
		return fail(invalidParams, "At most %d routes.", mostOrgRoutes)
	}
	list := slices.Clone(applied.Routes)
	for _, r := range list {
		if !orgRouteID.MatchString(r.ID) || r.Version < 1 {
			return fail(invalidParams, "%q is not a route's id and version.", r.ID)
		}
	}
	slices.SortFunc(list, func(a, b wire.OrgRouteVersion) int { return strings.Compare(a.ID, b.ID) })
	value, _ := json.Marshal(list)
	changed := false
	if err := s.records.ChangeHost(ctx, host, func(r *records.MachineRecord) bool {
		if bytes.Equal(r.Extra[orgRoutesApplied], value) {
			return false
		}
		extra := make(records.Extra, len(r.Extra)+1)
		maps.Copy(extra, r.Extra)
		extra[orgRoutesApplied] = value
		r.Extra = extra
		changed = true
		return true
	}); err != nil {
		return err
	}
	if changed {
		s.announce("orgRoutesApplied", host, host)
	}
	return nil
}

// appliedOrgRoutes is what a machine said it keeps.
func appliedOrgRoutes(h records.MachineRecord) []wire.OrgRouteVersion {
	var list []wire.OrgRouteVersion
	json.Unmarshal(h.Extra[orgRoutesApplied], &list)
	return list
}

// routesHeld counts the machines that keep each route's version, by "<id>|<version>".
func (s *Service) routesHeld() map[string]int {
	out := map[string]int{}
	for _, h := range s.records.Hosts() {
		for _, r := range appliedOrgRoutes(h) {
			out[r.ID+"|"+fmt.Sprint(r.Version)]++
		}
	}
	return out
}

// orgRoutesLeft is a machine removed with routes on it: it is sent nothing more, and its
// person and every admin hear which routes it held (spec: "A machine removed").
func (s *Service) orgRoutesLeft(host, user, name string, held []wire.OrgRouteVersion) {
	s.orgRoutes.mu.Lock()
	delete(s.orgRoutes.told, host)
	s.orgRoutes.mu.Unlock()
	if len(held) == 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), orgDeliveryTimeout)
	defer cancel()
	names := []string{}
	for _, r := range held {
		label := r.ID
		if kept, err := s.readOrgRoute(ctx, r.ID); err == nil && kept != nil {
			label = kept.route.Name
		}
		names = append(names, label)
	}
	left := wire.OrgRoutesLeft{Host: wire.MachineRef(host), Name: name, User: user, Routes: names}
	s.log(fmt.Sprintf("%s was removed with %d org routes on it", host, len(names)))
	told := map[string]bool{}
	for _, p := range s.records.People() {
		if p.IsAdmin() && !p.IsRemoved() || p.ID == user {
			s.router.TellPerson(p.ID, wire.NotifyControlOrgRoutesLeft.Name, left)
			told[p.ID] = true
		}
	}
	for _, who := range []string{user, s.localOwner()} {
		if !told[who] && (who == user || s.isAdmin(who)) {
			s.router.TellPerson(who, wire.NotifyControlOrgRoutesLeft.Name, left)
			told[who] = true
		}
	}
}
