package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/scim"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/signin/signintest"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// scimOn turns SCIM on for the org provider and makes a token: its value and the base URL.
func scimOn(t *testing.T, owner *controllink.Session, match wire.SCIMMatch) (string, string) {
	t.Helper()
	call(t, owner, "", "scim/set", wire.SCIMSet{Provider: "acme-okta", On: true, Match: &match})
	var made wire.SCIMTokenMade
	json.Unmarshal(call(t, owner, "", "scim/tokens/make", wire.SCIMTokenMake{Provider: "acme-okta", Name: "Okta"}), &made)
	if !strings.HasPrefix(made.Value, "agscim_") || !strings.HasSuffix(made.URL, "/scim/v2") {
		t.Fatalf("%+v", made)
	}
	return made.Value, made.URL
}

// scimPlane is a plane with the fake provider as acme-okta, SCIM on, and a token.
func scimPlane(t *testing.T, join wire.OrgProviderJoin) (*plane, *controllink.Session, *signintest.Provider, string, string) {
	prov := signintest.NewProvider(t, "RS256", "")
	p, _, owner, _ := orgPlane(t, prov, nil)
	addOrg(t, owner, prov, join)
	token, base := scimOn(t, owner, wire.SCIMMatchExternalId)
	return p, owner, prov, token, base
}

func scimDo(t *testing.T, base, token, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		reader = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, base+path, reader)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/scim+json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func newUser(userName, externalID string) map[string]any {
	return map[string]any{"schemas": []string{"urn:ietf:params:scim:schemas:core:2.0:User"}, "userName": userName,
		"externalId": externalID, "active": true, "displayName": strings.Split(userName, "@")[0]}
}

func patchOp(ops ...map[string]any) map[string]any {
	return map[string]any{"schemas": []string{"urn:ietf:params:scim:api:messages:2.0:PatchOp"}, "Operations": ops}
}

// play plays a recorded request set (research R4): each request's status, and what it
// says it expects of the answer.
func play(t *testing.T, base, token, file string) map[string]string {
	t.Helper()
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var set struct {
		Steps []struct {
			Name          string          `json:"name"`
			Method        string          `json:"method"`
			Path          string          `json:"path"`
			Body          json.RawMessage `json:"body"`
			Status        int             `json:"status"`
			Save          string          `json:"save"`
			Expect        map[string]any  `json:"expect"`
			ExpectMembers *int            `json:"expectMembers"`
			NoMembers     bool            `json:"noMembers"`
		} `json:"steps"`
	}
	if err := json.Unmarshal(data, &set); err != nil {
		t.Fatal(err)
	}
	ids := map[string]string{}
	fill := func(s string) string {
		for name, id := range ids {
			s = strings.ReplaceAll(s, "${"+name+"}", id)
		}
		return s
	}
	for _, step := range set.Steps {
		var body any
		if len(step.Body) > 0 {
			json.Unmarshal([]byte(fill(string(step.Body))), &body)
		}
		status, out := scimDo(t, base, token, step.Method, fill(step.Path), body)
		if status != step.Status {
			t.Fatalf("%s: %s %s answered %d, not %d: %v", file, step.Method, step.Name, status, step.Status, out)
		}
		if status >= 400 && (out["schemas"] == nil || out["status"] != strconv.Itoa(status)) {
			t.Fatalf("%s: %s: not a SCIM error: %v", file, step.Name, out)
		}
		if step.Save != "" {
			ids[step.Save], _ = out["id"].(string)
		}
		for k, want := range step.Expect {
			if got := out[k]; got != want && !(isNumber(got) && isNumber(want) && toFloat(got) == toFloat(want)) {
				t.Fatalf("%s: %s: %s is %v, not %v", file, step.Name, k, got, want)
			}
		}
		if step.ExpectMembers != nil {
			if members, _ := out["members"].([]any); len(members) != *step.ExpectMembers {
				t.Fatalf("%s: %s: %d members", file, step.Name, len(members))
			}
		}
		if step.NoMembers {
			for _, r := range out["Resources"].([]any) {
				if _, there := r.(map[string]any)["members"]; there {
					t.Fatalf("%s: %s: members sent", file, step.Name)
				}
			}
		}
	}
	return ids
}

func isNumber(v any) bool { _, ok := v.(float64); return ok }
func toFloat(v any) float64 {
	f, _ := v.(float64)
	return f
}

