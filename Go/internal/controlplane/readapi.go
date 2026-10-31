package controlplane

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// The read API (#2019, #1804 decision 4): a BI tool reads the organisation's reports with a
// token an admin made, GET /v1/read/reports?range=month[&group=<id>][&format=json|csv|jsonl],
// the same rows as reports/usage and reports/export. A token reads that and nothing else:
// no socket, no method, no write. It is shown once; the store keeps its SHA-256 only, as its
// key. Each token may ask readPerMinute times a minute, and works only while the admin who
// made it is an admin.

const (
	readTokensPrefix = "v1/read/tokens/"
	readTokenPrefix  = "agread_"
	readAPIPath      = "/v1/read/reports"
	mostLiveReadTokens = 10
	// mostReadTokens bounds what is kept, revoked ones too: the oldest revoked go first.
	mostReadTokens   = 50
	readTokenKept    = 10 * time.Second
	readLastUseEvery = time.Minute
	readPerMinute    = 30
	readBurst        = 10
	mostReadBuckets  = 1000
)

// readTokenRecord is v1/read/tokens/<sha256>.json.
type readTokenRecord struct {
	ID      string              `json:"id"`
	Name    string              `json:"name"`
	SHA256  string              `json:"sha256"`
	Made    wire.OrgRouteStamp  `json:"made"`
	LastUse *wire.SCIMTokenUse  `json:"lastUse,omitempty"`
	Revoked *wire.OrgRouteStamp `json:"revoked,omitempty"`
}

func (t readTokenRecord) onWire() wire.ReadToken {
	return wire.ReadToken{ID: t.ID, Name: t.Name, Made: t.Made, LastUse: t.LastUse, Revoked: t.Revoked}
}

func readTokenKey(sum string) string { return readTokensPrefix + sum + ".json" }

// readTokens is what this copy keeps of the tokens it read, and each one's rate.
type readTokens struct {
	s     *Service
	mu    sync.Mutex
	read  map[string]keptReadToken
	noted map[string]time.Time
	rates map[string]*bucket
}

type keptReadToken struct {
	t  *readTokenRecord
	at time.Time
}

// token is the live token a bearer names, read at most each readTokenKept.
func (rt *readTokens) token(ctx context.Context, bearer string, now time.Time) (*readTokenRecord, string) {
	if !strings.HasPrefix(bearer, readTokenPrefix) || len(bearer) > 100 {
		return nil, ""
	}
	sum := sha256.Sum256([]byte(bearer))
	hash := hex.EncodeToString(sum[:])
	rt.mu.Lock()
	kept, ok := rt.read[hash]
	rt.mu.Unlock()
	if !ok || now.Sub(kept.at) > readTokenKept {
		object, err := rt.s.cfg.Store.Get(ctx, readTokenKey(hash))
		if err != nil {
			return nil, ""
		}
		var t *readTokenRecord
		if object != nil {
			var r readTokenRecord
			if json.Unmarshal(object.Data, &r) == nil && r.SHA256 == hash {
				t = &r
			}
		}
		kept = keptReadToken{t, now}
		rt.mu.Lock()
		if rt.read == nil || len(rt.read) >= mostReadBuckets {
			rt.read = map[string]keptReadToken{}
		}
		rt.read[hash] = kept
		rt.mu.Unlock()
	}
	if kept.t == nil || kept.t.Revoked != nil || !rt.s.isAdmin(kept.t.Made.By.User) {
		return nil, ""
	}
	return kept.t, hash
}

// allow takes one from the token's bucket.
func (rt *readTokens) allow(hash string, now time.Time) bool {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if rt.rates == nil || len(rt.rates) >= mostReadBuckets {
		rt.rates = map[string]*bucket{}
	}
	b := rt.rates[hash]
	if b == nil {
		b = &bucket{}
		rt.rates[hash] = b
	}
	return b.take(now, 1, readPerMinute/60.0, readBurst)
}

// noteUse writes a token's last use, at most once a minute, in the background.
func (rt *readTokens) noteUse(hash, address string, now time.Time) {
	rt.mu.Lock()
	if rt.noted == nil || len(rt.noted) >= mostReadBuckets {
		rt.noted = map[string]time.Time{}
	}
	if now.Sub(rt.noted[hash]) < readLastUseEvery {
		rt.mu.Unlock()
		return
	}
	rt.noted[hash] = now
	rt.mu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		object, err := rt.s.cfg.Store.Get(ctx, readTokenKey(hash))
		if err != nil || object == nil {
			return
		}
		var t readTokenRecord
		if json.Unmarshal(object.Data, &t) != nil || t.Revoked != nil {
			return
		}
		t.LastUse = &wire.SCIMTokenUse{At: wire.DateOf(now), Address: optional(address)}
		if data, err := records.Encode(t); err == nil {
			// A revoke in between wins: its write moved the tag.
			_, _ = rt.s.cfg.Store.Put(ctx, readTokenKey(hash), data, store.Matching(object.ETag))
		}
	}()
}

