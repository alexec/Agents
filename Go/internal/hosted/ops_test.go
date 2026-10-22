package hosted

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// scrape reads the metrics as from remote.
func scrape(s *Service, remote string) (int, string) {
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	req.RemoteAddr = remote
	rec := httptest.NewRecorder()
	s.Metrics().ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

// #2226 FR-042: the metrics answer loopback and MetricsFrom only, never through the
// service's own port, and count accounts, sign-ups, refusals and requests.
func TestMetrics(t *testing.T) {
	st := store.NewMemory()
	s, newBrowser := startWith(t, Config{Store: st, SignUp: SignUpOpen,
		MetricsFrom: []netip.Prefix{netip.MustParsePrefix("172.30.62.1/32")}})
	b := newBrowser()
	b.signIn("good")
	acc, _ := s.accounts.byGitHub(context.Background(), 42)
	if err := (Admin{Store: st}).Suspend(context.Background(), acc.ID, "spam"); err != nil {
		t.Fatal(err)
	}
	// The sweep stops its copy, as within a minute.
	s.sweepAccounts(context.Background())
	if res, _ := b.get("https://" + acc.ID + "." + domain + "/readyz"); res.StatusCode != http.StatusForbidden {
		t.Fatal(res.StatusCode)
	}
	if _, err := (Admin{Store: st}).Block(context.Background(), "7", "spam"); err != nil {
		t.Fatal(err)
	}
	newBrowser().signIn("u.7.bot.400")

	for _, remote := range []string{"127.0.0.1:4000", "[::1]:4000", "172.30.62.1:4000"} {
		if code, _ := scrape(s, remote); code != http.StatusOK {
			t.Fatal(remote, code)
		}
	}
	for _, remote := range []string{"172.30.62.250:4000", "203.0.113.5:4000", "nonsense"} {
		if code, _ := scrape(s, remote); code != http.StatusForbidden {
			t.Fatal(remote, code)
		}
	}
	_, text := scrape(s, "127.0.0.1:4000")
	for _, want := range []string{
		`agents_hosted_accounts{plan="free",state="suspended"} 1`,
		`agents_hosted_accounts{plan="pro",state="active"} 0`,
		"agents_hosted_waitlist 0",
		"agents_hosted_copies_running 0",
		`agents_hosted_signups_total{kind="account"} 1`,
		`agents_hosted_refusals_total{kind="blocked"} 1`,
		`agents_hosted_refusals_total{kind="suspended"} 1`,
		`agents_hosted_requests_total{status="303"}`,
		`agents_hosted_requests_total{status="403"}`,
		"# TYPE agents_hosted_signups_total counter",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("no %s in\n%s", want, text)
		}
	}
	// Not through the service's own port, which Caddy passes.
	if res, _ := b.get("https://" + domain + "/metrics"); res.StatusCode != http.StatusNotFound {
		t.Fatal(res.StatusCode)
	}
}

// A limit's refusal is counted by the limit.
func TestMetricsCountLimits(t *testing.T) {
	var s Service
	l := limited(plans[PlanFree])
	l.onRefuse = s.metrics.refused
	ctx := context.Background()
	for _, key := range []string{"v1/hosts/a.json", "v1/hosts/b.json", "v1/hosts/c.json"} {
		_, _ = l.Put(ctx, key, []byte(`{}`), store.Absent)
	}
	if s.metrics.refusals["machines"] != 1 {
		t.Fatal(s.metrics.refusals)
	}
}

