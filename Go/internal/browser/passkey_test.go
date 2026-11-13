package browser

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/cdproto/webauthn"
	"github.com/chromedp/chromedp"
)

// makePasskey and usePasskey are a site's sign-up and sign-in with a passkey, on localhost
// (a secure context with no certificate): they say the credential's id.
const makePasskey = `navigator.credentials.create({publicKey: {
	rp: {name: "Test", id: "localhost"},
	user: {id: new Uint8Array([7]), name: "agent", displayName: "Agent"},
	challenge: new Uint8Array(16), pubKeyCredParams: [{type: "public-key", alg: -7}],
	authenticatorSelection: {residentKey: "required", userVerification: "required"}, timeout: 10000}}).then((c) => c.id)`

const usePasskey = `navigator.credentials.get({publicKey: {
	rpId: "localhost", challenge: new Uint8Array(16), userVerification: "required", timeout: 10000}}).then((c) => c.id)`

// TestARealSoftwarePasskey starts the Chromium in AGENTS_TEST_CHROMIUM with WebAuthn
// (#4085): a page makes a passkey on a tab's software authenticator, and changed hears it;
// put back on a new authenticator, as a later sign-in does, a page signs in with it, and
// changed hears its new sign count.
func TestARealSoftwarePasskey(t *testing.T) {
	exe := os.Getenv("AGENTS_TEST_CHROMIUM")
	if exe == "" {
		t.Skip("set AGENTS_TEST_CHROMIUM to a Chromium to start a real one")
	}
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("<!doctype html><title>Passkey</title>"))
	}))
	defer site.Close()
	address := strings.Replace(site.URL, "127.0.0.1", "localhost", 1)
	p, err := launchChromium(exe, t.TempDir(), os.Environ(), mode{webauthn: true})
	if err != nil {
		t.Fatal(err)
	}
	defer p.stop()
	tabs, err := FollowTabs(p.endpoint, func(_, _ target.ID) {}, func(target.ID) {}, func() {})
	if err != nil {
		t.Fatal(err)
	}
	defer tabs.Close()
	tab, err := tabs.Open(address)
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var heard []*webauthn.Credential
	changed := func(c *webauthn.Credential) { mu.Lock(); heard = append(heard, c); mu.Unlock() }
	waitFor := func(n int) *webauthn.Credential {
		t.Helper()
		for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
			mu.Lock()
			if len(heard) >= n {
				c := heard[n-1]
				mu.Unlock()
				return c
			}
			mu.Unlock()
		}
		t.Fatalf("heard %d passkeys, not %d", len(heard), n)
		return nil
	}
	if err := tabs.Passkey(tab, nil, changed); err != nil {
		t.Fatal(err)
	}
	if !tabs.HasPasskey(tab) {
		t.Fatal("the tab has no passkey")
	}
	page, cancel := chromedp.NewContext(tabs.root, chromedp.WithTargetID(tab))
	defer cancel()
	// The first call attaches, with no time limit, as it ties the tab's context to its own.
	if err := chromedp.Do(page); err != nil {
		t.Fatal(err)
	}
	run := func(js string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(page, 20*time.Second)
		defer cancel()
		id, err := chromedp.Run(ctx, chromedp.Evaluate[string](js, chromedp.EvalAwaitPromise))
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	made := run(makePasskey)
	saved := waitFor(1)
	if saved.RpID != "localhost" || len(saved.PrivateKey) == 0 || !saved.IsResidentCredential {
		t.Fatalf("the passkey heard is not whole: %+v", saved.RpID)
	}
	// A later sign-in: a new authenticator, with the kept passkey put back.
	tabs.NoPasskey(tab)
	if tabs.HasPasskey(tab) {
		t.Fatal("the passkey is still there")
	}
	if err := tabs.Passkey(tab, []*webauthn.Credential{saved}, changed); err != nil {
		t.Fatal(err)
	}
	if used := run(usePasskey); used != made {
		t.Fatalf("signed in with %q, not the passkey made, %q", used, made)
	}
	asserted := waitFor(2)
	if !bytes.Equal(asserted.CredentialID, saved.CredentialID) || asserted.SignCount <= saved.SignCount {
		t.Fatalf("the sign-in's sign count is %v, after %v", asserted.SignCount, saved.SignCount)
	}
}
