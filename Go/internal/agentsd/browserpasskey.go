package agentsd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/cdproto/webauthn"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// browser_passkey (#4085): a software passkey for an agent's own account on a site that
// takes only a passkey. The machine's browser has no WebAuthn of its own (#4084); this tool
// starts it again with WebAuthn (browser.Machine.Passkeys) and puts a software authenticator
// on each of the session's tabs (browser/passkey.go). The passkeys are kept as one of the
// person's secrets (Settings ▸ Secrets), as capture_secret keeps a token: put back from it
// when the agent signs in, and saved to it each time a page makes one or signs in with one
// (its sign count goes up each time, and a site may refuse one that goes back). The agent
// never sees a key: it is told how many passkeys there are, for which site. Using a kept
// secret that has Ask before use waits on a person's approval for the site, as fill_secret
// does (#4015). The passkey holds for the session's tabs, and the ones they open, until the
// agent takes it away, its tabs all close, or the browser stops.

const passkeyName = "browser_passkey"

// passkeyTool is browser_passkey as tools/list sends it, with the browser tools.
var passkeyTool = json.RawMessage(`{"name":"browser_passkey","title":"Use a software passkey",` +
	`"description":"Give this session's tabs in the browser a software passkey, for one of your own accounts on a site that takes only a passkey (or for a sudo step that asks for one). ` +
	`Use a password and a TOTP code where the site takes them. The passkey is a security key in the app with no dialog and no person: it says yes at once. ` +
	`It is kept as one of the person's secrets (Settings ▸ Secrets), one secret per account. When the secret is set, its passkeys are put back, so the site's passkey sign-in works; ` +
	`when it is not, the first passkey the site makes (Add a passkey, Set up a passkey) is saved as it. Each sign-in saves it again. You are told how many passkeys there are, never a key. ` +
	`Call it before you open the page: the first call starts the browser again with passkeys on, which closes its tabs (sign-ins are kept). ` +
	`It holds for this session's tabs and the ones they open, until you call it with off, the tabs close or the browser stops. ` +
	`Record the account's second factor as a software passkey with manage_accounts.",` +
	`"inputSchema":{"type":"object","properties":{` +
	`"secret":{"type":"string","description":"The secret that keeps the passkeys, e.g. GITHUB_AGENT_PASSKEY: letters, digits and underscores."},` +
	`"site":{"type":"string","description":"The site's domain, its passkeys' relying party, e.g. github.com. Passkeys for another site are not used or saved."},` +
	`"off":{"type":"boolean","description":"True takes the passkey off this session's tabs. The secret stays."}},` +
	`"required":["secret"],"additionalProperties":false},` +
	`"annotations":{"title":"Use a software passkey","readOnlyHint":false,"destructiveHint":false,"openWorldHint":true}}`)

// sessionPasskey is a session's software passkey: the secret that keeps it, for its site.
type sessionPasskey struct {
	secret, site string
}

// passkeySecret is a passkey secret's value: its site and its passkeys, as CDP has them.
type passkeySecret struct {
	Site     string                 `json:"site"`
	Passkeys []*webauthn.Credential `json:"passkeys"`
}

// passkeyCheck is the refusal for a call that cannot go on, before the lease: a bad name
// or site, no home, or a secret that is not passkeys.
func (d *Daemon) passkeyCheck(agent wire.UUID, args map[string]json.RawMessage) string {
	name := strings.TrimSpace(argString(args, "secret"))
	if !secretAskName.MatchString(name) {
		return "Nothing was done: `secret` is the name that keeps the passkeys, letters, digits and underscores, e.g. GITHUB_AGENT_PASSKEY."
	}
	if string(args["off"]) == "true" {
		return ""
	}
	if passkeySite(argString(args, "site")) == "" {
		return "Nothing was done: `site` is the site's domain, e.g. github.com."
	}
	if d.personalHome() == "" {
		return "Nothing was done: this machine has no personal home to keep secrets in."
	}
	if d.releasePending(agent, name) {
		// Read only after a signed approval: checked then.
		return ""
	}
	if v, ok, _ := d.localSecret(agent, name); ok && v != "" {
		if _, err := parsePasskeys(v); err != nil {
			return "Nothing was done: " + name + " is set, but it is not passkeys. Give another name."
		}
	}
	return ""
}

