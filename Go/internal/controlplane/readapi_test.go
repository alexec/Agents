package controlplane

// The read API (#2019, #1804 decision 4): tokens an admin makes, the reports they read, and
// nothing else; revoked, rate-limited and bounded.

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

func sendUsage(t *testing.T, p *plane, host string, rows ...wire.UsageRollupRow) {
	t.Helper()
	now := time.Now().UTC()
	r := wire.UsageRollup{Hours: []wire.UsageRollupPeriod{{At: now.Format(usageHourLayout), Rows: rows}},
		Days: []wire.UsageRollupPeriod{{At: now.Format(usageDayLayout), Rows: rows}}}
	params, _ := json.Marshal(r)
	if _, err := p.s.methods.HostSaid(host, "usage/rollup", params); err != nil {
		t.Fatal(err)
	}
}

func readReports(t *testing.T, p *plane, token, query string) (int, string) {
	t.Helper()
	r, _ := http.NewRequest(http.MethodGet, p.url+readAPIPath+query, nil)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body)
}

func TestTheReadAPIReadsTheReportsWithAToken(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	p := startPlane(t, st, controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	sendUsage(t, p, owner.member.Host, wire.UsageRollupRow{Folder: "agents", Runtime: "claude",
		Cost: map[string]float64{"USD": 2.5}, InputTokens: 100, Turns: 1})

	// Only an admin makes one; its value is shown once, and only its hash is kept.
	if e := callError(t, bea.window, "", "readApi/make", wire.ReadTokenMake{Name: "Looker"}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}
	var made wire.ReadTokenMade
	json.Unmarshal(call(t, admin, "", "readApi/make", wire.ReadTokenMake{Name: "Looker"}), &made)
	if !strings.HasPrefix(made.Value, readTokenPrefix) || made.URL != p.url+readAPIPath {
		t.Fatalf("%+v", made)
	}
	keys, _ := st.List(t.Context(), readTokensPrefix)
	if len(keys) != 1 {
		t.Fatalf("%v", keys)
	}
	if o, _ := st.Get(t.Context(), keys[0].Key); strings.Contains(string(o.Data), made.Value) {
		t.Fatal("the token's value was kept")
	}

	// No token, a wrong one, or another kind: refused.
	for _, token := range []string{"", readTokenPrefix + "nope", "agscim_x"} {
		if code, _ := readReports(t, p, token, ""); code != http.StatusUnauthorized {
			t.Fatalf("%q: %d", token, code)
		}
	}
	code, body := readReports(t, p, made.Value, "?range=day")
	var report wire.UsageReport
	if code != http.StatusOK || json.Unmarshal([]byte(body), &report) != nil || len(report.Rows) != 1 || report.Rows[0].Cost["USD"] != 2.5 {
		t.Fatalf("%d %s", code, body)
	}
	if code, body := readReports(t, p, made.Value, "?range=day&format=csv"); code != http.StatusOK || !strings.HasPrefix(body, "at,person") {
		t.Fatalf("%d %s", code, body)
	}
	if code, body := readReports(t, p, made.Value, "?range=day&format=jsonl"); code != http.StatusOK || strings.Count(body, "\n") != 1 {
		t.Fatalf("%d %s", code, body)
	}
	if code, _ := readReports(t, p, made.Value, "?range=year"); code != http.StatusBadRequest {
		t.Fatal(code)
	}
	// It reads nothing else: SCIM refuses it.
	r, _ := http.NewRequest(http.MethodGet, p.url+"/scim/v2/Users", nil)
	r.Header.Set("Authorization", "Bearer "+made.Value)
	if resp, err := http.DefaultClient.Do(r); err != nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("SCIM took a read token: %v %v", resp, err)
	} else {
		resp.Body.Close()
	}

	// Revoked: refused at once.
	var state wire.ReadAPI
	json.Unmarshal(call(t, admin, "", "readApi/revoke", wire.ReadTokenRevoke{ID: made.Token.ID}), &state)
	if len(state.Tokens) != 1 || state.Tokens[0].Revoked == nil || state.Otlp != nil {
		t.Fatalf("%+v", state)
	}
	if code, _ := readReports(t, p, made.Value, ""); code != http.StatusUnauthorized {
		t.Fatal(code)
	}
}

// A token works only while its maker is an admin, and asks at most its rate.
func TestAReadTokenIsLimited(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleAdmin)
	var made wire.ReadTokenMade
	json.Unmarshal(call(t, bea.window, "", "readApi/make", wire.ReadTokenMake{Name: "Bea's BI"}), &made)
	limited := false
	for range readBurst + 5 {
		if code, _ := readReports(t, p, made.Value, ""); code == http.StatusTooManyRequests {
			limited = true
			break
		}
	}
	if !limited {
		t.Fatal("never limited")
	}
	call(t, admin, "", "people/setRole", wire.PersonRoleRequest{User: bea.id, Role: wire.UserRoleMember})
	p.s.readAPI.mu.Lock()
	p.s.readAPI.read, p.s.readAPI.rates = nil, nil
	p.s.readAPI.mu.Unlock()
	if code, _ := readReports(t, p, made.Value, ""); code != http.StatusUnauthorized {
		t.Fatalf("a member's token read: %d", code)
	}
}

// At most mostLiveReadTokens are live.
func TestReadTokensAreBounded(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, admin := p.client("Owner's window")
	for range mostLiveReadTokens {
		call(t, admin, "", "readApi/make", wire.ReadTokenMake{Name: "BI"})
	}
	if e := callError(t, admin, "", "readApi/make", wire.ReadTokenMake{Name: "one more"}); !strings.Contains(e, "Revoke one first") {
		t.Fatal(e)
	}
	if e := callError(t, admin, "", "readApi/make", wire.ReadTokenMake{Name: " "}); !strings.Contains(e, "name") {
		t.Fatal(e)
	}
}

// A last-use stamp written between revoke's read and its write does not fail the revoke
// (#2830), and the stamp is kept.
func TestARevokeWinsOverALastUseStamp(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	p := startPlane(t, st, controllink.NewPrivateKey())
	_, admin := p.client("Owner's window")
	var made wire.ReadTokenMade
	json.Unmarshal(call(t, admin, "", "readApi/make", wire.ReadTokenMake{Name: "Looker"}), &made)
	all, etags, err := p.s.readAPI.list(t.Context())
	if err != nil || len(all) != 1 {
		t.Fatal(all, err)
	}
	used := all[0]
	used.LastUse = &wire.SCIMTokenUse{At: wire.DateOf(time.Now())}
	data, _ := json.Marshal(used)
	if _, err := st.Put(t.Context(), readTokenKey(used.SHA256), data, store.Matching(etags[used.ID])); err != nil {
		t.Fatal(err)
	}
	stamp := &wire.OrgRouteStamp{At: wire.DateOf(time.Now())}
	if revoked, err := p.s.readAPI.markRevoked(t.Context(), all[0], etags[used.ID], stamp); err != nil || !revoked {
		t.Fatal(revoked, err)
	}
	after, _, _ := p.s.readAPI.list(t.Context())
	if len(after) != 1 || after[0].Revoked == nil || after[0].LastUse == nil {
		t.Fatalf("%+v", after)
	}
	// Revoked again by another copy's stale read: nothing to do.
	if revoked, err := p.s.readAPI.markRevoked(t.Context(), all[0], etags[used.ID], stamp); err != nil || revoked {
		t.Fatal(revoked, err)
	}
	if code, _ := readReports(t, p, made.Value, ""); code != http.StatusUnauthorized {
		t.Fatal(code)
	}
}
