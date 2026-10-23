// Package scim is SCIM 2.0 (RFC 7643, RFC 7644) at /scim/v2/ on the control plane (#1002,
// spec 1002 D11, FR-013): the subset that Okta and Entra use. Users and Groups, filters
// with eq (and and), pages of at most 100, PATCH, the error schema, and the three
// discovery documents. No Bulk, sort, ETags, /Me or password change.
//
// It knows nothing of people or groups: it calls a Directory, which the control plane
// gives it, and a Tokens, which says which org provider a bearer token is of. The token
// decides the provider; a resource of another provider is not found.
package scim

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	SchemaUser       = "urn:ietf:params:scim:schemas:core:2.0:User"
	SchemaGroup      = "urn:ietf:params:scim:schemas:core:2.0:Group"
	SchemaEnterprise = "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"
	schemaList       = "urn:ietf:params:scim:api:messages:2.0:ListResponse"
	schemaError      = "urn:ietf:params:scim:api:messages:2.0:Error"
	schemaConfig     = "urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"
	schemaType       = "urn:ietf:params:scim:schemas:core:2.0:ResourceType"
	schemaSchema     = "urn:ietf:params:scim:schemas:core:2.0:Schema"

	// Base is where the server is mounted.
	Base = "/scim/v2"
	// MaxResults is the largest page (FR-023).
	MaxResults = 100
	// mostBody is the largest request body: one more is 413.
	mostBody = 1 << 20
	// perSecond is how many requests one token may make each second; one more is 429.
	perSecond = 50
)

// Caller is who a request is from: an org provider, by one of its tokens.
type Caller struct {
	Provider string
	Token    string
}

// Tokens says which provider a bearer token is of, and notes its use.
type Tokens interface {
	Authenticate(ctx context.Context, bearer, address string) (Caller, bool)
}

// Name is a user's name parts.
type Name struct {
	GivenName  string `json:"givenName,omitempty"`
	FamilyName string `json:"familyName,omitempty"`
	Formatted  string `json:"formatted,omitempty"`
}

// Email is one of a user's emails.
type Email struct {
	Value   string `json:"value"`
	Type    string `json:"type,omitempty"`
	Primary bool   `json:"primary,omitempty"`
}

// User is a SCIM user as the Directory keeps it. Extra is every attribute not read, the
// Enterprise extension among them, kept as it came.
type User struct {
	ID          string
	ExternalID  string
	UserName    string
	Name        *Name
	DisplayName string
	Emails      []Email
	Active      bool
	Created     time.Time
	Changed     time.Time
	Extra       map[string]json.RawMessage
}

// Member is a group's member: a user's id.
type Member struct {
	Value   string `json:"value"`
	Display string `json:"display,omitempty"`
}

// Group is a SCIM group as the Directory keeps it.
type Group struct {
	ID          string
	ExternalID  string
	DisplayName string
	Members     []Member
	Created     time.Time
	Changed     time.Time
}

// Directory is the people and groups behind the server. Each call is for one provider's
// own resources. A resource not found is (nil, nil); a refusal is an *Error.
type Directory interface {
	// Users is the provider's users that keep takes, by id: filtered before they are sorted,
	// so a sync's GET for one user is not a sort of every user (#2430).
	Users(ctx context.Context, provider string, keep func(User) bool) ([]User, error)
	User(ctx context.Context, provider, id string) (*User, error)
	CreateUser(ctx context.Context, c Caller, u User) (*User, error)
	ReplaceUser(ctx context.Context, c Caller, u User) (*User, error)
	DeleteUser(ctx context.Context, c Caller, id string) error
	// Groups is the provider's groups that keep takes, by id. keep sees each member's
	// value only; the groups it takes have their members' names too.
	Groups(ctx context.Context, provider string, keep func(Group) bool) ([]Group, error)
	Group(ctx context.Context, provider, id string) (*Group, error)
	CreateGroup(ctx context.Context, c Caller, g Group) (*Group, error)
	ReplaceGroup(ctx context.Context, c Caller, g Group) (*Group, error)
	DeleteGroup(ctx context.Context, c Caller, id string) error
}

// Error is a SCIM error (RFC 7644 §3.12).
type Error struct {
	Status   int
	SCIMType string
	Detail   string
}

func (e *Error) Error() string { return fmt.Sprintf("%d %s: %s", e.Status, e.SCIMType, e.Detail) }

// Errorf makes an Error.
func Errorf(status int, scimType, format string, args ...any) *Error {
	return &Error{Status: status, SCIMType: scimType, Detail: fmt.Sprintf(format, args...)}
}