// T014, SC-006: Okta's and Entra's request sets play with no failed request; the
// Enterprise extension is kept as it came, and no password is kept anywhere.
func TestOktaAndEntraRequestSetsPlay(t *testing.T) {
	t.Parallel()
	p, owner, _, token, base := scimPlane(t, wire.OrgProviderJoinScim)
	ids := play(t, base, token, "scim/testdata/okta.json")
	kim := p.s.records.Person(ids["kim"])
	if kim == nil || kim.SCIM == nil || string(kim.SCIM.Extra["urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"]) == "" {
		t.Fatalf("%+v", kim)
	}
	if storeHolds(t, p.store, "never-kept-1") {
		t.Fatal("the store holds a SCIM password")
	}
	ids = play(t, base, token, "scim/testdata/entra.json")
	ana := p.s.records.Person(ids["ana"])
	if ana.Name != "Ana Silva-Reis" || ana.SCIM.Emails[0].Value != "ana.reis@contoso.test" || ana.SCIM.Name.GivenName != nil {
		t.Fatalf("%+v %+v", ana, ana.SCIM)
	}
	if !strings.Contains(string(ana.SCIM.Extra["urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"]), "Marketing") {
		t.Fatal(string(ana.SCIM.Extra["urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"]))
	}
	// Ben, deleted, is suspended and waits for an admin's Remove.
	ben := p.s.records.Person(ids["ben"])
	if !ben.IsSuspended() || ben.IsRemoved() {
		t.Fatalf("%+v", ben)
	}
	var requests wire.RemoveRequestList
	json.Unmarshal(call(t, owner, "", "people/removeRequests", nil), &requests)
	if len(requests.Requests) != 1 || requests.Requests[0].User != ids["ben"] {
		t.Fatalf("%+v", requests)
	}
	call(t, owner, "", "people/remove", wire.PersonRequest{User: ids["ben"]})
	json.Unmarshal(call(t, owner, "", "people/removeRequests", nil), &requests)
	if len(requests.Requests) != 0 {
		t.Fatalf("%+v", requests)
	}
	status, out := scimDo(t, base, token, "GET", "/ServiceProviderConfig", nil)
	if status != 200 || out["bulk"].(map[string]any)["supported"] != false || out["patch"].(map[string]any)["supported"] != true {
		t.Fatal(status, out)
	}
}

// T015, FR-014: no token, a wrong, revoked or ended one, or another provider's resource:
// refused, and nothing written. Two tokens at most are live; the last use is noted.
func TestSCIMTokens(t *testing.T) {
	t.Parallel()
	p, owner, _, token, base := scimPlane(t, wire.OrgProviderJoinScim)
	people := len(p.s.records.People())
	for _, bad := range []string{"", "agscim_wrong", "Basic " + token} {
		if status, out := scimDo(t, base, bad, "POST", "/Users", newUser("sam@acme.test", "00u-sam")); status != 401 || out["status"] != "401" {
			t.Fatal(bad, status, out)
		}
	}
	if len(p.s.records.People()) != people {
		t.Fatal("a refused request wrote a person")
	}
	if status, _ := scimDo(t, base, token, "POST", "/Users", newUser("sam@acme.test", "00u-sam")); status != 201 {
		t.Fatal(status)
	}
	// A second token, then a third is refused while two are live.
	var second wire.SCIMTokenMade
	json.Unmarshal(call(t, owner, "", "scim/tokens/make", wire.SCIMTokenMake{Provider: "acme-okta", Name: "Rotation"}), &second)
	if e := callError(t, owner, "", "scim/tokens/make", wire.SCIMTokenMake{Provider: "acme-okta", Name: "Third"}); !strings.Contains(e, "Revoke one first") {
		t.Fatal(e)
	}
	var list wire.SCIMTokenList
	json.Unmarshal(call(t, owner, "", "scim/tokens/list", wire.SCIMTokensRequest{Provider: "acme-okta"}), &list)
	if len(list.Tokens) != 2 {
		t.Fatalf("%+v", list)
	}
	p.waitFor(func() bool {
		json.Unmarshal(call(t, owner, "", "scim/tokens/list", wire.SCIMTokensRequest{Provider: "acme-okta"}), &list)
		return slices.ContainsFunc(list.Tokens, func(tk wire.SCIMToken) bool { return tk.LastUse != nil })
	}, "the token's last use noted")
	// Revoked: refused at once.
	call(t, owner, "", "scim/tokens/revoke", wire.SCIMTokenRequest{ID: second.Token.ID})
	if status, _ := scimDo(t, base, second.Value, "GET", "/Users", nil); status != 401 {
		t.Fatal(status)
	}
	// The store keeps no token value.
	if storeHolds(t, p.store, strings.TrimPrefix(token, "agscim_")) || storeHolds(t, p.store, strings.TrimPrefix(second.Value, "agscim_")) {
		t.Fatal("the store holds a SCIM token")
	}
	// Another provider's token reaches none of acme-okta's people.
	prov2 := signintest.NewProvider(t, "RS256", "")
	p.s.signIns.cfg.HTTP = prov2.HTTP()
	other := orgProvider(prov2, wire.OrgProviderJoinScim)
	other.Name, other.ID = "Other Entra", "other-entra"
	call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: other, Secret: &prov2.ClientSecret})
	call(t, owner, "", "scim/set", wire.SCIMSet{Provider: "other-entra", On: true})
	var made wire.SCIMTokenMade
	json.Unmarshal(call(t, owner, "", "scim/tokens/make", wire.SCIMTokenMake{Provider: "other-entra", Name: "Entra"}), &made)
	_, list2 := scimDo(t, base, made.Value, "GET", "/Users", nil)
	if list2["totalResults"].(float64) != 0 {
		t.Fatal(list2)
	}
	sam := ""
	for _, q := range p.s.records.People() {
		if q.SCIM != nil && q.SCIM.UserName == "sam@acme.test" {
			sam = q.ID
		}
	}
	if status, _ := scimDo(t, base, made.Value, "GET", "/Users/"+sam, nil); status != 404 {
		t.Fatal(status)
	}
	// SCIM off: no token works.
	call(t, owner, "", "scim/set", wire.SCIMSet{Provider: "acme-okta", On: false})
	p.s.scimTokens.forget()
	if status, _ := scimDo(t, base, token, "GET", "/Users", nil); status != 401 {
		t.Fatal(status)
	}
}

