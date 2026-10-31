package controlplane

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Approve-to-join (#994, spec 736 FR-017): a machine with no code asks to join over
// HTTPS, shows a short code, and waits. The person it names (or, when it names nobody, an
// admin) approves it on a signed-in client within 10 minutes. The machine then connects
// as h:<id> with the key it asked with, as one that used a code does.
//
//	POST /v1/join            MachineJoinAsk → MachineJoinTicket
//	GET  /v1/join/<request>  → MachineJoinDecision, waiting up to 25 s for a change
//
// Requests are kept in the store (v1/joins/<request>.json), so every copy sees them.

const (
	joinsPrefix  = "v1/joins/"
	joinLifetime = 10 * time.Minute
	// joinsOpen is how many requests may wait at once, and joinsPerSource from one address.
	joinsOpen      = 50
	joinsPerSource = 5
	// joinsPerPerson requests may name one person at once (#2150).
	joinsPerPerson = 10
	// joinKept is how long an ended request stays, so the machine hears how it ended.
	joinKept = time.Hour
)

// joinRecord is v1/joins/<request>.json (data-model.md "Join request").
type joinRecord struct {
	ID        string        `json:"id"`
	Code      string        `json:"code"`
	Name      string        `json:"name"`
	Platform  string        `json:"platform"`
	Version   string        `json:"version,omitempty"`
	PublicKey []byte        `json:"publicKey"`
	MachineID string        `json:"machineID,omitempty"`
	Person    string        `json:"person,omitempty"`
	From      string        `json:"from"`
	Created   records.Stamp `json:"created"`
	Expires   records.Stamp `json:"expires"`
	Result    string        `json:"result,omitempty"`
	By        string        `json:"by,omitempty"`
	Host      string        `json:"host,omitempty"`
}

func joinKey(id string) string { return joinsPrefix + id + ".json" }

type joins struct {
	s   *Service
	now func() time.Time
	// One ask at a time, so the limits hold at this copy.
	mu sync.Mutex
}

func newJoins(s *Service) *joins { return &joins{s: s, now: time.Now} }

func newJoinID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func isJoinID(s string) bool {
	if len(s) != 32 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil && strings.ToLower(s) == s
}

// all is every request kept; ended ones older than joinKept are deleted on the way.
func (j *joins) all(ctx context.Context) ([]joinRecord, error) {
	listed, err := j.s.cfg.Store.List(ctx, joinsPrefix)
	if err != nil {
		return nil, err
	}
	now := j.now()
	out := []joinRecord{}
	for _, entry := range listed {
		r, _, err := j.read(ctx, strings.TrimSuffix(strings.TrimPrefix(entry.Key, joinsPrefix), ".json"))
		if err != nil || r == nil {
			continue
		}
		if now.Sub(r.Expires.Time) > joinKept {
			j.s.cfg.Store.Delete(ctx, entry.Key)
			continue
		}
		out = append(out, *r)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Created.Before(out[b].Created.Time) })
	return out, nil
}

func (j *joins) read(ctx context.Context, id string) (*joinRecord, string, error) {
	if !isJoinID(id) {
		return nil, "", nil
	}
	object, err := j.s.cfg.Store.Get(ctx, joinKey(id))
	if err != nil || object == nil {
		return nil, "", err
	}
	var r joinRecord
	if json.Unmarshal(object.Data, &r) != nil || r.ID != id {
		return nil, "", nil
	}
	return &r, object.ETag, nil
}

// open says a request still waits.
func (j *joins) open(r joinRecord) bool { return r.Result == "" && j.now().Before(r.Expires.Time) }

// person is whom a machine names: a person's id, or the one name of a person.
func (j *joins) person(named string) string {
	named = strings.TrimSpace(named)
	if named == "" {
		return ""
	}
	found := ""
	for _, p := range j.s.records.People() {
		if p.Kind == records.KindBot {
			continue
		}
		if p.ID == strings.ToLower(named) {
			return p.ID
		}
		if strings.EqualFold(p.Name, named) {
			if found != "" {
				return ""
			}
			found = p.ID
		}
	}
	return found
}

