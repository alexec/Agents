package connections

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// An organization (#3802) is named by itself, by its dev.azure.com or visualstudio.com
// address, or as an Azure DevOps Server's collection; http only for this machine.
func TestAzureDevOpsOrganization(t *testing.T) {
	for raw, want := range map[string][2]string{
		"acme":                                     {AzureDevOpsServices, "acme"},
		"dev.azure.com/acme":                       {AzureDevOpsServices, "acme"},
		"https://dev.azure.com/acme/Web/_git/site": {AzureDevOpsServices, "acme"},
		"acme.visualstudio.com":                    {AzureDevOpsServices, "acme"},
		"https://acme.visualstudio.com/DefaultCollection": {AzureDevOpsServices, "acme"},
		"server/tfs/DefaultCollection":                    {"https://server/tfs/", "DefaultCollection"},
		"http://127.0.0.1:3802/acme":                      {"http://127.0.0.1:3802/", "acme"},
	} {
		root, org, err := AzureDevOpsOrganization(raw)
		if err != nil || root != want[0] || org != want[1] {
			t.Errorf("%q: %q %q %v, want %v", raw, root, org, err, want)
		}
	}
	for _, raw := range []string{"", "dev.azure.com", "server.example.com", "http://server.example.com/tfs/c"} {
		if _, _, err := AzureDevOpsOrganization(raw); err == nil {
			t.Errorf("%q: no error", raw)
		}
	}
}

// A token is sent as Basic with no user and names its account; a wrong one, or a sign-in
// page, says so and holds no token.
func TestCheckAzureDevOpsToken(t *testing.T) {
	ado := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, basic := r.BasicAuth()
		switch {
		case r.URL.Path != "/acme/_apis/connectionData":
			http.NotFound(w, r)
		case basic && user == "" && pass == "pat-good":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"authenticatedUser":{"id":"u1","providerDisplayName":"Agents Test"}}`))
		case pass == "pat-redirect":
			http.Redirect(w, r, "/_signin", http.StatusFound)
		default:
			w.WriteHeader(http.StatusUnauthorized)
		}
	}))
	defer ado.Close()
	root := ado.URL + "/"
	ctx := context.Background()
	if login, err := CheckAzureDevOpsToken(ctx, ado.Client(), root, "acme", "pat-good"); err != nil || login != "Agents Test" {
		t.Fatalf("a good token: %q %v", login, err)
	}
	for _, bad := range []string{"pat-bad", "pat-redirect"} {
		if _, err := CheckAzureDevOpsToken(ctx, ado.Client(), root, "acme", bad); err == nil || strings.Contains(err.Error(), bad) || !strings.Contains(err.Error(), "did not take") {
			t.Fatalf("%s: %v", bad, err)
		}
	}
	if _, err := CheckAzureDevOpsToken(ctx, ado.Client(), root, "other", "pat-good"); err == nil || !strings.Contains(err.Error(), "no organization other") {
		t.Fatalf("another organization: %v", err)
	}
	at := time.Now()
	if c := AzureDevOpsConnection(AzureDevOpsServices, "acme", "t", "a", at); c.URL != "" || c.Resource != "acme" || c.Workspace != "dev.azure.com/acme" {
		t.Fatalf("services: %+v", c)
	}
	if c := AzureDevOpsConnection("https://server/tfs/", "DefaultCollection", "t", "a", at); c.URL != "https://server/tfs/" || c.Workspace != "server/tfs/DefaultCollection" {
		t.Fatalf("a server: %+v", c)
	}
}

// #3921: an Entra access token (a JWT) goes as a bearer token; a personal access token as
// Basic's password.
func TestAzureDevOpsAuthorization(t *testing.T) {
	if got := AzureDevOpsAuthorization("eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln"); got != "Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln" {
		t.Fatalf("Entra: %q", got)
	}
	if got := AzureDevOpsAuthorization("abc123"); got != "Basic OmFiYzEyMw==" {
		t.Fatalf("a personal access token: %q", got)
	}
	f := NewAzureDevOpsEntraFlow("app", "contoso.onmicrosoft.com")
	if f.Base != EntraLogin+"contoso.onmicrosoft.com/" || !f.RefreshScope || f.Scope != AzureDevOpsEntraScope {
		t.Fatalf("flow: %+v", f)
	}
	if NewAzureDevOpsEntraFlow("app", " ").Base != EntraLogin+"organizations/" {
		t.Fatal("no tenant")
	}
}