// T016, FR-015, FR-016: users made, a second userName refused, filters, pages of 100, PUT
// and PATCH, the match at first sign-in, and a rename kept.
func TestSCIMUsers(t *testing.T) {
	t.Parallel()
	p, owner, prov, token, base := scimPlane(t, wire.OrgProviderJoinScim)
	status, lee := scimDo(t, base, token, "POST", "/Users", newUser("lee@acme.test", "00u-lee"))
	if status != 201 || lee["id"] == "" || lee["active"] != true {
		t.Fatal(status, lee)
	}
	id := lee["id"].(string)
	if status, out := scimDo(t, base, token, "POST", "/Users", newUser("Lee@Acme.test", "00u-other")); status != 409 || out["scimType"] != "uniqueness" {
		t.Fatal(status, out)
	}
	for i := range 5 {
		scimDo(t, base, token, "POST", "/Users", newUser("user"+strconv.Itoa(i)+"@acme.test", "00u-"+strconv.Itoa(i)))
	}
	for _, f := range []string{`userName eq "LEE@acme.test"`, `externalId eq "00u-lee"`, `emails.value eq "nobody@acme.test"`} {
		_, out := scimDo(t, base, token, "GET", "/Users?filter="+urlEscape(f), nil)
		want := 1.0
		if strings.HasPrefix(f, "emails") {
			want = 0
		}
		if out["totalResults"] != want {
			t.Fatal(f, out)
		}
	}
	_, page := scimDo(t, base, token, "GET", "/Users?startIndex=3&count=2", nil)
	if page["totalResults"] != 6.0 || page["itemsPerPage"] != 2.0 || page["startIndex"] != 3.0 {
		t.Fatal(page)
	}
	_, all := scimDo(t, base, token, "GET", "/Users?count=500", nil)
	if all["itemsPerPage"] != 6.0 {
		t.Fatal(all)
	}
	if status, _ := scimDo(t, base, token, "GET", "/Users?filter="+urlEscape(`userName sw "lee"`), nil); status != 400 {
		t.Fatal(status)
	}
	// Provisioned: People says Waiting for first sign-in.
	var list wire.PeopleList
	json.Unmarshal(call(t, owner, "", "people/list", nil), &list)
	row := list.People[slices.IndexFunc(list.People, func(r wire.PersonRow) bool { return r.ID == id })]
	if row.Provisioned == nil || !*row.Provisioned || row.Scim == nil || row.Scim.Provider != "acme-okta" {
		t.Fatalf("%+v", row)
	}
	// PATCH with no path, and active as a string.
	if status, out := scimDo(t, base, token, "PATCH", "/Users/"+id, patchOp(map[string]any{"op": "replace",
		"value": map[string]any{"displayName": "Lee Park", "name.givenName": "Lee"}})); status != 200 || out["displayName"] != "Lee Park" {
		t.Fatal(status, out)
	}
	if p.s.records.Person(id).Name != "Lee Park" {
		t.Fatal(p.s.records.Person(id).Name)
	}
	// Someone not provisioned is refused when only SCIM people may join.
	b := &browser{prov: prov}
	prov.SignInAs(signintest.Claims{"sub": "00u-stranger", "email": "x@acme.test"})
	if _, err := p.signInOrg(t, b); err == nil || !strings.Contains(err.Error(), "has not added you") {
		t.Fatal(err)
	}
	// Lee signs in: matched by externalId to the person SCIM made.
	prov.SignInAs(signintest.Claims{"sub": "00u-lee", "email": "lee@acme.test", "name": "Lee"})
	m, err := p.signInOrg(t, b)
	if err != nil || personOf(t, p, m) != id {
		t.Fatal(err)
	}
	if q := p.s.records.Person(id); q.Provisioned || !q.HasSignIn("acme-okta", "00u-lee") {
		t.Fatalf("%+v", q)
	}
	// A rename keeps the old userName for the match by userName.
	scimDo(t, base, token, "PUT", "/Users/"+id, newUser("lee.park@acme.test", "00u-lee"))
	if q := p.s.records.Person(id); len(q.LastNames) != 1 || q.LastNames[0].UserName != "lee@acme.test" || !q.HasSignIn("acme-okta", "00u-lee") {
		t.Fatalf("%+v", q)
	}
	// The old userName is free again.
	if status, _ := scimDo(t, base, token, "POST", "/Users", newUser("lee@acme.test", "00u-new-lee")); status != 201 {
		t.Fatal(status)
	}
	// A SCIM POST for a person who signed in first (Anyone) links to them.
	o := listedProvider(t, owner)
	o.Provider.Join = new(wire.OrgProviderJoinAnyone)
	call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: o.Provider, Rev: &o.Rev})
	prov.SignInAs(signintest.Claims{"sub": "00u-early", "email": "early@acme.test", "name": "Early"})
	early, err := p.signInOrg(t, b)
	if err != nil {
		t.Fatal(err)
	}
	status, out := scimDo(t, base, token, "POST", "/Users", newUser("early@acme.test", "00u-early"))
	if status != 201 || out["id"] != personOf(t, p, early) {
		t.Fatal(status, out, personOf(t, p, early))
	}
}