// ask is POST /v1/join.
func (j *joins) ask(ctx context.Context, a wire.MachineJoinAsk, from string) (*wire.MachineJoinTicket, error) {
	name := strings.TrimSpace(a.Name)
	if name == "" || len([]rune(name)) > 80 || len(a.Platform) > 80 || len(deref(a.Version)) > 80 {
		return nil, fail(invalidParams, "Say the machine's name and platform.")
	}
	if _, err := controllink.SharedSecret(controllink.NewPrivateKey(), a.PublicKey); err != nil {
		return nil, fail(invalidParams, "That is not a P-256 public key.")
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	all, err := j.all(ctx)
	if err != nil {
		return nil, err
	}
	// By address (an IPv6 /64 as one) and by person named, so neither a few addresses nor
	// one name holds every place (#2150).
	person := j.person(deref(a.Person))
	waiting, forThem, counts, oldest := 0, 0, map[string]int{}, map[string]joinRecord{}
	for _, r := range all {
		if j.open(r) {
			waiting++
			key := keyOf(r.From)
			if counts[key] == 0 {
				oldest[key] = r
			}
			counts[key]++
			if person != "" && r.Person == person {
				forThem++
			}
		}
	}
	busy := fail(notPermitted, "Too many machines are waiting to join. Try again in a few minutes.")
	if counts[keyOf(from)] >= joinsPerSource || forThem >= joinsPerPerson {
		j.s.refusals.note("join", keyOf(from), "refused a request to join from "+keyOf(from)+": too many are waiting")
		return nil, busy
	}
	if waiting >= joinsOpen {
		// Every place is taken: the oldest of the address that holds the most ends first.
		heavy := heaviest(counts)
		if heavy == "" {
			j.s.refusals.note("join", "", "refused a request to join from "+keyOf(from)+": every place is taken")
			return nil, busy
		}
		old := oldest[heavy]
		if err := j.end(ctx, old.ID, "expired"); err != nil {
			return nil, busy
		}
		j.tell(old, "control/joinDecided", wire.JoinDecided{Request: old.ID, Result: "expired"})
		j.s.refusals.note("join-dropped", "", "ended the oldest request to join from "+heavy+": every place was taken")
	}
	now := records.At(j.now())
	r := joinRecord{ID: newJoinID(), Code: controllink.JoinCode(a.PublicKey), Name: name, Platform: a.Platform, Version: deref(a.Version),
		PublicKey: a.PublicKey, MachineID: deref(a.MachineID), Person: person, From: from,
		Created: now, Expires: records.At(now.Add(joinLifetime))}
	data, err := records.Encode(r)
	if err != nil {
		return nil, err
	}
	if _, err := j.s.cfg.Store.Put(ctx, joinKey(r.ID), data, store.Absent); err != nil {
		return nil, err
	}
	j.tell(r, "control/joinRequested", j.row(r))
	j.s.log("machine " + name + " asks to join (request " + r.ID[:8] + ")")
	return &wire.MachineJoinTicket{Request: r.ID, Code: r.Code, Expires: dateOf(r.Expires.Time)}, nil
}

// decision is GET /v1/join/<request>.
func (j *joins) decision(ctx context.Context, id string) (*wire.MachineJoinDecision, error) {
	r, _, err := j.read(ctx, id)
	if err != nil {
		return nil, err
	}
	if r == nil {
		return nil, nil
	}
	switch {
	case r.Result == "approved":
		host := wire.MachineRef(r.Host)
		d := &wire.MachineJoinDecision{Result: "approved", Host: &host}
		if settings := j.s.records.Settings(); settings != nil {
			d.ControlKey = settings.ControlKey
			d.Name = optional(settings.Name)
		}
		return d, nil
	case r.Result != "":
		return &wire.MachineJoinDecision{Result: r.Result}, nil
	case !j.open(*r):
		return &wire.MachineJoinDecision{Result: "expired"}, nil
	}
	return &wire.MachineJoinDecision{Result: "waiting"}, nil
}

// row is a request as a client's card shows it.
func (j *joins) row(r joinRecord) wire.JoinRequest {
	row := wire.JoinRequest{Request: r.ID, Name: r.Name, Platform: r.Platform, Code: r.Code,
		Expires: dateOf(r.Expires.Time), For: r.Person}
	if name := j.s.personName(r.Person); name != "" {
		row.ForName = &name
	}
	return row
}

// mayDecide says a person may approve or deny: the person named, or an admin when it
// names nobody.
func (j *joins) mayDecide(r joinRecord, user string) bool {
	if r.Person != "" {
		return r.Person == user
	}
	return j.s.isAdmin(user)
}

// tell tells the person named, or every admin, a request's change.
func (j *joins) tell(r joinRecord, method string, params any) {
	if r.Person != "" {
		j.s.router.TellPerson(r.Person, method, params)
		return
	}
	for _, p := range j.s.records.People() {
		if p.IsAdmin() {
			j.s.router.TellPerson(p.ID, method, params)
		}
	}
	if j.s.records.Person(j.s.localOwner()) == nil {
		j.s.router.TellPerson(j.s.localOwner(), method, params)
	}
}

// list is hosts/joinRequests: the open requests the caller may decide.
func (j *joins) list(ctx context.Context, user string) ([]wire.JoinRequest, error) {
	all, err := j.all(ctx)
	if err != nil {
		return nil, fail(storeUnavailable, "The requests to join could not be read: %v", err)
	}
	out := []wire.JoinRequest{}
	for _, r := range all {
		if j.open(r) && j.mayDecide(r, user) {
			out = append(out, j.row(r))
		}
	}
	return out, nil
}

// decide is hosts/approveJoin and hosts/denyJoin. An approved machine is the named
// person's, or the approving admin's.
func (j *joins) decide(ctx context.Context, id, user string, approve bool) (*wire.JoinApproved, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	r, etag, err := j.read(ctx, id)
	if err != nil {
		return nil, err
	}
	if r == nil || !j.mayDecide(*r, user) {
		return nil, fail(invalidParams, "There is no such request to join.")
	}
	if !j.open(*r) {
		return nil, fail(notPermitted, "That request has ended. The machine can ask again.")
	}
	r.By = user
	if !approve {
		r.Result = "denied"
		if err := j.write(ctx, *r, etag); err != nil {
			return nil, err
		}
		j.tell(*r, "control/joinDecided", wire.JoinDecided{Request: r.ID, Result: r.Result})
		j.s.log("machine " + r.Name + " was not let join")
		return nil, nil
	}
	owner := r.Person
	if owner == "" {
		owner = user
	}
	host := records.NewHostID()
	r.Result, r.Host = "approved", host
	// The request first: a second approval at another copy loses here, and makes no host.
	if err := j.write(ctx, *r, etag); err != nil {
		return nil, err
	}
	record := records.MachineRecord{ID: host, Name: r.Name, PublicKey: r.PublicKey, Platform: r.Platform, Version: r.Version,
		Owner: &owner, Expires: j.s.newExpiry()}
	if r.MachineID != "" {
		mid := r.MachineID
		record.MachineID = &mid
	}
	if err := j.s.records.SaveHost(ctx, record); err != nil {
		return nil, err
	}
	j.s.announce("hostEnrolled", host, "join")
	j.s.router.Know(host)
	j.s.router.HoldToOwners()
	j.tell(*r, "control/joinDecided", wire.JoinDecided{Request: r.ID, Result: r.Result})
	j.s.log("machine " + r.Name + " joined as " + host + " by approval")
	return &wire.JoinApproved{Host: wire.MachineRef(host)}, nil
}

// end ends an open request with a result, as a decision would.
func (j *joins) end(ctx context.Context, id, result string) error {
	r, etag, err := j.read(ctx, id)
	if err != nil || r == nil {
		return fail(storeUnavailable, "The request could not be read.")
	}
	r.Result = result
	return j.write(ctx, *r, etag)
}

func (j *joins) write(ctx context.Context, r joinRecord, etag string) error {
	data, err := records.Encode(r)
	if err != nil {
		return err
	}
	if _, err := j.s.cfg.Store.Put(ctx, joinKey(r.ID), data, store.Matching(etag)); err != nil {
		if store.IsConflict(err) {
			return fail(notPermitted, "That request was decided already.")
		}
		return err
	}
	return nil
}

// dropFor denies every open request that names a removed person.
func (j *joins) dropFor(ctx context.Context, user string) {
	all, err := j.all(ctx)
	if err != nil {
		return
	}
	for _, r := range all {
		if r.Person == user && j.open(r) {
			if _, etag, err := j.read(ctx, r.ID); err == nil {
				r.Result, r.By = "denied", ""
				j.write(ctx, r, etag)
			}
		}
	}
}

// serve answers POST /v1/join and GET /v1/join/<request>.
func (j *joins) serve(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	path := strings.TrimPrefix(r.URL.Path, "/v1/join")
	answer := func(status int, v any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(v)
	}
	refuse := func(err error) {
		e := asRPC(err)
		status := http.StatusBadRequest
		if e.Code == storeUnavailable {
			status = http.StatusServiceUnavailable
		} else if e.Code == notPermitted {
			status = http.StatusTooManyRequests
		}
		answer(status, map[string]any{"error": e.Message})
	}
	switch {
	case path == "" && r.Method == http.MethodPost:
		body, err := io.ReadAll(io.LimitReader(r.Body, 16<<10))
		if err != nil {
			refuse(fail(invalidParams, "Say the machine's name, platform and key."))
			return
		}
		a, err := require[wire.MachineJoinAsk](body, "MachineJoinAsk")
		if err != nil {
			refuse(err)
			return
		}
		ticket, err := j.ask(ctx, a, j.s.sources.of(r))
		if err != nil {
			refuse(err)
			return
		}
		answer(http.StatusOK, ticket)
	case strings.HasPrefix(path, "/") && r.Method == http.MethodGet:
		id := path[1:]
		deadline := time.Now().Add(25 * time.Second)
		for {
			d, err := j.decision(ctx, id)
			if err != nil {
				refuse(fail(storeUnavailable, "The request could not be read."))
				return
			}
			if d == nil {
				answer(http.StatusNotFound, map[string]any{"error": "There is no such request to join."})
				return
			}
			if d.Result != "waiting" || time.Now().After(deadline) {
				answer(http.StatusOK, d)
				return
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
		}
	default:
		answer(http.StatusMethodNotAllowed, map[string]any{"error": "POST /v1/join, or GET /v1/join/<request>."})
	}
}
