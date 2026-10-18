package mcpcatalog

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// GHSA-mwhc-9j82-rffr (#1416): a hostile MCP server that copies a known issuer, and gives a
// token endpoint of its own, is not given the person's client, its secret or a real code.

// metadataServer is an MCP server that is its own authorization server, its metadata naming
// the issuer issuerOf gives it (nil: no issuer at all).
func metadataServer(t *testing.T, issuerOf func(self string) *string) *httptest.Server {
	t.Helper()
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/.well-known/oauth-authorization-server" {
			http.NotFound(w, r)
			return
		}
		issuer := ""
		if s := issuerOf(srv.URL); s != nil {
			issuer = fmt.Sprintf(`"issuer":%q,`, *s)
		}
		fmt.Fprintf(w, `{%s"authorization_endpoint":"https://github.com/login/oauth/authorize",
			"token_endpoint":"%s/token","code_challenge_methods_supported":["S256"]}`, issuer, srv.URL)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestDiscoverRefusesAForgedIssuer(t *testing.T) {
	forged := "https://github.com/login/oauth"
	srv := metadataServer(t, func(string) *string { return &forged })
	_, err := OAuth{}.Discover(context.Background(), srv.URL+"/mcp", "")
	var f *OAuthFailure
	if !errors.As(err, &f) || f.Kind != "issuerMismatch" {
		t.Fatalf("a forged issuer: want issuerMismatch, got %v", err)
	}
}

func TestDiscoverRefusesMetadataWithNoIssuer(t *testing.T) {
	srv := metadataServer(t, func(string) *string { return nil })
	_, err := OAuth{}.Discover(context.Background(), srv.URL+"/mcp", "")
	var f *OAuthFailure
	if !errors.As(err, &f) || f.Kind != "issuerMismatch" {
		t.Fatalf("no issuer: want issuerMismatch, got %v", err)
	}
}

func TestDiscoverTakesTheIssuerItFetched(t *testing.T) {
	srv := metadataServer(t, func(self string) *string { return &self })
	plan, err := OAuth{}.Discover(context.Background(), srv.URL+"/mcp", "")
	if err != nil {
		t.Fatal(err)
	}
	if plan.Server.Issuer != srv.URL || plan.Server.TokenEndpoint != srv.URL+"/token" {
		t.Fatalf("plan: %+v", plan.Server)
	}
}

func TestThePersonsClientNeedsItsOwnTokenEndpoint(t *testing.T) {
	s := &SignIns{Home: t.TempDir()}
	secret := "the-secret"
	github := AuthorizationServer{Issuer: "https://github.com/login/oauth",
		TokenEndpoint: "https://github.com/login/oauth/access_token"}
	if err := s.KeepClient(Client{ID: "mine", Secret: &secret}, github); err != nil {
		t.Fatal(err)
	}
	if c, ok := s.ClientFor(github); !ok || c.ID != "mine" {
		t.Fatalf("the same issuer and token endpoint: want the client, got %+v %v", c, ok)
	}
	hostile := github
	hostile.TokenEndpoint = "https://hostile.example/token"
	if c, ok := s.ClientFor(hostile); ok {
		t.Fatalf("another token endpoint was given the person's client: %+v", c)
	}
}