func urlEscape(s string) string {
	return strings.NewReplacer(" ", "%20", `"`, "%22", "@", "%40").Replace(s)
}

func listedProvider(t *testing.T, owner *controllink.Session) wire.OrgProviderKept {
	var list wire.OrgProviderList
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/list", nil), &list)
	return list.Providers[0]
}

// T017, FR-017, SC-003: active: false on one copy cuts off the person's three clients on
// both copies within 5 seconds; they cannot connect or sign in again, and their keys stop
// renewing. DELETE adds a Remove request. active: true undoes it. The local owner stays.
func TestSCIMSuspensionOnTwoCopies(t *testing.T) {
	// Not parallel (#2512): it holds a wall-clock limit, which other tests running beside it would make flaky.
	prov := signintest.NewProvider(t, "RS256", "")
	st, key, keeper := store.NewMemory(), controllink.NewPrivateKey(), newKeeperKey()
	change := func(c *Config) {
		withKeeper(keeper)(c)
		c.SignIn = &signin.Config{HTTP: prov.HTTP()}
	}
	a, b := startCopyWith(t, st, key, change), startCopyWith(t, st, key, change)
	a.waitFor(func() bool { return len(a.s.mesh.peers()) == 1 && len(b.s.mesh.peers()) == 1 }, "the copies linked")
	_, owner := a.client("Alex's Mac")
	addOrg(t, owner, prov, wire.OrgProviderJoinScim)
	token, base := scimOn(t, owner, wire.SCIMMatchExternalId)
	_, kim := scimDo(t, base, token, "POST", "/Users", newUser("kim@acme.test", "00u-kim"))
	id := kim["id"].(string)
	prov.SignInAs(signintest.Claims{"sub": "00u-kim", "email": "kim@acme.test", "name": "Kim"})
	var sessions []*controllink.Session
	var memberships []*controllink.ClientMembership
	for i, at := range []*plane{a, b, a} {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		m, err := controllink.SignInOrg(ctx, at.url, "", nil, "Kim's device "+strconv.Itoa(i), records.KindIPhone, "acme-okta", (&browser{prov: prov}).ticket(t))
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		s, err := controllink.DialClient(context.Background(), m)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(s.Close)
		sessions, memberships = append(sessions, s), append(memberships, m)
	}
	b.waitFor(func() bool { return b.s.records.Person(id) != nil }, "b read Kim")
	began := time.Now()
	if status, _ := scimDo(t, base, token, "PATCH", "/Users/"+id, patchOp(map[string]any{"op": "replace", "path": "active", "value": false})); status != 200 {
		t.Fatal(status)
	}
	for i, s := range sessions {
		deadline := time.Now().Add(5 * time.Second)
		for {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			_, err := s.Call(ctx, "", "control/status", nil)
			cancel()
			if err != nil {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("client %d still connected after 5 s", i)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	if took := time.Since(began); took > 5*time.Second {
		t.Fatal(took)
	}
	// They cannot connect again, at either copy, and keep their keys.
	for _, m := range memberships {
		if _, err := controllink.DialClient(context.Background(), m); err == nil || !strings.Contains(err.Error(), "suspended") {
			t.Fatal(err)
		}
	}
	// No org sign-in, and no renewal.
	if _, err := a.signInOrg(t, &browser{prov: prov}); err == nil || !strings.Contains(err.Error(), "turned your access off") {
		t.Fatal(err)
	}
	c := a.s.records.Client(memberships[0].Client)
	expires := records.At(time.Now().Add(24 * time.Hour))
	c.Expires = &expires
	a.s.records.SaveClient(context.Background(), *c)
	a.s.renewClient(context.Background(), c.ID)
	if got := a.s.records.Client(c.ID).Expires; !got.Time.Equal(expires.Time) {
		t.Fatal("a suspended person's key renewed")
	}
	var list wire.PeopleList
	json.Unmarshal(call(t, owner, "", "people/list", nil), &list)
	row := list.People[slices.IndexFunc(list.People, func(r wire.PersonRow) bool { return r.ID == id })]
	if row.Suspended == nil || row.Suspended.By != "scim" || row.Suspended.Provider != "acme-okta" {
		t.Fatalf("%+v", row)
	}
	// active: true: they connect again.
	scimDo(t, base, token, "PATCH", "/Users/"+id, patchOp(map[string]any{"op": "replace", "path": "active", "value": "True"}))
	b.waitFor(func() bool { return !b.s.suspended(id) }, "b heard the suspension end")
	again, err := controllink.DialClient(context.Background(), memberships[1])
	if err != nil {
		t.Fatal(err)
	}
	again.Close()
	// DELETE suspends and asks an admin.
	scimDo(t, base, token, "DELETE", "/Users/"+id, nil)
	b.waitFor(func() bool { return b.s.suspended(id) }, "b heard the delete")
	var requests wire.RemoveRequestList
	json.Unmarshal(call(t, owner, "", "people/removeRequests", nil), &requests)
	if len(requests.Requests) != 1 || requests.Requests[0].Name != "kim" {
		t.Fatalf("%+v", requests)
	}
	// The owner's window is untouched.
	call(t, owner, "", "control/status", nil)
}

// T018, FR-019 to FR-021: groups with members, PATCH add and remove, another provider's
// member refused, Gives the admin role, managedByProvider, the last admin kept.
func TestSCIMGroupsGiveRoles(t *testing.T) {
	t.Parallel()
	p, owner, _, token, base := scimPlane(t, wire.OrgProviderJoinScim)
	_, raj := scimDo(t, base, token, "POST", "/Users", newUser("raj@acme.test", "00u-raj"))
	rajID := raj["id"].(string)
	status, g := scimDo(t, base, token, "POST", "/Groups", map[string]any{"displayName": "Agents Admins", "members": []any{}})
	if status != 201 {
		t.Fatal(status, g)
	}
	gid := g["id"].(string)
	if status, _ := scimDo(t, base, token, "POST", "/Groups", map[string]any{"displayName": "agents admins"}); status != 409 {
		t.Fatal(status)
	}
	// Bots and the owner are not this provider's users.
	if status, out := scimDo(t, base, token, "PATCH", "/Groups/"+gid, patchOp(map[string]any{"op": "add", "path": "members",
		"value": []any{map[string]any{"value": p.s.localOwner()}}})); status != 400 || out["scimType"] != "invalidValue" {
		t.Fatal(status, out)
	}
	// An admin cannot change a SCIM group's members, or remove it.
	var groups wire.GroupList
	json.Unmarshal(call(t, owner, "", "groups/list", nil), &groups)
	if len(groups.Groups) != 1 || groups.Groups[0].Source == nil || groups.Groups[0].Source.Scim != "acme-okta" {
		t.Fatalf("%+v", groups)
	}
	if e := callError(t, owner, "", "groups/set", wire.GroupSet{ID: &gid, Name: "Agents Admins", Members: []string{p.s.localOwner()}}); !strings.Contains(e, "provider") {
		t.Fatal(e)
	}
	if e := callError(t, owner, "", "groups/remove", wire.GroupRequest{ID: gid}); !strings.Contains(e, "provider") {
		t.Fatal(e)
	}
	call(t, owner, "", "groups/setRole", wire.GroupRoleSet{Group: gid, Role: new("admin")})
	scimDo(t, base, token, "PATCH", "/Groups/"+gid, patchOp(map[string]any{"op": "add", "path": "members", "value": []any{map[string]any{"value": rajID}}}))
	p.waitFor(func() bool { q := p.s.records.Person(rajID); return q.IsAdmin() && len(q.RoleFrom) == 1 }, "Raj an admin by the group")
	if e := callError(t, owner, "", "people/setRole", wire.PersonRoleRequest{User: rajID, Role: wire.UserRoleMember}); !strings.Contains(e, "organisation's groups") {
		t.Fatal(e)
	}
	// Out of the group: a member again.
	scimDo(t, base, token, "PATCH", "/Groups/"+gid, patchOp(map[string]any{"op": "remove", "path": "members[value eq \"" + rajID + "\"]"}))
	p.waitFor(func() bool { q := p.s.records.Person(rajID); return !q.IsAdmin() && len(q.RoleFrom) == 0 }, "Raj a member again")
	// Raj is the only admin: the owner made a member. Taking Raj out keeps him an admin.
	scimDo(t, base, token, "PATCH", "/Groups/"+gid, patchOp(map[string]any{"op": "add", "path": "members", "value": []any{map[string]any{"value": rajID}}}))
	p.waitFor(func() bool { return p.s.records.Person(rajID).IsAdmin() }, "Raj an admin again")
	call(t, owner, "", "people/setRole", wire.PersonRoleRequest{User: p.s.localOwner(), Role: wire.UserRoleMember})
	if status, _ := scimDo(t, base, token, "PATCH", "/Groups/"+gid, patchOp(map[string]any{"op": "replace", "path": "members", "value": []any{}})); status != 200 {
		t.Fatal(status)
	}
	if q := p.s.records.Person(rajID); !q.IsAdmin() {
		t.Fatal("the last admin was taken away")
	}
	if g := p.s.records.Group(gid); len(g.Members) != 0 {
		t.Fatal("the group did not change")
	}
}

// T019, Q1 A, FR-024: an org sign-in's refresh token is kept sealed; invalid_grant
// suspends; with the provider down, keys renew for 7 days after the last good check.
func TestRefreshChecksFindLeavers(t *testing.T) {
	t.Parallel()
	prov := signintest.NewProvider(t, "RS256", "")
	p, _, owner, _ := orgPlane(t, prov, nil)
	addOrg(t, owner, prov, wire.OrgProviderJoinAnyone)
	b := &browser{prov: prov}
	prov.SignInAs(signintest.Claims{"sub": "00u-kim", "email": "kim@acme.test", "name": "Kim"})
	kim, err := p.signInOrg(t, b)
	if err != nil {
		t.Fatal(err)
	}
	id := personOf(t, p, kim)
	if q := prov.Authorized(); !strings.Contains(q[len(q)-1].Get("scope"), "offline_access") {
		t.Fatal(q[len(q)-1])
	}
	object, _ := p.store.Get(context.Background(), refreshKey(id, "acme-okta"))
	if object == nil {
		t.Fatal("no refresh token kept")
	}
	for _, issued := range prov.Issued() {
		if strings.HasPrefix(issued, "rt-") && storeHolds(t, p.store, issued) {
			t.Fatal("the store holds a refresh token in the clear")
		}
	}
	si := p.s.signIns
	if got := si.checkRefresh(context.Background(), id, "acme-okta"); got != refreshGood {
		t.Fatal(got)
	}
	// A day on, the provider is down: within the grace, keys renew.
	si.org.skew.Store(int64(25 * time.Hour))
	si.cfg.HTTP = &http.Client{Transport: failing{}}
	if !si.refreshAllows(context.Background(), id) {
		t.Fatal("refused within the grace")
	}
	si.org.skew.Store(int64(8 * 24 * time.Hour))
	if si.refreshAllows(context.Background(), id) {
		t.Fatal("renewed 8 days after the last good check")
	}
	// The provider answers again, refusing the refresh: Kim is suspended by refresh.
	si.cfg.HTTP = prov.HTTP()
	prov.InvalidGrant.Store(true)
	si.checkRefreshes(context.Background())
	if q := p.s.records.Person(id); !q.IsSuspended() || q.Suspended.By != "refresh" {
		t.Fatalf("%+v", q.Suspended)
	}
}

type failing struct{}

func (failing) RoundTrip(*http.Request) (*http.Response, error) { return nil, io.ErrUnexpectedEOF }

// T020, FR-023: 5,000 users and 500 groups; SCIM answers within 200 ms at p95.
func TestSCIMAtSize(t *testing.T) {
	// Not parallel (#2512): it holds a wall-clock limit, which other tests running beside it would make flaky.
	if testing.Short() {
		t.Skip("5,000 users")
	}
	p, _, _, token, base := scimPlane(t, wire.OrgProviderJoinScim)
	// The time each takes is measured here, not the rate the provider keeps to.
	p.s.scimServer.PerSecond = 100000
	ctx := context.Background()
	var ids []string
	for i := range 5000 {
		id := records.NewPersonID()
		now := records.Now()
		person := records.Person{ID: id, Name: "User " + strconv.Itoa(i), Kind: records.KindPerson, Role: records.RoleMember, Provisioned: true,
			SCIM: &records.PersonSCIM{Provider: "acme-okta", UserName: "user" + strconv.Itoa(i) + "@acme.test", ExternalID: "00u-" + strconv.Itoa(i),
				Active: true, Created: &now}}
		if err := p.s.records.SavePerson(ctx, person); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	for i := range 500 {
		id := records.NewPersonID()
		members := ids[i*10 : i*10+10]
		if _, err := p.s.records.ChangeGroup(ctx, id, func(*records.Group) (*records.Group, error) {
			return &records.Group{ID: id, Name: "Group " + strconv.Itoa(i), Members: members,
				Source: &records.GroupSource{SCIM: "acme-okta", DisplayName: "Group " + strconv.Itoa(i)}}, nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	var took []time.Duration
	for i := range 200 {
		start := time.Now()
		var status int
		switch i % 4 {
		case 0:
			status, _ = scimDo(t, base, token, "GET", "/Users?filter="+urlEscape(`userName eq "user`+strconv.Itoa(i*20)+`@acme.test"`), nil)
		case 1:
			status, _ = scimDo(t, base, token, "GET", "/Users?startIndex="+strconv.Itoa(i*20)+"&count=100", nil)
		case 2:
			status, _ = scimDo(t, base, token, "GET", "/Groups?excludedAttributes=members&filter="+urlEscape(`displayName eq "Group `+strconv.Itoa(i)+`"`), nil)
		case 3:
			status, _ = scimDo(t, base, token, "PATCH", "/Users/"+ids[i], patchOp(map[string]any{"op": "replace", "path": "displayName", "value": "Renamed"}))
		}
		if status != 200 {
			t.Fatal(i, status)
		}
		took = append(took, time.Since(start))
	}
	sort.Slice(took, func(i, j int) bool { return took[i] < took[j] })
	if p95 := took[len(took)*95/100]; p95 > 200*time.Millisecond {
		t.Fatalf("p95 %v", p95)
	}
}

// #2424: a sync sends every user and group again, mostly as they were. A write that
// changes nothing keeps nothing and tells nobody; one that changes something tells once.
func TestSCIMNoOpWritesTellNobody(t *testing.T) {
	t.Parallel()
	p, owner, _, token, base := scimPlane(t, wire.OrgProviderJoinScim)
	raj := newUser("raj@acme.test", "00u-raj")
	_, made := scimDo(t, base, token, "POST", "/Users", raj)
	rajID := made["id"].(string)
	group := map[string]any{"displayName": "Engineers", "members": []any{map[string]any{"value": rajID}}}
	_, g := scimDo(t, base, token, "POST", "/Groups", group)
	gid := g["id"].(string)
	told := func(method string) int {
		n := 0
		settle := time.After(500 * time.Millisecond)
		for {
			select {
			case note := <-owner.Notes:
				if note.Method == method {
					n++
				}
			case <-settle:
				return n
			}
		}
	}
	told("")
	personRev, groupRev := p.s.records.Person(rajID).Rev, p.s.records.Group(gid).Rev
	if status, out := scimDo(t, base, token, "PUT", "/Users/"+rajID, raj); status != 200 || out["id"] != rajID {
		t.Fatal(status, out)
	}
	if status, out := scimDo(t, base, token, "PUT", "/Groups/"+gid, group); status != 200 || out["id"] != gid {
		t.Fatal(status, out)
	}
	if n := told("control/peopleChanged") + told("control/groupsChanged"); n != 0 {
		t.Fatalf("a write that changed nothing told %d times", n)
	}
	if p.s.records.Person(rajID).Rev != personRev || p.s.records.Group(gid).Rev != groupRev {
		t.Fatal("a write that changed nothing was kept")
	}
	raj["displayName"] = "Raj K"
	if status, _ := scimDo(t, base, token, "PUT", "/Users/"+rajID, raj); status != 200 {
		t.Fatal(status)
	}
	if n := told("control/peopleChanged"); n != 1 {
		t.Fatalf("a changed user told %d times", n)
	}
	group["displayName"] = "Engineering"
	if status, _ := scimDo(t, base, token, "PUT", "/Groups/"+gid, group); status != 200 {
		t.Fatal(status)
	}
	if n := told("control/groupsChanged"); n != 1 {
		t.Fatalf("a changed group told %d times", n)
	}
}

// #2425: a million made-up bearers keep nothing; a live token is still kept, and one
// address that sends many made-up ones is answered 429 with no token read.
func TestSCIMUnknownBearersKeepNothing(t *testing.T) {
	t.Parallel()
	p, _, _, token, base := scimPlane(t, wire.OrgProviderJoinScim)
	st := p.s.scimTokens
	ctx := context.Background()
	if _, ok := st.Authenticate(ctx, token, "192.0.2.1"); !ok {
		t.Fatal("the live token was refused")
	}
	for i := range 1_000_000 {
		if _, ok := st.Authenticate(ctx, "agscim_"+strconv.Itoa(i), "192.0.2.1"); ok {
			t.Fatal("a made-up bearer was taken")
		}
	}
	st.mu.Lock()
	kept := len(st.read)
	st.mu.Unlock()
	if kept != 1 {
		t.Fatalf("%d tokens kept, want only the live one", kept)
	}
	if _, ok := st.Authenticate(ctx, token, "192.0.2.1"); !ok {
		t.Fatal("the live token was refused after the crowd")
	}
	limited := 0
	for i := range 30 {
		if status, _ := scimDo(t, base, "agscim_made-up-"+strconv.Itoa(i), "GET", "/Users", nil); status == http.StatusTooManyRequests {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("30 made-up tokens from one address were all read")
	}
}

// #2430: a first sync, Okta's GET with a filter then a POST for each user, reads every
// person from the store for none of them, and its median call does not grow with N.
// -scim-sync sets N: go test -run TestAFirstSync -args -scim-sync=5000.
var scimSyncUsers = flag.Int("scim-sync", 1000, "how many users TestAFirstSyncListsNoPeoplePerUser syncs")

func TestAFirstSyncListsNoPeoplePerUser(t *testing.T) {
	// Not parallel (#2512): it holds a wall-clock limit, which other tests running beside it would make flaky.
	n := *scimSyncUsers
	p, _, _, _, _ := scimPlane(t, wire.OrgProviderJoinScim)
	counted := &countingStore{Store: p.s.records.Store}
	p.s.records.Store = counted
	d := scimDirectory{p.s}
	ctx := context.Background()
	c := scim.Caller{Provider: "acme-okta"}
	var took []time.Duration
	for i := range n {
		userName := fmt.Sprintf("user%05d@acme.example", i)
		start := time.Now()
		found, err := d.Users(ctx, c.Provider, func(u scim.User) bool { return u.UserName == userName })
		if err != nil || len(found) != 0 {
			t.Fatalf("GET %s: %v %v", userName, found, err)
		}
		if _, err := d.CreateUser(ctx, c, scim.User{UserName: userName, ExternalID: fmt.Sprintf("ext-%05d", i), Active: true}); err != nil {
			t.Fatalf("POST %s: %v", userName, err)
		}
		took = append(took, time.Since(start))
	}
	slices.Sort(took)
	lists := counted.lists.Load()
	t.Logf("a first sync of %d users: median GET+POST %v, slowest %v, %d store Lists", n, took[n/2], took[n-1], lists)
	// Some Lists come from elsewhere as people change (a reload, a group's roles); one per
	// user is the cost this bounds.
	if lists > int64(n/10) {
		t.Fatalf("%d store Lists for %d users", lists, n)
	}
}
