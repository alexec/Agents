package signintest

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// TestServe runs the fake org provider until it is stopped, for a walk on a scratch
// control plane (#1002, slice 3). It runs only with AGENTS_FAKE_OIDC set to a file, where
// it writes the issuer, the client id and secret, and the certificate to trust (PEM, for
// the control plane's AGENTS_TEST_TRUST_ROOT). Sam (00u-sam, sam@acme.test) signs in.
//
//	GOOS=darwin Go/scripts/go.sh test -c -o out/fake-oidc ./internal/controlplane/signin/signintest
//	AGENTS_FAKE_OIDC=/tmp/oidc.json Go/out/fake-oidc -test.run TestServe -test.timeout 0
//
// A file <AGENTS_FAKE_OIDC>.code, holding an admin's client code of the scratch control plane
// (started after this, with the certificate), makes it add itself there as "Acme Okta" (Anyone may join), turns on SCIM, provisions Sam and Lee
// (who never signs in), and puts Sam in a group that gives the admin role. Then a file
// <AGENTS_FAKE_OIDC>.suspend suspends Sam by SCIM, and <AGENTS_FAKE_OIDC>.resume turns them
// on again; each is removed once done.
func TestServe(t *testing.T) {
	file := os.Getenv("AGENTS_FAKE_OIDC")
	if file == "" {
		t.Skip("a walk's tool: set AGENTS_FAKE_OIDC")
	}
	p := NewProvider(t, "RS256", "/oauth2/default")
	p.SignInAs(Claims{"sub": "00u-sam", "email": "sam@acme.test", "name": "Sam"})
	cert := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: p.Server.Certificate().Raw})
	data, _ := json.MarshalIndent(map[string]string{"issuer": p.Issuer, "clientID": p.ClientID, "clientSecret": p.ClientSecret,
		"certificate": string(cert)}, "", "  ")
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	var scim func(method, path string, body any) map[string]any
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	tick := time.NewTicker(time.Second)
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
		}
		if code, err := os.ReadFile(file + ".code"); err == nil && scim == nil {
			os.Remove(file + ".code")
			scim = setUp(t, p, strings.TrimSpace(string(code)))
		}
		if scim == nil {
			continue
		}
		for suffix, active := range map[string]bool{".suspend": false, ".resume": true} {
			if _, err := os.Stat(file + suffix); err == nil {
				os.Remove(file + suffix)
				scim("PATCH", "/Users/"+samID, map[string]any{"schemas": []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"},
					"Operations": []map[string]any{{"op": "replace", "value": map[string]any{"active": active}}}})
				fmt.Println("sam active:", active)
			}
		}
	}
}

var samID string

func setUp(t *testing.T, p *Provider, text string) func(method, path string, body any) map[string]any {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	code, err := controllink.ParseCode(text)
	if err != nil {
		t.Fatal(err)
	}
	m, err := controllink.PairClientAs(ctx, code, "Walk set-up", "mac")
	if err != nil {
		t.Fatal(err)
	}
	s, err := controllink.DialClient(ctx, m)
	if err != nil {
		t.Fatal(err)
	}
	call := func(method string, params any) json.RawMessage {
		raw, err := s.Call(ctx, "", method, params)
		if err != nil {
			t.Fatalf("%s: %v", method, err)
		}
		return raw
	}
	join := wire.OrgProviderJoinAnyone
	call("signIn/orgProviders/set", wire.OrgProviderSet{Provider: wire.OrgProvider{Name: "Acme Okta", Preset: wire.OrgProviderPresetOkta,
		Issuer: p.Issuer, ClientID: p.ClientID, Join: &join}, Secret: &p.ClientSecret})
	match := wire.SCIMMatchExternalId
	call("scim/set", wire.SCIMSet{Provider: "acme-okta", On: true, Match: &match})
	var made wire.SCIMTokenMade
	json.Unmarshal(call("scim/tokens/make", wire.SCIMTokenMake{Provider: "acme-okta", Name: "Okta"}), &made)
	// The scratch control plane's own certificate is a walk's: not checked.
	client := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	scim := func(method, path string, body any) map[string]any {
		data, _ := json.Marshal(body)
		req, _ := http.NewRequest(method, made.URL+path, bytes.NewReader(data))
		req.Header.Set("Authorization", "Bearer "+made.Value)
		req.Header.Set("Content-Type", "application/scim+json")
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var out map[string]any
		json.NewDecoder(res.Body).Decode(&out)
		if res.StatusCode >= 300 {
			t.Fatalf("%s %s: %d %v", method, path, res.StatusCode, out)
		}
		return out
	}
	user := func(name, external string) string {
		out := scim("POST", "/Users", map[string]any{"schemas": []string{"urn:ietf:params:scim:schemas:core:2.0:User"},
			"userName": name, "externalId": external, "active": true, "displayName": strings.Split(name, "@")[0]})
		id, _ := out["id"].(string)
		return id
	}
	samID = user("sam@acme.test", "00u-sam")
	user("lee@acme.test", "00u-lee")
	group := scim("POST", "/Groups", map[string]any{"schemas": []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		"displayName": "Acme Admins", "members": []map[string]any{{"value": samID}}})
	groupID, _ := group["id"].(string)
	var groups wire.GroupList
	json.Unmarshal(call("groups/list", map[string]any{}), &groups)
	for _, g := range groups.Groups {
		if g.Source != nil && g.Source.DisplayName == "Acme Admins" {
			admin := wire.UserRoleAdmin
			call("groups/setRole", map[string]any{"group": g.ID, "role": admin})
		}
	}
	fmt.Println("set up: acme-okta, SCIM, sam", samID, "lee, group", groupID)
	return scim
}
