package mcpcatalog

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// SignInFile is ~/.agents-secrets/mcp-sign-ins.json (MCPSignInFile): the person's MCP
// sign-ins, mode 0600, keyed by the server's address as a resource. Never in mcp.json,
// never in a log, never in an answer: a client is only told signed in or needs sign-in.
type SignInFile struct {
	Grants      map[string]Grant       `json:"grants"`
	NeedsSignIn map[string]NeedsSignIn `json:"needsSignIn"`
	// Clients is the ones the person registered themselves, by issuer.
	Clients map[string]Client `json:"clients"`
}

// Grant is what a sign-in left: what to send, and how to renew it.
type Grant struct {
	Issuer             string     `json:"issuer"`
	TokenEndpoint      string     `json:"tokenEndpoint"`
	RevocationEndpoint *string    `json:"revocationEndpoint,omitempty"`
	Client             Client     `json:"client"`
	Access             string     `json:"access"`
	Refresh            *string    `json:"refresh,omitempty"`
	ExpiresAt          *time.Time `json:"expiresAt,omitempty"`
	SignedInAt         time.Time  `json:"signedInAt"`
}

// NeedsSignIn is a server that answered 401 and has no grant.
type NeedsSignIn struct {
	ResourceMetadata *string   `json:"resourceMetadata,omitempty"`
	SeenAt           time.Time `json:"seenAt"`
}

const SignInFileName = "mcp-sign-ins.json"

// ErrSignInsUnreadable is a file there that does not read: nothing is written over it.
var ErrSignInsUnreadable = errors.New(SignInFileName + " could not be read")

func emptySignIns() SignInFile {
	return SignInFile{Grants: map[string]Grant{}, NeedsSignIn: map[string]NeedsSignIn{}, Clients: map[string]Client{}}
}

func loadSignIns(path string) (SignInFile, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return emptySignIns(), nil
	}
	f := emptySignIns()
	if err != nil || json.Unmarshal(b, &f) != nil {
		return emptySignIns(), ErrSignInsUnreadable
	}
	if f.Grants == nil {
		f.Grants = map[string]Grant{}
	}
	if f.NeedsSignIn == nil {
		f.NeedsSignIn = map[string]NeedsSignIn{}
	}
	if f.Clients == nil {
		f.Clients = map[string]Client{}
	}
	return f, nil
}

func (f SignInFile) save(path string) error {
	for k, g := range f.Grants {
		g.SignedInAt = g.SignedInAt.UTC().Truncate(time.Second)
		if g.ExpiresAt != nil {
			t := g.ExpiresAt.UTC().Truncate(time.Second)
			g.ExpiresAt = &t
		}
		f.Grants[k] = g
	}
	for k, n := range f.NeedsSignIn {
		n.SeenAt = n.SeenAt.UTC().Truncate(time.Second)
		f.NeedsSignIn[k] = n
	}
	b, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	os.Chmod(dir, 0o700)
	return store.WriteAtomically(path, b, 0o600)
}

// SignIns is the daemon's keeper of MCP sign-ins (MCPSignIns): what a server's row says,
// the bearer an agent starts with (refreshed first when it is about to end), and sign-out.
// One refresh at a time per server: a refresh token that rotates is spent by the first.
type SignIns struct {
	Home  string // the personal home; "" keeps nothing
	OAuth OAuth
	Log   func(string)
	Now   func() time.Time

	mu         sync.Mutex
	refreshing map[string]*refresh
	probed     map[string]bool
}

type refresh struct {
	done   chan struct{}
	bearer Bearer
}

// Bearer is what a session is given for a server: nothing (Kind ""), a token, or left out
// because it needs a sign-in.
type Bearer struct {
	Kind  string // "", token, needsSignIn
	Token string
}

// RefreshMargin is how close to its end a token is renewed.
const RefreshMargin = 2 * time.Minute

func (s *SignIns) path() string {
	if s.Home == "" {
		return ""
	}
	return filepath.Join(s.Home, ".agents-secrets", SignInFileName)
}

func (s *SignIns) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *SignIns) log(line string) {
	if s.Log != nil {
		s.Log(line)
	}
}

