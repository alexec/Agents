package connections

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Atlassian has no public clients (#3304): a refresh goes as JSON with the app's secret, and
// its refresh tokens rotate.
func TestAtlassianRefreshSendsTheSecretAsJSON(t *testing.T) {
	var got map[string]string
	var kind string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		kind = r.Header.Get("Content-Type")
		json.NewDecoder(r.Body).Decode(&got)
		fmt.Fprint(w, `{"access_token":"new","refresh_token":"rotated","expires_in":3600}`)
	}))
	defer srv.Close()
	f := NewAtlassianFlow("id", "app-secret")
	f.Token, f.HTTP = srv.URL, srv.Client()
	tok, err := f.Refresh(context.Background(), "old")
	if err != nil || tok.Access != "new" || tok.Refresh != "rotated" {
		t.Fatalf("%+v %v", tok, err)
	}
	if kind != "application/json" || got["client_secret"] != "app-secret" || got["refresh_token"] != "old" || got["grant_type"] != "refresh_token" {
		t.Fatalf("%s %v", kind, got)
	}
}

func TestJiraSiteHeaderAndAPI(t *testing.T) {
	for in, want := range map[string]string{"example.atlassian.net": "https://example.atlassian.net",
		"https://jira.example.com/jira/": "https://jira.example.com/jira", "http://localhost:8080": "http://localhost:8080"} {
		if got, err := JiraSite(in); err != nil || got != want {
			t.Errorf("%s: %q %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "ftp://x", "https://u:p@x.net", "https://x.net?a=b"} {
		if _, err := JiraSite(bad); err == nil {
			t.Errorf("%q was taken", bad)
		}
	}
	oauth := Connection{Access: "t", Resource: "cloud 1", URL: "https://x.atlassian.net"}
	if JiraHeader(oauth) != "Bearer t" || JiraAPI(oauth) != "https://api.atlassian.com/ex/jira/cloud%201" {
		t.Fatalf("oauth: %q %q", JiraHeader(oauth), JiraAPI(oauth))
	}
	cloud := Connection{Access: "t", User: "a@b.c", URL: "https://x.atlassian.net"}
	if JiraHeader(cloud) != "Basic YUBiLmM6dA==" || JiraAPI(cloud) != "https://x.atlassian.net" {
		t.Fatalf("cloud: %q", JiraHeader(cloud))
	}
	if JiraHeader(Connection{Access: "t"}) != "Bearer t" || JiraHeader(Connection{}) != "" {
		t.Fatal("data center or none")
	}
}