// Uniqueness is 409 uniqueness: a second userName, or displayName.
func Uniqueness(format string, args ...any) *Error {
	return Errorf(http.StatusConflict, "uniqueness", format, args...)
}

// InvalidValue is 400 invalidValue.
func InvalidValue(format string, args ...any) *Error {
	return Errorf(http.StatusBadRequest, "invalidValue", format, args...)
}

// Server answers /scim/v2/.
type Server struct {
	Directory Directory
	Tokens    Tokens
	// URL is the base URL, for meta.location: https://<control plane>/scim/v2.
	URL func() string
	// Log, if set, hears each refused or failed request, with no token.
	Log func(string)
	// PerSecond is how many requests one token may make each second: perSecond if 0.
	PerSecond int

	mu    sync.Mutex
	rates map[string]*rate
	// refusals is each address's refused tokens this second (refusedAt), so a crowd of
	// made-up tokens from one address costs the store little (#2425).
	refusals  map[string]int
	refusedAt int64
}

// mostRefusedPerSecond is how many refused tokens an address may send each second before
// it is answered 429 with no token read.
const mostRefusedPerSecond = 10

// refusing says an address sent mostRefusedPerSecond refused tokens this second; refuse
// counts one more. The map holds one second's addresses only.
func (s *Server) refusing(address string, now time.Time, refuse bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.refusedAt != now.Unix() {
		s.refusals, s.refusedAt = nil, now.Unix()
	}
	if refuse {
		if s.refusals == nil {
			s.refusals = map[string]int{}
		}
		s.refusals[address]++
	}
	return s.refusals[address] >= mostRefusedPerSecond
}

type rate struct {
	second int64
	count  int
}

// allow counts a request for a token, perSecond each second.
func (s *Server) allow(token string, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.rates == nil {
		s.rates = map[string]*rate{}
	}
	r := s.rates[token]
	if r == nil {
		r = &rate{}
		s.rates[token] = r
	}
	if r.second != now.Unix() {
		r.second, r.count = now.Unix(), 0
	}
	r.count++
	return r.count <= cmp.Or(s.PerSecond, perSecond)
}

func (s *Server) log(line string) {
	if s.Log != nil {
		s.Log(line)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/scim+json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}

func writeError(w http.ResponseWriter, e *Error) {
	body := map[string]any{"schemas": []string{schemaError}, "status": strconv.Itoa(e.Status), "detail": e.Detail}
	if e.SCIMType != "" {
		body["scimType"] = e.SCIMType
	}
	writeJSON(w, e.Status, body)
}

// asError is err as a SCIM error: one the Directory made, or a 500 that says nothing.
func asError(err error) *Error {
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	return Errorf(http.StatusInternalServerError, "", "The control plane could not do that. Try again.")
}

func address(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ServeHTTP answers one request under Base.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, Base), "/")
	bearer, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || bearer == "" {
		w.Header().Set("WWW-Authenticate", `Bearer realm="scim"`)
		writeError(w, Errorf(http.StatusUnauthorized, "", "Send a SCIM token: Authorization: Bearer agscim_…"))
		return
	}
	from := address(r)
	if s.refusing(from, time.Now(), false) {
		w.Header().Set("Retry-After", "1")
		writeError(w, Errorf(http.StatusTooManyRequests, "", "Too many tokens that are not live. Try again in a second."))
		return
	}
	caller, ok := s.Tokens.Authenticate(r.Context(), strings.TrimSpace(bearer), from)
	if !ok {
		s.refusing(from, time.Now(), true)
		w.Header().Set("WWW-Authenticate", `Bearer realm="scim", error="invalid_token"`)
		s.log("scim: a request with a token that is not live was refused")
		writeError(w, Errorf(http.StatusUnauthorized, "", "That SCIM token is not live. An admin makes one in Console ▸ Sign-In."))
		return
	}
	if !s.allow(caller.Token, time.Now()) {
		w.Header().Set("Retry-After", "1")
		writeError(w, Errorf(http.StatusTooManyRequests, "", "More than %d requests a second. Try again in a second.", perSecond))
		return
	}
	var body []byte
	if r.Body != nil {
		read, err := io.ReadAll(io.LimitReader(r.Body, mostBody+1))
		if err != nil {
			writeError(w, Errorf(http.StatusBadRequest, "invalidSyntax", "The body could not be read."))
			return
		}
		if len(read) > mostBody {
			writeError(w, Errorf(http.StatusRequestEntityTooLarge, "", "A body is at most 1 MiB."))
			return
		}
		body = read
	}
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	kind, id := parts[0], ""
	if len(parts) == 2 {
		id = parts[1]
	} else if len(parts) > 2 {
		writeError(w, Errorf(http.StatusNotFound, "", "There is nothing at %s.", r.URL.Path))
		return
	}
	switch kind {
	case "ServiceProviderConfig":
		s.only(w, r, http.MethodGet, func() { writeJSON(w, http.StatusOK, s.config()) })
	case "ResourceTypes":
		s.only(w, r, http.MethodGet, func() { s.listOf(w, id, resourceTypes(s.base())) })
	case "Schemas":
		s.only(w, r, http.MethodGet, func() { s.listOf(w, id, schemas()) })
	case "Users":
		s.users(w, r, caller, id, body)
	case "Groups":
		s.groups(w, r, caller, id, body)
	case "Bulk", "Me", ".search":
		writeError(w, Errorf(http.StatusNotImplemented, "", "%s is not supported here.", kind))
	default:
		writeError(w, Errorf(http.StatusNotFound, "", "There is nothing at %s.", r.URL.Path))
	}
}