// serve is GET /v1/read/reports.
func (rt *readTokens) serve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		plain(w, http.StatusMethodNotAllowed, "only GET\n")
		return
	}
	now := time.Now()
	bearer, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	t, hash := rt.token(r.Context(), strings.TrimSpace(bearer), now)
	if t == nil {
		w.Header().Set("WWW-Authenticate", `Bearer realm="agents read API"`)
		plain(w, http.StatusUnauthorized, "a read API token is needed: an admin makes one in Console ▸ Read API\n")
		return
	}
	if !rt.allow(hash, now) {
		w.Header().Set("Retry-After", "10")
		plain(w, http.StatusTooManyRequests, "too many requests with this token; try again in a few seconds\n")
		return
	}
	rt.noteUse(hash, rt.s.sources.of(r), now)
	q := r.URL.Query()
	period := wire.ReportRange(q.Get("range"))
	if period == "" {
		period = wire.ReportRangeMonth
	}
	scope := &wire.ReportScope{Kind: wire.ReportScopeKindOrg}
	if group := q.Get("group"); group != "" {
		scope = &wire.ReportScope{Kind: wire.ReportScopeKindGroup, Group: &group}
	}
	report, err := rt.s.scopedReport(r.Context(), period, scope, t.Made.By.User)
	if err != nil {
		status, words := http.StatusBadRequest, err.Error()
		if e, ok := err.(*RPCError); ok {
			words = e.Message
			if e.Code == storeUnavailable {
				status = http.StatusServiceUnavailable
			}
		}
		plain(w, status, words+"\n")
		return
	}
	switch q.Get("format") {
	case "", "json":
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(report)
	case "csv":
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		w.Write([]byte(reportCSV(report.Rows, report.GroupNames)))
	case "jsonl":
		w.Header().Set("Content-Type", "application/jsonl")
		var b bytes.Buffer
		for _, row := range report.Rows {
			if line, err := json.Marshal(row); err == nil {
				b.Write(line)
				b.WriteByte('\n')
			}
		}
		w.Write(b.Bytes())
	default:
		plain(w, http.StatusBadRequest, "format is json, csv or jsonl\n")
	}
}

// list is every token, newest first.
func (rt *readTokens) list(ctx context.Context) ([]readTokenRecord, map[string]string, error) {
	keys, err := rt.s.cfg.Store.List(ctx, readTokensPrefix)
	if err != nil {
		return nil, nil, fail(storeUnavailable, "The read API's tokens could not be read: %v", err)
	}
	var out []readTokenRecord
	etags := map[string]string{}
	for _, k := range keys {
		object, err := rt.s.cfg.Store.Get(ctx, k.Key)
		if err != nil {
			return nil, nil, fail(storeUnavailable, "The read API's tokens could not be read: %v", err)
		}
		var t readTokenRecord
		if object == nil || json.Unmarshal(object.Data, &t) != nil {
			continue
		}
		out = append(out, t)
		etags[t.ID] = object.ETag
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Made.At > out[j].Made.At })
	return out, etags, nil
}

func (rt *readTokens) url() string {
	base, _ := rt.s.signIns.httpsBase()
	return base + readAPIPath
}

func (rt *readTokens) state(ctx context.Context) (wire.ReadAPI, error) {
	all, _, err := rt.list(ctx)
	if err != nil {
		return wire.ReadAPI{}, err
	}
	out := wire.ReadAPI{Tokens: []wire.ReadToken{}, URL: rt.url(), Otlp: rt.s.otlpState()}
	for _, t := range all {
		out.Tokens = append(out.Tokens, t.onWire())
	}
	return out, nil
}