// passkeySite is a site as a relying party: its host, in lower case, with no scheme, port
// or path. "" for none.
func passkeySite(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	if _, rest, ok := strings.Cut(s, "://"); ok {
		s = rest
	}
	s, _, _ = strings.Cut(s, "/")
	if i := strings.LastIndex(s, ":"); i >= 0 {
		s = s[:i]
	}
	s = strings.Trim(s, ".")
	if s == "" || strings.ContainsAny(s, " @") {
		return ""
	}
	return s
}

// parsePasskeys reads a passkey secret: the app's own value, or one passkey as CDP says it
// (the file scripts/okta-signin.mjs keeps), so a passkey kept that way can move into a secret.
func parsePasskeys(v string) (passkeySecret, error) {
	var s passkeySecret
	if err := json.Unmarshal([]byte(v), &s); err == nil && s.Passkeys != nil {
		return s, nil
	}
	var one webauthn.Credential
	if err := json.Unmarshal([]byte(v), &one); err != nil || len(one.CredentialID) == 0 || len(one.PrivateKey) == 0 {
		return passkeySecret{}, fmt.Errorf("not passkeys")
	}
	return passkeySecret{Site: one.RpID, Passkeys: []*webauthn.Credential{&one}}, nil
}

// forSite is whether a passkey with relying party rpID is site's: the same, or site is under it.
func forSite(rpID, site string) bool {
	rpID = strings.ToLower(rpID)
	return rpID != "" && (rpID == site || strings.HasSuffix(site, "."+rpID))
}

// usePasskey gives agent's session the passkey, or takes it away, and says what it did.
// The browser started again with WebAuthn before this (driveBrowser).
func (d *Daemon) usePasskey(agent wire.UUID, args map[string]json.RawMessage) (string, bool) {
	name := strings.TrimSpace(argString(args, "secret"))
	key := sessionKey(agent)
	if string(args["off"]) == "true" {
		d.tabsMu.Lock()
		t, own := d.tabs, append([]target.ID(nil), d.ownTabs[key]...)
		delete(d.passkeys, key)
		d.tabsMu.Unlock()
		if t != nil {
			for _, tab := range own {
				t.NoPasskey(tab)
			}
		}
		return "This session's tabs have no software passkey now. " + name + " is kept.", false
	}
	site := passkeySite(argString(args, "site"))
	home := d.personalHome()
	if secretIsSet(home, name) || d.isSessionSecret(agent, name) {
		if d.secretIsSealed(agent, name) {
			waiting, err := d.approveSecretUse(agent, name, wire.SecretUseFill, site)
			if err != nil {
				return "Nothing was done: " + err.Error(), true
			}
			if waiting != "" {
				return waiting, false
			}
		}
	}
	kept, refusal := d.keptPasskeys(agent, name, site)
	if refusal != "" {
		return refusal, true
	}
	// The tab @playwright/mcp just opened for the session is told to agentsd a moment later.
	for i := 0; i < 20 && d.followsTabs() && d.sessionTab(agent) == ""; i++ {
		time.Sleep(100 * time.Millisecond)
	}
	d.tabsMu.Lock()
	t := d.tabs
	if t == nil {
		d.tabsMu.Unlock()
		return "The browser isn't running: call browser_navigate first, then browser_passkey.", true
	}
	if d.passkeys == nil {
		d.passkeys = map[wire.UUID]*sessionPasskey{}
	}
	p := &sessionPasskey{secret: name, site: site}
	d.passkeys[key] = p
	own := append([]target.ID(nil), d.ownTabs[key]...)
	d.tabsMu.Unlock()
	var failed []string
	for _, tab := range own {
		if err := t.Passkey(tab, kept, d.passkeySaver(agent, p)); err != nil {
			failed = append(failed, err.Error())
		}
	}
	if len(own) == 0 || len(failed) == len(own) {
		d.tabsMu.Lock()
		if d.passkeys[key] == p {
			delete(d.passkeys, key)
		}
		d.tabsMu.Unlock()
		if len(own) == 0 {
			return "This session has no tab in the browser: call browser_navigate first, then browser_passkey.", true
		}
		return "No passkey was put on this session's tabs: " + strings.Join(failed, "; "), true
	}
	if len(kept) > 0 {
		d.secretRead(agent, name, wire.SecretOperationUseFill, site)
		return fmt.Sprintf("This session's tabs have a software passkey for %s now: %s, with %s, put back. "+
			"Use the site's passkey sign-in; the passkey says yes at once.", site, name, plural(len(kept), "passkey", "passkeys")), false
	}
	return fmt.Sprintf("This session's tabs have a software passkey for %s now, with no passkey on it yet. "+
		"Add one on the site (Add a passkey, Set up a passkey): it is saved as %s, and the site's passkey sign-in works after that.", site, name), false
}

