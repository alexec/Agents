package browser

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"

	"github.com/chromedp/cdproto/network"
)

// fakeStore is a running Chromium's cookies, and the origins whose storage was cleared.
type fakeStore struct {
	jar     []*network.Cookie
	cleared []string
}

func (s *fakeStore) cookies(context.Context) ([]*network.Cookie, error) {
	return append([]*network.Cookie(nil), s.jar...), nil
}
func (s *fakeStore) setCookies(_ context.Context, cs []*network.Cookie) error {
	s.jar = append(s.jar, cs...)
	return nil
}
func (s *fakeStore) clearOrigin(_ context.Context, origin string) error {
	s.cleared = append(s.cleared, origin)
	return nil
}
func (s *fakeStore) clearAll(context.Context) error { s.jar = nil; return nil }

func withStore(t *testing.T, f *fake, store *fakeStore) {
	t.Helper()
	launch := f.m.launch
	f.m.launch = func(exe, profile string, env []string) (*process, error) {
		p, err := launch(exe, profile, env)
		if p != nil {
			p.store = store
		}
		return p, err
	}
}

func jar(domains ...string) []*network.Cookie {
	var cs []*network.Cookie
	for i, d := range domains {
		cs = append(cs, &network.Cookie{Name: "c" + string(rune('a'+i)), Value: "v", Domain: d, Path: "/"})
	}
	return cs
}

func TestBeforeTheDownloadThereAreNoSitesAndNothingStarts(t *testing.T) {
	f := newFake(t)
	sites, err := f.m.Sites(context.Background())
	if err != nil || len(sites) != 0 || f.m.Installed() || f.m.DownloadBytes() != 0 {
		t.Fatal(sites, err)
	}
	if err := f.m.Clear(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	if f.installs.Load() != 0 || f.launches.Load() != 0 {
		t.Fatal("Settings ▸ Browser downloaded or started the browser")
	}
}

func TestSitesGroupsCookiesBySite(t *testing.T) {
	f := newFake(t)
	store := &fakeStore{jar: jar(".github.com", "api.github.com", "github.com", ".gitlab.com", "localhost", "foo.co.uk")}
	withStore(t, f, store)
	mustStart(t, f.m)
	f.m.Stop()
	if !f.m.Installed() || f.m.DownloadBytes() == 0 {
		t.Fatal("the download is not seen", f.m.DownloadBytes())
	}
	// Not running: reading the sites starts it again.
	sites, err := f.m.Sites(context.Background())
	if err != nil || !f.m.Running() {
		t.Fatal(err)
	}
	want := []Site{{"github.com", 3}, {"foo.co.uk", 1}, {"gitlab.com", 1}, {"localhost", 1}}
	if !reflect.DeepEqual(sites, want) {
		t.Fatalf("%+v", sites)
	}
}

func TestClearOneSiteKeepsTheOthers(t *testing.T) {
	f := newFake(t)
	store := &fakeStore{jar: jar(".github.com", "api.github.com", ".gitlab.com")}
	withStore(t, f, store)
	mustStart(t, f.m)
	if err := f.m.Clear(context.Background(), "github.com"); err != nil {
		t.Fatal(err)
	}
	if len(store.jar) != 1 || store.jar[0].Domain != ".gitlab.com" {
		t.Fatalf("%+v", store.jar)
	}
	sort.Strings(store.cleared)
	if want := []string{"http://api.github.com", "http://github.com", "https://api.github.com", "https://github.com"}; !reflect.DeepEqual(store.cleared, want) {
		t.Fatal(store.cleared)
	}
	// A site with no cookies clears nothing.
	store.cleared = nil
	if err := f.m.Clear(context.Background(), "example.com"); err != nil || len(store.jar) != 1 || store.cleared != nil {
		t.Fatal(err, store.jar, store.cleared)
	}
}

func TestClearAll(t *testing.T) {
	f := newFake(t)
	store := &fakeStore{jar: jar(".github.com", ".gitlab.com")}
	withStore(t, f, store)
	mustStart(t, f.m)
	if err := f.m.Clear(context.Background(), ""); err != nil || len(store.jar) != 0 || len(store.cleared) != 4 {
		t.Fatal(err, store.jar, store.cleared)
	}
}

func TestDownloadBytesCountsEveryFile(t *testing.T) {
	f := newFake(t)
	dir := filepath.Join(f.m.Binaries, "chromium-1200", "chrome-linux")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, size := range map[string]int{"chrome": 1000, "libGLESv2.so": 24} {
		if err := os.WriteFile(filepath.Join(dir, name), make([]byte, size), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if got := f.m.DownloadBytes(); got != 1024 || !f.m.Installed() {
		t.Fatal(got)
	}
}

// TestARealChromiumsCookies reads, sets and clears cookies on the Chromium in
// AGENTS_TEST_CHROMIUM, when it is set, over the browser's own CDP connection.
func TestARealChromiumsCookies(t *testing.T) {
	exe := os.Getenv("AGENTS_TEST_CHROMIUM")
	if exe == "" {
		t.Skip("set AGENTS_TEST_CHROMIUM to a Chromium to start a real one")
	}
	p, err := launchChromium(exe, t.TempDir(), os.Environ())
	if err != nil {
		t.Fatal(err)
	}
	defer p.stop()
	ctx := context.Background()
	store := p.store
	if err := store.setCookies(ctx, []*network.Cookie{
		{Name: "a", Value: "1", Domain: ".github.com", Path: "/", Secure: true, Expires: 4102444800},
		{Name: "b", Value: "2", Domain: "gitlab.com", Path: "/", Session: true},
	}); err != nil {
		t.Fatal(err)
	}
	got, err := store.cookies(ctx)
	if err != nil || len(got) != 2 {
		t.Fatal(got, err)
	}
	if err := store.clearOrigin(ctx, "https://github.com"); err != nil {
		t.Fatal(err)
	}
	if err := store.clearAll(ctx); err != nil {
		t.Fatal(err)
	}
	if got, err := store.cookies(ctx); err != nil || len(got) != 0 {
		t.Fatal(got, err)
	}
}