// make is readApi/make: a new token, refused while mostLiveReadTokens are live.
func (rt *readTokens) make(ctx context.Context, r wire.ReadTokenMake, actor wire.AuditActor) (wire.ReadTokenMade, error) {
	name := strings.TrimSpace(r.Name)
	if name == "" || len([]rune(name)) > 60 {
		return wire.ReadTokenMade{}, fail(invalidParams, "Give the token a name of 1 to 60 characters.")
	}
	if _, ok := rt.s.signIns.httpsBase(); !ok {
		return wire.ReadTokenMade{}, fail(notPermitted, "The read API needs this control plane's HTTPS address.")
	}
	all, _, err := rt.list(ctx)
	if err != nil {
		return wire.ReadTokenMade{}, err
	}
	live := 0
	for _, t := range all {
		if t.Revoked == nil {
			live++
		}
	}
	if live >= mostLiveReadTokens {
		return wire.ReadTokenMade{}, fail(notPermitted, "There are %d live read API tokens. Revoke one first.", live)
	}
	now := time.Now()
	value := readTokenPrefix + randomToken(32)
	sum := sha256.Sum256([]byte(value))
	hash := hex.EncodeToString(sum[:])
	t := readTokenRecord{ID: hash[:12], Name: name, SHA256: hash, Made: wire.OrgRouteStamp{By: actor, At: wire.DateOf(now)}}
	data, err := records.Encode(t)
	if err == nil {
		_, err = rt.s.cfg.Store.Put(ctx, readTokenKey(hash), data, store.Absent)
	}
	if err != nil {
		return wire.ReadTokenMade{}, fail(storeUnavailable, "The token could not be kept: %v", err)
	}
	rt.trim(ctx, append(all, t))
	rt.s.auditAs(actor, "readApi/made", "token "+t.ID+" ("+name+")")
	rt.s.log("a read API token " + t.ID + " was made")
	return wire.ReadTokenMade{Token: t.onWire(), Value: value, URL: rt.url()}, nil
}

// trim deletes the oldest revoked tokens over mostReadTokens.
func (rt *readTokens) trim(ctx context.Context, all []readTokenRecord) {
	sort.SliceStable(all, func(i, j int) bool { return all[i].Made.At > all[j].Made.At })
	over := len(all) - mostReadTokens
	for i := len(all) - 1; i >= 0 && over > 0; i-- {
		if all[i].Revoked != nil {
			_ = rt.s.cfg.Store.Delete(ctx, readTokenKey(all[i].SHA256))
			over--
		}
	}
}

// revoke is readApi/revoke: the token stops working at once here, and within
// readTokenKept at every other copy.
func (rt *readTokens) revoke(ctx context.Context, id string, actor wire.AuditActor) error {
	all, etags, err := rt.list(ctx)
	if err != nil {
		return err
	}
	for _, t := range all {
		if t.ID != id {
			continue
		}
		if t.Revoked != nil {
			return nil
		}
		revoked, err := rt.markRevoked(ctx, t, etags[t.ID], &wire.OrgRouteStamp{By: actor, At: wire.DateOf(time.Now())})
		if err != nil {
			return fail(storeUnavailable, "The token could not be revoked: %v", err)
		}
		rt.mu.Lock()
		delete(rt.read, t.SHA256)
		rt.mu.Unlock()
		if !revoked {
			return nil
		}
		rt.s.auditAs(actor, "readApi/revoked", "token "+t.ID+" ("+t.Name+")")
		return nil
	}
	return fail(invalidParams, "There is no read API token %s.", id)
}

// markRevoked writes t revoked against etag. A conflict is most often noteUse's last-use
// stamp landing in between (#2830), so it reads the token again and tries once more, a
// few times; false when another revoke got there first.
func (rt *readTokens) markRevoked(ctx context.Context, t readTokenRecord, etag string, stamp *wire.OrgRouteStamp) (bool, error) {
	key := readTokenKey(t.SHA256)
	for try := 0; ; try++ {
		t.Revoked = stamp
		data, err := records.Encode(t)
		if err != nil {
			return false, err
		}
		_, err = rt.s.cfg.Store.Put(ctx, key, data, store.Matching(etag))
		if err == nil || !store.IsConflict(err) || try == 3 {
			return err == nil, err
		}
		object, err := rt.s.cfg.Store.Get(ctx, key)
		if err != nil {
			return false, err
		}
		var now readTokenRecord
		if object == nil || json.Unmarshal(object.Data, &now) != nil {
			return false, &store.ConflictError{Key: key}
		}
		t = now
		if t.Revoked != nil {
			return false, nil
		}
		etag = object.ETag
	}
}

func (s *Service) otlpState() *wire.OTLPExport {
	s.mu.Lock()
	e := s.otlp
	s.mu.Unlock()
	return e.State()
}

// readAPIMethod answers readApi/*: an admin's only.
func (m *Methods) readAPIMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	actor := m.s.actorFor(from.Client)
	actor.User = m.callerPerson(from)
	if !m.s.isAdmin(actor.User) {
		return nil, fail(notPermitted, "Only an admin can see or make read API tokens.")
	}
	switch method {
	case "readApi/make":
		r, err := require[wire.ReadTokenMake](params, "ReadTokenMake")
		if err != nil {
			return nil, err
		}
		return m.s.readAPI.make(ctx, r, actor)
	case "readApi/revoke":
		r, err := require[wire.ReadTokenRevoke](params, "ReadTokenRevoke")
		if err != nil {
			return nil, err
		}
		if err := m.s.readAPI.revoke(ctx, r.ID, actor); err != nil {
			return nil, err
		}
	}
	return m.s.readAPI.state(ctx)
}
