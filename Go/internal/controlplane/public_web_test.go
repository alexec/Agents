package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// The page on the control plane's own domain (#1459): served by its listener at its
// address's origin, with the loopback page's policy. A browser pairs there by a browser
// code and connects with its key, bound to that origin; a window's code and key are
// refused there, and a browser's over a window's socket. Forgotten, it is refused.
func TestABrowserThroughThePublicPage(t *testing.T) {
	t.Parallel()
	dist := t.TempDir()
	index := []byte("<html></html>")
	sum := sha256.Sum256(index)
	os.WriteFile(filepath.Join(dist, "index.html"), index, 0o644)
	os.WriteFile(filepath.Join(dist, "MANIFEST"), []byte("agents-web 1\nout "+hex.EncodeToString(sum[:])+" Web/dist/index.html\n"), 0o644)

	port := freePort(t)
	// Caddy's side: the listener is plain HTTP on loopback, and the address is the domain's.
	address := "https://agents.test:8444"
	page := "https://agents.test:8444"
	direct := "http://127.0.0.1:" + itoa(port)
	s, err := New(Config{Store: store.NewMemory(), PrivateKey: controllink.NewPrivateKey(), URL: address, Bind: "127.0.0.1",
		Port: port, Name: "Test plane", PublicWeb: dist})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	defer s.Stop()

	// The files, at the page's own name only, with the page's policy.
	get := func(host, path string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.Host = host
		w := httptest.NewRecorder()
		s.serveHTTP(w, r)
		return w
	}
	if w := get("agents.test:8444", "/"); w.Code != http.StatusOK || w.Body.String() != string(index) ||
		!strings.Contains(w.Header().Get("Content-Security-Policy"), "connect-src wss://agents.test:8444;") ||
		!strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-src 'none'") ||
		w.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatalf("%d %v", w.Code, w.Header())
	}
	if w := get("rebound.example", "/index.html"); w.Code != http.StatusMisdirectedRequest || w.Body.Len() != 0 {
		t.Fatalf("%d", w.Code)
	}
	if w := get("agents.test:8444", "/sandbox.html"); w.Code != http.StatusNotFound {
		t.Fatalf("%d", w.Code)
	}
	if w := get("agents.test:8444", "/healthz"); w.Code != http.StatusOK {
		t.Fatalf("%d", w.Code)
	}

	pair := func(browser bool, kind, origin string) (string, []byte, error) {
		shown, err := s.Codes().Issue(context.Background(), false, browser, time.Minute)
		if err != nil {
			t.Fatal(err)
		}
		code, _ := controllink.ParseCode(shown.Text)
		var l *controllink.Lines
		at := origin
		if origin == "" {
			l, err = controllink.Dial(context.Background(), direct, "")
			at = address
		} else {
			l, err = dialBrowser(direct, origin)
		}
		if err != nil {
			return "", nil, err
		}
		defer l.Close()
		if _, _, err := answerHello(l, controllink.Identity{Kind: 'p', ID: code.ID()}, controllink.CodeKey(code.Secret), at, "browser"); err != nil {
			return "", nil, err
		}
		private := controllink.NewPrivateKey()
		public, _ := controllink.PublicKey(private)
		id := records.NewUUID()
		params, _ := json.Marshal(wire.ClientAnnounce{ID: wire.UUID(id), PublicKey: public, Name: "Chrome", Kind: wire.ClientKind(kind)})
		l.Write(context.Background(), `{"jsonrpc":"2.0","id":1,"method":"clients/announce","params":`+string(params)+`}`)
		line, err := l.Read(context.Background())
		if err != nil {
			return "", nil, err
		}
		if !strings.Contains(line, `"result"`) {
			return "", nil, fmt.Errorf("%s", line)
		}
		return id, private, nil
	}
	// A window's code is no good on the page, and a browser's code is no good for a window.
	if _, _, err := pair(false, records.KindBrowser, page); err == nil || !strings.Contains(err.Error(), "Get one from Add a Browser") {
		t.Fatal(err)
	}
	if _, _, err := pair(true, records.KindIPhone, ""); err == nil || !strings.Contains(err.Error(), "That code is for a browser.") {
		t.Fatal(err)
	}
	// A page at another origin is a window's socket, so its browser code is refused too.
	if _, _, err := pair(true, records.KindBrowser, "https://elsewhere.example"); err == nil {
		t.Fatal("a browser code worked from another origin")
	}
	id, private, err := pair(true, records.KindBrowser, page)
	if err != nil {
		t.Fatal(err)
	}
	if c := s.Records().Client(id); c == nil || c.Name != "Chrome on the web" || c.Kind != records.KindBrowser {
		t.Fatal(c)
	}

	public, _ := controllink.PublicKey(s.cfg.PrivateKey)
	key, _ := controllink.ClientKey(private, public, id)
	connect := func(origin string) error {
		var l *controllink.Lines
		var err error
		at := origin
		if origin == "" {
			l, err = controllink.Dial(context.Background(), direct, "")
			at = address
		} else {
			l, err = dialBrowser(direct, origin)
		}
		if err != nil {
			return err
		}
		defer l.Close()
		_, _, err = answerHello(l, controllink.Identity{Kind: 'c', ID: id}, key, at, "browser")
		return err
	}
	// Its key proves itself on the page, bound to the page's origin…
	if err := connect(page); err != nil {
		t.Fatal(err)
	}
	// …and not over a window's socket.
	if err := connect(""); err == nil {
		t.Fatal("a browser's key worked without the page")
	}
	// control/status says where the page is.
	if s.page == nil || s.page.Address() != page+"/" {
		t.Fatal(s.page)
	}
	// Forgotten, it is refused.
	if err := s.methods.forget(context.Background(), id, 0); err != nil {
		t.Fatal(err)
	}
	if err := connect(page); err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatal(err)
	}
}

// With a second name (#1484), the page frames the views' sandbox proxy there, and
// control/status says where it is, for the page to draw views through.
func TestThePublicPagesViewsName(t *testing.T) {
	t.Parallel()
	dist := t.TempDir()
	index := []byte("<html></html>")
	sum := sha256.Sum256(index)
	os.WriteFile(filepath.Join(dist, "index.html"), index, 0o644)
	os.WriteFile(filepath.Join(dist, "MANIFEST"), []byte("agents-web 1\nout "+hex.EncodeToString(sum[:])+" Web/dist/index.html\n"), 0o644)
	s, err := New(Config{Store: store.NewMemory(), PrivateKey: controllink.NewPrivateKey(), URL: "https://agents.test:8444",
		Bind: "127.0.0.1", Port: freePort(t), Name: "Test plane", PublicWeb: dist, PublicViews: "https://views.test:8444"})
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Host = "agents.test:8444"
	w := httptest.NewRecorder()
	s.serveHTTP(w, r)
	if !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-src https://views.test:8444;") {
		t.Fatal(w.Header())
	}
	if status := s.methods.status(Caller{}); status.PublicViews == nil || *status.PublicViews != "https://views.test:8444" {
		t.Fatal(status.PublicViews)
	}
}