func (s *Server) only(w http.ResponseWriter, r *http.Request, method string, then func()) {
	if r.Method != method {
		writeError(w, Errorf(http.StatusMethodNotAllowed, "", "%s is not supported here.", r.Method))
		return
	}
	then()
}

func (s *Server) base() string {
	if s.URL == nil {
		return Base
	}
	return s.URL()
}

// listOf is a discovery list, or one of it by id.
func (s *Server) listOf(w http.ResponseWriter, id string, all []map[string]any) {
	if id != "" {
		for _, one := range all {
			if one["id"] == id {
				writeJSON(w, http.StatusOK, one)
				return
			}
		}
		writeError(w, Errorf(http.StatusNotFound, "", "No %s here.", id))
		return
	}
	resources := make([]any, len(all))
	for i, one := range all {
		resources[i] = one
	}
	writeJSON(w, http.StatusOK, listResponse(resources, len(all), 1))
}

func listResponse(resources []any, total, start int) map[string]any {
	if resources == nil {
		resources = []any{}
	}
	return map[string]any{"schemas": []string{schemaList}, "totalResults": total, "startIndex": start,
		"itemsPerPage": len(resources), "Resources": resources}
}

// page reads startIndex and count: 1-based, at most MaxResults.
func page(r *http.Request) (start, count int, err *Error) {
	start, count = 1, MaxResults
	q := r.URL.Query()
	if v := q.Get("startIndex"); v != "" {
		n, e := strconv.Atoi(v)
		if e != nil {
			return 0, 0, InvalidValue("startIndex is a number.")
		}
		start = max(n, 1)
	}
	if v := q.Get("count"); v != "" {
		n, e := strconv.Atoi(v)
		if e != nil {
			return 0, 0, InvalidValue("count is a number.")
		}
		count = min(max(n, 0), MaxResults)
	}
	if q.Get("sortBy") != "" {
		return 0, 0, Errorf(http.StatusNotImplemented, "", "Sorting is not supported here.")
	}
	return start, count, nil
}

// shape keeps only the attributes asked for, or drops those asked not to be.
func shape(r *http.Request, resource map[string]any) map[string]any {
	q := r.URL.Query()
	if attrs := q.Get("attributes"); attrs != "" {
		keep := map[string]bool{"id": true, "schemas": true, "meta": true}
		for _, a := range strings.Split(attrs, ",") {
			keep[strings.ToLower(topName(a))] = true
		}
		for k := range resource {
			if !keep[strings.ToLower(k)] {
				delete(resource, k)
			}
		}
	}
	if excluded := q.Get("excludedAttributes"); excluded != "" {
		for _, a := range strings.Split(excluded, ",") {
			name := strings.ToLower(topName(a))
			for k := range resource {
				if strings.ToLower(k) == name && k != "id" && k != "schemas" {
					delete(resource, k)
				}
			}
		}
	}
	return resource
}

// topName is an attribute's top-level name: emails.value is emails, and a URN-qualified
// core attribute is its own name.
func topName(a string) string {
	a = strings.TrimSpace(a)
	for _, urn := range []string{SchemaUser + ":", SchemaGroup + ":"} {
		if len(a) > len(urn) && strings.EqualFold(a[:len(urn)], urn) {
			a = a[len(urn):]
		}
	}
	name, _, _ := strings.Cut(a, ".")
	return name
}

func readJSON(body []byte) (map[string]any, *Error) {
	var v map[string]any
	d := json.NewDecoder(strings.NewReader(string(body)))
	d.UseNumber()
	if err := d.Decode(&v); err != nil || v == nil {
		return nil, Errorf(http.StatusBadRequest, "invalidSyntax", "The body is not a JSON object.")
	}
	return v, nil
}
