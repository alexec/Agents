package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Agents Host updates itself (#2178): the release is downloaded and checked, put in place
// only between turns, and refused when its signature or checksum is wrong.

type selfUpdateRig struct {
	u        *selfUpdater
	app      string
	turns    atomic.Int64
	restarts atomic.Int64
	mu       sync.Mutex
	told     []wire.SelfUpdate
}

// newSelfUpdateRig is an Agents Host.app at 0.11.0 in a folder of its own, and a release
// 0.12.0 served as GitHub serves one.
func newSelfUpdateRig(t *testing.T, zip []byte) *selfUpdateRig {
	t.Helper()
	dir := t.TempDir()
	r := &selfUpdateRig{app: filepath.Join(dir, "Agents Host.app")}
	os.MkdirAll(r.app, 0o755)
	os.WriteFile(filepath.Join(r.app, "which"), []byte("old"), 0o644)
	sum := sha256.Sum256(zip)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/v0.12.0/SHA256SUMS":
			w.Write([]byte(hex.EncodeToString(sum[:]) + "  Agents-Host-0.12.0.zip\n"))
		case "/v0.12.0/Agents-Host-0.12.0.zip":
			w.Write(zip)
		default:
			http.NotFound(w, req)
		}
	}))
	t.Cleanup(srv.Close)
	t.Setenv("AGENTS_RELEASE_DOWNLOADS", srv.URL)
	u := newSelfUpdater(filepath.Join(t.TempDir(), selfUpdateFile), r.app, "0.11.0")
	u.ctx, u.pause = t.Context(), 5*time.Millisecond
	u.turns = func() int { return int(r.turns.Load()) }
	u.unpack = func(zip, out string) error {
		next := filepath.Join(out, "Agents Host.app")
		os.MkdirAll(next, 0o755)
		return os.WriteFile(filepath.Join(next, "which"), []byte("new"), 0o644)
	}
	u.version = func(string) (string, error) { return "0.12.0", nil }
	u.verify = func(next, running string) error { return nil }
	u.restart = func() error { r.restarts.Add(1); return nil }
	u.tell = func(s wire.SelfUpdate) { r.mu.Lock(); r.told = append(r.told, s); r.mu.Unlock() }
	r.u = u
	return r
}

