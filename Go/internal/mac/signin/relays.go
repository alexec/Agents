package signin

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Policy is a runtime's SignInRelay, as ToolPolicyCatalog has it: where its service is and
// where this Mac keeps its sign-in (a Keychain item, or a file under the home folder).
type Policy struct {
	Upstream string
	Keychain string
	File     string
}

// Policies are the runtimes a Mac relays the sign-in of (ToolPolicyCatalog).
var Policies = map[string]Policy{
	"claude": {Upstream: "api.anthropic.com", Keychain: "Claude Code-credentials"},
	"codex":  {Upstream: "chatgpt.com", File: ".codex/auth.json"},
}

// Relays is HostSignInRelays: one relay per runtime, started on its first grant and kept
// for the host's life. Its keys and certificates are in <root>/relay; its log, which says
// only what was asked and how it was answered, is host-relay.log, rolled at 1 MB.
type Relays struct {
	Root, Logs, Home string
	// TestKeychain is a walk's stand-in for Claude's item: never renewed (debug builds).
	TestKeychain string

	mu      sync.Mutex
	relays  map[string]*Relay
	sources map[string]Source
	logMu   sync.Mutex
}

// Grant is the reply to relay/grant.
type Grant struct {
	Runtime, CACertificate, StandIn string
}

// SignIn is this Mac's own sign-in for runtime, where its policy says it is kept.
func (s *Relays) SignIn(runtime string) Source {
	s.mu.Lock()
	defer s.mu.Unlock()
	if src := s.sources[runtime]; src != nil {
		return src
	}
	p, ok := Policies[runtime]
	if !ok {
		return nil
	}
	var src Source
	if p.File != "" {
		src = NewCodex(filepath.Join(s.Home, p.File))
	} else if s.TestKeychain != "" {
		src = NewClaude(s.TestKeychain, true)
	} else {
		src = NewClaude(p.Keychain, false)
	}
	if s.sources == nil {
		s.sources = map[string]Source{}
	}
	s.sources[runtime] = src
	return src
}

// Grant starts relaying runtime's sign-in and says what the borrower's gate needs: the
// relay's CA and a stand-in holding no secret of this Mac's, fresh each time.
func (s *Relays) Grant(runtime string) (Grant, error) {
	p, ok := Policies[runtime]
	src := s.SignIn(runtime)
	if !ok || src == nil {
		return Grant{}, fmt.Errorf("This Mac does not relay %s's sign-in.", runtime)
	}
	if _, err := src.Current(); err != nil {
		return Grant{}, fmt.Errorf("This Mac is not signed in to %s the way a server can use.", runtime)
	}
	certs := Certificates{Folder: filepath.Join(s.Root, "relay")}
	s.mu.Lock()
	r := s.relays[runtime]
	if r == nil {
		r = &Relay{Upstream: p.Upstream, Source: src, Certs: certs, Log: s.write}
		if s.relays == nil {
			s.relays = map[string]*Relay{}
		}
		s.relays[runtime] = r
	}
	s.mu.Unlock()
	if _, err := r.Start(); err != nil {
		return Grant{}, err
	}
	standIn, err := src.StandIn()
	if err != nil {
		return Grant{}, err
	}
	r.ExpectClientBearer(ClientBearer(standIn))
	ca, err := certs.CAPEM()
	if err != nil {
		return Grant{}, err
	}
	s.write("granted " + runtime + " for a tunnel")
	return Grant{Runtime: runtime, CACertificate: ca, StandIn: standIn}, nil
}

// Port is where runtime's relay listens once granted: what a tunnel connects to; 0 if none.
func (s *Relays) Port(runtime string) int {
	s.mu.Lock()
	r := s.relays[runtime]
	s.mu.Unlock()
	if r == nil {
		return 0
	}
	return r.Port()
}

// Stop closes every relay.
func (s *Relays) Stop() {
	s.mu.Lock()
	all := s.relays
	s.relays = nil
	s.mu.Unlock()
	for _, r := range all {
		r.Stop()
	}
}

const logLimit = 1 << 20

func (s *Relays) write(line string) {
	if s.Logs == "" {
		return
	}
	s.logMu.Lock()
	defer s.logMu.Unlock()
	file := filepath.Join(s.Logs, "host-relay.log")
	if fi, err := os.Stat(file); err == nil && fi.Size() > logLimit {
		os.Rename(file, filepath.Join(s.Logs, "host-relay.previous.log"))
	}
	f, err := os.OpenFile(file, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().UTC().Format("2006-01-02T15:04:05Z"), line)
}
