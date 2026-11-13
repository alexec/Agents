package browser

import (
	"context"
	"encoding/json"
	"time"

	"github.com/chromedp/cdproto/cdp"
	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/cdproto/webauthn"
	"github.com/chromedp/chromedp"
)

// A software passkey for an agent's own accounts (#4085): Chromium's virtual authenticator,
// set on a tab over CDP, as a browser's developer tools do. It is a security key with no
// person behind it: it says yes to each request at once, with user verification. Chromium
// drops a CDP session's authenticators when the session detaches, so Tabs keeps one session
// on each tab that has one, for as long as it holds, as Emulate does. The browser must
// start with WebAuthn on for a page to reach it (Machine.Passkeys).

// passkeyOptions are the authenticator's: a platform passkey (CTAP2, internal), which
// keeps a resident key and verifies its user, as Touch ID would.
var passkeyOptions = webauthn.VirtualAuthenticatorOptions{
	Protocol:                    webauthn.AuthenticatorProtocolCtap2,
	Ctap2version:                webauthn.Ctap2versionCtap21,
	Transport:                   webauthn.AuthenticatorTransportInternal,
	HasResidentKey:              true,
	HasUserVerification:         true,
	IsUserVerified:              true,
	AutomaticPresenceSimulation: true,
}

// passkeyTab is one tab's session that holds its authenticator.
type passkeyTab struct {
	ctx    context.Context
	cancel context.CancelFunc
}

// Passkey puts a software authenticator on tab, with creds on it, and calls changed with
// each passkey that a page makes on it, and with each one a page signs in with (its sign
// count is one more then). A tab that has one gets a new one. changed runs on its own
// goroutine, one call at a time. The tab closing, NoPasskey or Close ends it.
func (t *Tabs) Passkey(tab target.ID, creds []*webauthn.Credential, changed func(*webauthn.Credential)) error {
	t.NoPasskey(tab)
	ctx, cancel := chromedp.NewContext(t.root, chromedp.WithTargetID(tab), chromedp.WithDetachOnCancel())
	p := &passkeyTab{ctx: ctx, cancel: cancel}
	t.mu.Lock()
	if t.passkeys == nil {
		t.passkeys = map[target.ID]*passkeyTab{}
	}
	t.passkeys[tab] = p
	t.mu.Unlock()
	// The first call attaches, with no time limit, as it ties the tab's context to its own.
	if err := chromedp.Do(ctx); err != nil {
		t.forgetPasskey(tab, p)
		return err
	}
	if err := t.authenticate(ctx, creds, changed); err != nil {
		t.forgetPasskey(tab, p)
		return err
	}
	return nil
}

// authenticate adds the authenticator on the session of ctx, puts creds on it, and
// follows what the page does with them.
func (t *Tabs) authenticate(ctx context.Context, creds []*webauthn.Credential, changed func(*webauthn.Credential)) error {
	// Heard before the authenticator is there, so no passkey a page makes at once is lost.
	seen := make(chan *webauthn.Credential, 16)
	err := chromedp.Listen(ctx, func(ev any) {
		var c *webauthn.Credential
		switch e := ev.(type) {
		case *webauthn.EventCredentialAdded:
			c = e.Credential
		case *webauthn.EventCredentialAsserted:
			c = e.Credential
		case *webauthn.EventCredentialUpdated:
			c = e.Credential
		}
		if c == nil {
			return
		}
		select {
		case seen <- c:
		case <-ctx.Done():
		}
	})
	if err != nil {
		return err
	}
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case c := <-seen:
				if changed != nil {
					changed(c)
				}
			}
		}
	}()
	call, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	// No UI: the virtual authenticator answers, and no dialog waits for a person.
	if _, err := chromedp.Call(call, webauthn.Enable, webauthn.EnableParams{EnableUI: new(false)}); err != nil {
		return err
	}
	added, err := chromedp.Call(call, webauthn.AddVirtualAuthenticator, webauthn.AddVirtualAuthenticatorParams{Options: &passkeyOptions})
	if err != nil {
		return err
	}
	for _, c := range creds {
		if _, err := chromedp.Call(call, addCredential,
			addCredentialParams{AuthenticatorID: added.AuthenticatorID, Credential: credentialToAdd(c)}); err != nil {
			return err
		}
	}
	return nil
}

// addCredential is WebAuthn.addCredential with a credential that has only the fields this
// Chromium takes: cdproto's sends generateCmtgKeyOnNextOperation always, and Chromium
// refuses any CMTG field ("CMTG is not supported by this authenticator").
var addCredential = cdp.Command[addCredentialParams, cdp.Empty]{Method: webauthn.CommandAddCredential}

type addCredentialParams struct {
	AuthenticatorID webauthn.AuthenticatorID `json:"authenticatorId"`
	Credential      map[string]any           `json:"credential"`
}

// credentialToAdd is c as addCredential sends it: its JSON, with no CMTG field.
func credentialToAdd(c *webauthn.Credential) map[string]any {
	b, _ := json.Marshal(c)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	for _, k := range []string{"cmtgKeys", "activeCmtgKeyIndex", "generateCmtgKeyOnNextOperation"} {
		delete(m, k)
	}
	return m
}

// NoPasskey takes tab's authenticator away, with the passkeys on it.
func (t *Tabs) NoPasskey(tab target.ID) { t.forgetPasskey(tab, nil) }

// HasPasskey is whether tab has a software authenticator now.
func (t *Tabs) HasPasskey(tab target.ID) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.passkeys[tab] != nil
}

// forgetPasskey drops tab's session, when it is still p (nil: whichever it has). Detached,
// its authenticator goes with it.
func (t *Tabs) forgetPasskey(tab target.ID, p *passkeyTab) {
	t.mu.Lock()
	had := t.passkeys[tab]
	if had != nil && (p == nil || had == p) {
		delete(t.passkeys, tab)
	} else {
		had = nil
	}
	t.mu.Unlock()
	if had != nil {
		had.cancel()
	}
}