// keptPasskeys are the passkeys for site in the secret name, none when it is not set.
func (d *Daemon) keptPasskeys(agent wire.UUID, name, site string) ([]*webauthn.Credential, string) {
	v, ok, expired := d.localSecret(agent, name)
	if !ok || v == "" {
		if expired {
			return nil, name + " was for this session only and has expired. Give another name to make a new passkey."
		}
		return nil, ""
	}
	s, err := parsePasskeys(v)
	if err != nil {
		return nil, "Nothing was done: " + name + " is set, but it is not passkeys. Give another name."
	}
	var out []*webauthn.Credential
	for _, c := range s.Passkeys {
		if c != nil && forSite(c.RpID, site) {
			out = append(out, c)
		}
	}
	if len(out) == 0 && len(s.Passkeys) > 0 {
		return nil, fmt.Sprintf("Nothing was done: %s keeps passkeys for %s, not %s. Give the site they are for, or another name.", name, s.Site, site)
	}
	return out, ""
}

// passkeyMu keeps two saves of one secret from losing each other's passkey.
var passkeyMu sync.Mutex

// passkeySaver saves each passkey a page makes or signs in with on one of p's tabs to p's
// secret: a new one is added, a known one (by its id) is replaced, with its sign count.
// A passkey for another site is not saved.
func (d *Daemon) passkeySaver(agent wire.UUID, p *sessionPasskey) func(*webauthn.Credential) {
	return func(c *webauthn.Credential) {
		if c == nil || len(c.PrivateKey) == 0 {
			return
		}
		if !forSite(c.RpID, p.site) {
			log.Printf("browser: a page made a passkey for %s on a tab whose passkey is for %s; it was not saved", c.RpID, p.site)
			return
		}
		passkeyMu.Lock()
		defer passkeyMu.Unlock()
		s := passkeySecret{Site: p.site}
		v, had, _ := d.localSecret(agent, p.secret)
		if had && v != "" {
			if kept, err := parsePasskeys(v); err == nil {
				s = kept
			}
		}
		replaced := false
		for i, k := range s.Passkeys {
			if k != nil && bytes.Equal(k.CredentialID, c.CredentialID) {
				s.Passkeys[i], replaced = c, true
			}
		}
		if !replaced {
			s.Passkeys = append(s.Passkeys, c)
		}
		b, err := json.Marshal(s)
		if err != nil {
			log.Printf("browser: couldn't keep a passkey for %s: %v", p.site, err)
			return
		}
		// A new secret is an agent's write: Ask before use on (#4014). One that is there
		// keeps the flag the person gave it.
		home := d.personalHome()
		ask := !had || home == "" || isSealedSecret(home, p.secret)
		if err := d.saveSecret(p.secret, string(b), ask); err != nil {
			log.Printf("browser: couldn't save a passkey for %s as %s: %v", p.site, p.secret, err)
			return
		}
		if replaced {
			log.Printf("browser: saved %s again: a sign-in on %s", p.secret, p.site)
		} else {
			log.Printf("browser: saved a new passkey for %s as %s", p.site, p.secret)
		}
	}
}

// giveTabPasskey gives a tab that is now owner's the passkey of owner's session: a sign-in
// window that one of its tabs opened, say.
func (d *Daemon) giveTabPasskey(owner wire.UUID, tab target.ID) {
	d.tabsMu.Lock()
	t, p := d.tabs, d.passkeys[sessionKey(owner)]
	d.tabsMu.Unlock()
	if t == nil || p == nil {
		return
	}
	// Away from the browser's own events, which must not wait on a call to it.
	go func() {
		kept, refusal := d.keptPasskeys(owner, p.secret, p.site)
		if refusal != "" {
			log.Printf("browser: no passkey on a new tab: %s", refusal)
			return
		}
		if err := t.Passkey(tab, kept, d.passkeySaver(owner, p)); err != nil {
			log.Printf("browser: couldn't give a tab its session's passkey: %v", err)
		}
	}()
}