func (r *selfUpdateRig) which(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(r.app, "which"))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func (r *selfUpdateRig) until(t *testing.T, state wire.SelfUpdateState) wire.SelfUpdate {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if s := r.u.Status(); s.State == state {
			return s
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("never %s: %+v", state, r.u.Status())
	return wire.SelfUpdate{}
}

// restarted waits for the restart, the update's last step.
func (r *selfUpdateRig) restarted(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for r.restarts.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
}

func (r *selfUpdateRig) leftovers() []string {
	m, _ := filepath.Glob(filepath.Join(filepath.Dir(r.app), ".Agents Host.update-*"))
	return m
}

func TestSelfUpdateWaitsForTheTurnToEnd(t *testing.T) {
	r := newSelfUpdateRig(t, []byte("zip"))
	r.turns.Store(1)
	r.u.Named("0.12.0")
	r.until(t, wire.SelfUpdateStateWaiting)
	time.Sleep(50 * time.Millisecond)
	if r.which(t) != "old" || r.restarts.Load() != 0 {
		t.Fatal("a running turn was cut: the copy was changed or restarted")
	}
	r.turns.Store(0)
	r.until(t, wire.SelfUpdateStateRestarting)
	r.restarted(t)
	if r.which(t) != "new" || r.restarts.Load() != 1 {
		t.Fatalf("not updated: %s, %d restarts", r.which(t), r.restarts.Load())
	}
	// The old copy waits beside it until the next start takes it away.
	if len(r.leftovers()) != 1 {
		t.Fatalf("%v", r.leftovers())
	}
	cleanSelfUpdates(r.app)
	if len(r.leftovers()) != 0 {
		t.Fatalf("%v", r.leftovers())
	}
}

func TestSelfUpdateRefusesABadSignature(t *testing.T) {
	r := newSelfUpdateRig(t, []byte("zip"))
	r.u.verify = func(next, running string) error { return errors.New("not signed by team 6T4RVD5724") }
	r.u.Named("0.12.0")
	s := r.until(t, wire.SelfUpdateStateFailed)
	if s.Message == nil || !strings.Contains(*s.Message, "signature") {
		t.Fatalf("%+v", s)
	}
	if r.which(t) != "old" || r.restarts.Load() != 0 || len(r.leftovers()) != 0 {
		t.Fatalf("a badly signed copy was installed, or its download kept: %s %v", r.which(t), r.leftovers())
	}
}

func TestSelfUpdateRefusesABadChecksum(t *testing.T) {
	r := newSelfUpdateRig(t, []byte("zip"))
	var verified atomic.Bool
	r.u.verify = func(string, string) error { verified.Store(true); return nil }
	// The server's sum is for "zip"; the bytes are something else.
	r.u.fetch = func(ctx context.Context, url string, w io.Writer, limit int64) error {
		if strings.HasSuffix(url, ".zip") {
			_, err := w.Write([]byte("tampered"))
			return err
		}
		return fetchTo(ctx, url, w, limit)
	}
	r.u.Named("0.12.0")
	s := r.until(t, wire.SelfUpdateStateFailed)
	if s.Message == nil || !strings.Contains(*s.Message, "checksum") || verified.Load() || r.which(t) != "old" {
		t.Fatalf("%+v", s)
	}
}

func TestSelfUpdateTakesOnlyANewerRelease(t *testing.T) {
	r := newSelfUpdateRig(t, []byte("zip"))
	for _, v := range []string{"0.11.0", "0.10.3", "0.12.0-dev.1+gabc", "nonsense"} {
		r.u.Named(v)
		if s := r.u.Status(); s.State != wire.SelfUpdateStateUpToDate || s.Release == nil || *s.Release != v {
			t.Fatalf("%s: %+v", v, s)
		}
	}
	if r.which(t) != "old" {
		t.Fatal("changed")
	}
}

func TestSelfUpdateOffIsKept(t *testing.T) {
	r := newSelfUpdateRig(t, []byte("zip"))
	if _, err := r.u.Set(wire.SelfUpdateSet{AutoUpdate: false}); err != nil {
		t.Fatal(err)
	}
	r.u.Named("0.12.0")
	if s := r.u.Status(); s.State != wire.SelfUpdateStateOff || s.AutoUpdate {
		t.Fatalf("%+v", s)
	}
	if again := newSelfUpdater(r.u.file, r.app, "0.11.0"); again.Status().State != wire.SelfUpdateStateOff {
		t.Fatalf("not kept: %+v", again.Status())
	}
	// Turned on, the release named before is taken up.
	r.u.Set(wire.SelfUpdateSet{AutoUpdate: true})
	r.until(t, wire.SelfUpdateStateRestarting)
	r.restarted(t)
}

func TestSelfUpdateTurnedOffWhileWaitingChangesNothing(t *testing.T) {
	r := newSelfUpdateRig(t, []byte("zip"))
	r.turns.Store(1)
	r.u.Named("0.12.0")
	r.until(t, wire.SelfUpdateStateWaiting)
	r.u.Set(wire.SelfUpdateSet{AutoUpdate: false})
	r.until(t, wire.SelfUpdateStateOff)
	deadline := time.Now().Add(5 * time.Second)
	for len(r.leftovers()) != 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if r.which(t) != "old" || len(r.leftovers()) != 0 || r.restarts.Load() != 0 {
		t.Fatal("changed after it was turned off")
	}
}

func TestSelfUpdateNeverAsksForAnAdministrator(t *testing.T) {
	r := newSelfUpdateRig(t, []byte("zip"))
	r.u.writable = func(string) error { return os.ErrPermission }
	r.u.Named("0.12.0")
	s := r.u.Status()
	if s.State != wire.SelfUpdateStateCannot || s.Message == nil || !strings.Contains(*s.Message, "home folder") {
		t.Fatalf("%+v", s)
	}
	if dev := newSelfUpdater(filepath.Join(t.TempDir(), selfUpdateFile), r.app, "0.12.0-dev.3+gabc"); dev.Status().State != wire.SelfUpdateStateCannot {
		t.Fatalf("a development build would update: %+v", dev.Status())
	}
}

func TestEnclosingApp(t *testing.T) {
	if got := enclosingApp("/Users/a/Applications/Agents Host.app/Contents/Helpers/agentsd"); got != "/Users/a/Applications/Agents Host.app" {
		t.Fatal(got)
	}
	if got := enclosingApp("/usr/local/bin/agentsd"); got != "" {
		t.Fatal(got)
	}
	if sumFor("ABC  x\n"+strings.Repeat("a", 64)+"  Agents-Host-1.0.0.zip\n", "Agents-Host-1.0.0.zip") != strings.Repeat("a", 64) {
		t.Fatal("sum")
	}
}