// #2226 FR-041: a backup of one account restores only that account's records, and only
// once it is suspended; a deleted account comes back whole.
func TestBackupAndRestoreOneAccount(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory()
	now := time.Now()
	a := Admin{Store: st, Now: func() time.Time { return now }}
	ana, _, _ := a.accounts().make(ctx, GitHubID{ID: 1, Login: "ana"})
	bo, _, _ := a.accounts().make(ctx, GitHubID{ID: 2, Login: "bo"})
	for _, id := range []string{ana.ID, bo.ID} {
		for _, k := range []string{"v1/hosts/a.json", "v1/clients/b.json", "v1/keys/control.sealed"} {
			if _, err := accountStore(st, id).Put(ctx, k, []byte(id+k), store.Absent); err != nil {
				t.Fatal(err)
			}
		}
	}
	dir := t.TempDir()
	done, err := a.Backup(ctx, dir, nil)
	if err != nil || len(done) != 2 {
		t.Fatal(done, err)
	}
	if info, err := os.Stat(filepath.Join(dir, ana.ID, "records.jsonl")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatal(info, err)
	}

	// Both change after the backup.
	for _, id := range []string{ana.ID, bo.ID} {
		p := accountStore(st, id)
		_, _ = p.Put(ctx, "v1/hosts/a.json", []byte("changed"), store.Always)
		_ = p.Delete(ctx, "v1/clients/b.json")
		_, _ = p.Put(ctx, "v1/hosts/new.json", []byte("new"), store.Absent)
	}
	if _, err := a.Restore(ctx, dir, ana.ID); err == nil || !strings.Contains(err.Error(), "suspend it first") {
		t.Fatal("restored a running account:", err)
	}
	if err := a.Suspend(ctx, ana.ID, "restoring"); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Restore(ctx, dir, ana.ID); err == nil || !strings.Contains(err.Error(), "try again in a minute") {
		t.Fatal("restored over a copy that may still run:", err)
	}
	now = now.Add(2 * time.Minute)
	if n, err := a.Restore(ctx, dir, ana.ID); err != nil || n != 3 {
		t.Fatal(n, err)
	}
	same := func(id, key, want string) {
		t.Helper()
		o, _ := accountStore(st, id).Get(ctx, key)
		if want == "" && o != nil || want != "" && (o == nil || string(o.Data) != want) {
			t.Fatalf("%s %s: %v", id, key, o)
		}
	}
	same(ana.ID, "v1/hosts/a.json", ana.ID+"v1/hosts/a.json")
	same(ana.ID, "v1/clients/b.json", ana.ID+"v1/clients/b.json")
	same(ana.ID, "v1/hosts/new.json", "")
	// The other account is as it was.
	same(bo.ID, "v1/hosts/a.json", "changed")
	same(bo.ID, "v1/clients/b.json", "")
	same(bo.ID, "v1/hosts/new.json", "new")
	if acc, _ := a.accounts().get(ctx, ana.ID); acc == nil || acc.Suspended == nil {
		t.Fatal("the restore changed the account's record")
	}

	// A deleted account comes back, record and link; not when its user has another.
	if err := a.accounts().remove(ctx, bo); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Restore(ctx, dir, bo.ID); err != nil {
		t.Fatal(err)
	}
	if acc, _ := a.accounts().byGitHub(ctx, 2); acc == nil || acc.ID != bo.ID {
		t.Fatal("the deleted account did not come back", acc)
	}
	same(bo.ID, "v1/hosts/a.json", bo.ID+"v1/hosts/a.json")
	_ = a.accounts().remove(ctx, bo)
	again, _, _ := a.accounts().make(ctx, GitHubID{ID: 2, Login: "bo"})
	if _, err := a.Restore(ctx, dir, bo.ID); err == nil || !strings.Contains(err.Error(), again.ID) {
		t.Fatal("restored over the user's new account:", err)
	}
	if _, err := a.Restore(ctx, dir, "zzzzzzzzzz"); err == nil {
		t.Fatal("restored an account with no backup")
	}

	// The operator deletes a suspended account only.
	if err := a.Delete(ctx, again.ID); err == nil || !strings.Contains(err.Error(), "suspend it first") {
		t.Fatal(err)
	}
	_ = a.Suspend(ctx, again.ID, "deleting")
	now = now.Add(2 * time.Minute)
	_, _ = accountStore(st, again.ID).Put(ctx, "v1/hosts/x.json", []byte("x"), store.Absent)
	if err := a.Delete(ctx, again.ID); err != nil {
		t.Fatal(err)
	}
	if keys, _ := accountStore(st, again.ID).List(ctx, ""); len(keys) != 0 {
		t.Fatal("records left:", keys)
	}
	if acc, _ := a.accounts().byGitHub(ctx, 2); acc != nil {
		t.Fatal("the account is still there")
	}
}