func (s *SignIns) read() SignInFile {
	if s.path() == "" {
		return emptySignIns()
	}
	f, _ := loadSignIns(s.path())
	return f
}

// change edits the file, or nothing when it is there and unreadable.
func (s *SignIns) change(edit func(*SignInFile)) error {
	if s.path() == "" {
		return nil
	}
	f, err := loadSignIns(s.path())
	if err != nil {
		return err
	}
	edit(&f)
	return f.save(s.path())
}

// State is signedIn, needsSignIn, or "" for a server the app has nothing on.
func (s *SignIns) State(server string) string {
	key, ok := Canonical(server)
	if !ok {
		return ""
	}
	f := s.read()
	if _, ok := f.Grants[key]; ok {
		return "signedIn"
	}
	if _, ok := f.NeedsSignIn[key]; ok {
		return "needsSignIn"
	}
	return ""
}

// WasProbed is whether a server was asked this run, so a list asks each once.
func (s *SignIns) WasProbed(server string) bool {
	key, ok := Canonical(server)
	if !ok {
		return true
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, asked := s.probed[key]
	return asked
}

func (s *SignIns) NoteProbe(server string, wants bool) {
	if key, ok := Canonical(server); ok {
		s.mu.Lock()
		if s.probed == nil {
			s.probed = map[string]bool{}
		}
		s.probed[key] = wants
		s.mu.Unlock()
	}
}

func (s *SignIns) ResourceMetadata(server string) string {
	key, ok := Canonical(server)
	if !ok {
		return ""
	}
	if n, ok := s.read().NeedsSignIn[key]; ok && n.ResourceMetadata != nil {
		return *n.ResourceMetadata
	}
	return ""
}

// MarkNeedsSignIn: the server answered 401; unless a grant is held, its row says so.
func (s *SignIns) MarkNeedsSignIn(server, name, resourceMetadata string) {
	key, ok := Canonical(server)
	if !ok {
		return
	}
	s.NoteProbe(server, true)
	err := s.change(func(f *SignInFile) {
		if _, ok := f.Grants[key]; ok {
			return
		}
		n := NeedsSignIn{SeenAt: s.now()}
		if resourceMetadata != "" {
			n.ResourceMetadata = &resourceMetadata
		}
		f.NeedsSignIn[key] = n
	})
	if err != nil {
		s.log("mcp sign-in: " + name + " needs sign-in; " + SignInFileName + " could not be read, so nothing was kept")
		return
	}
	s.log("mcp sign-in: " + name + " needs sign-in")
}

func (s *SignIns) ClientFor(issuer string) (Client, bool) {
	c, ok := s.read().Clients[issuer]
	return c, ok
}

func (s *SignIns) KeepClient(c Client, issuer string) error {
	return s.change(func(f *SignInFile) { f.Clients[issuer] = c })
}

// Keep is a sign-in, kept.
func (s *SignIns) Keep(server, name string, p Plan, c Client, t Tokens) error {
	key, ok := Canonical(server)
	if !ok {
		return nil
	}
	at := s.now()
	err := s.change(func(f *SignInFile) {
		g := Grant{Issuer: p.Server.Issuer, TokenEndpoint: p.Server.TokenEndpoint, RevocationEndpoint: p.Server.RevocationEndpoint,
			Client: c, Access: t.Access, SignedInAt: at}
		if t.Refresh != "" {
			r := t.Refresh
			g.Refresh = &r
		}
		if t.ExpiresIn != nil {
			e := at.Add(time.Duration(*t.ExpiresIn) * time.Second)
			g.ExpiresAt = &e
		}
		f.Grants[key] = g
		delete(f.NeedsSignIn, key)
	})
	if err != nil {
		return err
	}
	s.NoteProbe(server, true)
	s.log("mcp sign-in: " + name + " signed in")
	return nil
}

// SignOut forgets the grant, revoking it first where the server offers that. The server is
// then one that needs a sign-in.
func (s *SignIns) SignOut(ctx context.Context, server, name string) error {
	key, ok := Canonical(server)
	if !ok {
		return nil
	}
	if g, ok := s.read().Grants[key]; ok && g.RevocationEndpoint != nil {
		token := g.Access
		if g.Refresh != nil {
			token = *g.Refresh
		}
		s.OAuth.Revoke(ctx, token, *g.RevocationEndpoint, g.Client)
	}
	if err := s.change(func(f *SignInFile) {
		delete(f.Grants, key)
		f.NeedsSignIn[key] = NeedsSignIn{SeenAt: s.now()}
	}); err != nil {
		return err
	}
	s.log("mcp sign-in: " + name + " signed out")
	return nil
}

// BearerFor is the bearer to send server with, refreshed first when it ends within
// RefreshMargin. A refresh token no longer taken leaves the server needing a sign-in.
func (s *SignIns) BearerFor(ctx context.Context, server, name string) Bearer {
	key, ok := Canonical(server)
	if !ok {
		return Bearer{}
	}
	s.mu.Lock()
	if r, ok := s.refreshing[key]; ok {
		s.mu.Unlock()
		<-r.done
		return r.bearer
	}
	f := s.read()
	g, held := f.Grants[key]
	if !held {
		s.mu.Unlock()
		if _, ok := f.NeedsSignIn[key]; ok {
			return Bearer{Kind: "needsSignIn"}
		}
		return Bearer{}
	}
	current := s.now()
	if g.ExpiresAt == nil || g.ExpiresAt.Sub(current) >= RefreshMargin {
		s.mu.Unlock()
		return Bearer{Kind: "token", Token: g.Access}
	}
	if g.Refresh == nil {
		s.mu.Unlock()
		if g.ExpiresAt.After(current) {
			return Bearer{Kind: "token", Token: g.Access}
		}
		return s.expire(key, name, "its token ended")
	}
	r := &refresh{done: make(chan struct{})}
	if s.refreshing == nil {
		s.refreshing = map[string]*refresh{}
	}
	s.refreshing[key] = r
	s.mu.Unlock()
	r.bearer = s.renew(ctx, key, name, g)
	s.mu.Lock()
	delete(s.refreshing, key)
	s.mu.Unlock()
	close(r.done)
	return r.bearer
}

func (s *SignIns) renew(ctx context.Context, key, name string, g Grant) Bearer {
	t, err := s.OAuth.Refresh(ctx, *g.Refresh, g.TokenEndpoint, g.Client, key)
	if err == nil {
		at := s.now()
		s.change(func(f *SignInFile) {
			kept, ok := f.Grants[key]
			if !ok {
				return
			}
			kept.Access = t.Access
			// A server that does not rotate it answers without one: the old one stands.
			if t.Refresh != "" {
				r := t.Refresh
				kept.Refresh = &r
			}
			kept.ExpiresAt = nil
			if t.ExpiresIn != nil {
				e := at.Add(time.Duration(*t.ExpiresIn) * time.Second)
				kept.ExpiresAt = &e
			}
			f.Grants[key] = kept
		})
		s.log("mcp sign-in: " + name + " refreshed")
		return Bearer{Kind: "token", Token: t.Access}
	}
	var f *OAuthFailure
	if errors.As(err, &f) && f.Kind == "invalidGrant" {
		return s.expire(key, name, "its sign-in has ended")
	}
	word := "failed"
	if f != nil {
		word = f.LogWord()
	}
	// Not reached, or refused for now: the token there is still good if it has not ended.
	if g.ExpiresAt != nil && g.ExpiresAt.After(s.now()) {
		s.log("mcp sign-in: " + name + " refresh " + word + "; using the token it has")
		return Bearer{Kind: "token", Token: g.Access}
	}
	s.log("mcp sign-in: " + name + " refresh " + word)
	return Bearer{Kind: "needsSignIn"}
}

func (s *SignIns) expire(key, name, why string) Bearer {
	s.change(func(f *SignInFile) {
		delete(f.Grants, key)
		f.NeedsSignIn[key] = NeedsSignIn{SeenAt: s.now()}
	})
	s.log("mcp sign-in: " + name + " needs sign-in: " + why)
	return Bearer{Kind: "needsSignIn"}
}
