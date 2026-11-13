package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/chromedp/cdproto/webauthn"
)

// browser_passkey (#4085): listed with the browser tools, refused for a bad name or site,
// and its passkeys kept in a secret that never says a key.

func TestPasskeyIsListedWithTheBrowserTools(t *testing.T) {
	m, _, _ := fillSetUp(t, nil)
	_, list := m.post("tools/list", nil, 2)
	if !strings.Contains(string(list["result"]), `"name":"browser_passkey"`) {
		t.Fatal("no browser_passkey")
	}
	if got := appToolMethod(passkeyName); got != "browser/passkey" {
		t.Fatal(got)
	}
}

func TestPasskeyRefusesABadNameSiteOrSecret(t *testing.T) {
	m, _, d := fillSetUp(t, map[string]string{"MAIL_PASSWORD": "hunter2secret"})
	for i, c := range []struct {
		args map[string]any
		want string
	}{
		{map[string]any{"secret": "no spaces", "site": "github.com"}, "`secret` is the name"},
		{map[string]any{"secret": "GITHUB_AGENT_PASSKEY"}, "`site` is the site's domain"},
		{map[string]any{"secret": "GITHUB_AGENT_PASSKEY", "site": "https://"}, "`site` is the site's domain"},
		{map[string]any{"secret": "MAIL_PASSWORD", "site": "github.com"}, "not passkeys"},
	} {
		r := m.browserTool(2+i, passkeyName, c.args)
		if !r.IsError || !strings.Contains(replyText(r), c.want) || strings.Contains(replyText(r), "hunter2") {
			t.Fatalf("%v: %+v", c.args, r)
		}
	}
	if d.browser.Running() {
		t.Fatal("a refused call started the browser")
	}
}

func TestPasskeyOffNeedsNoSite(t *testing.T) {
	m, _, _ := fillSetUp(t, nil)
	r := m.browserTool(2, passkeyName, map[string]any{"secret": "GITHUB_AGENT_PASSKEY", "off": true})
	if r.IsError || !strings.Contains(replyText(r), "no software passkey now") {
		t.Fatalf("%+v", r)
	}
}

func TestPasskeySite(t *testing.T) {
	for in, want := range map[string]string{
		"github.com":                    "github.com",
		" GitHub.com ":                  "github.com",
		"https://github.com/settings/x": "github.com",
		"login.example.com:8443":        "login.example.com",
		"":                              "",
		"a b":                           "",
	} {
		if got := passkeySite(in); got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
	if !forSite("github.com", "github.com") || !forSite("example.com", "login.example.com") ||
		forSite("example.com", "notexample.com") || forSite("", "github.com") || forSite("login.example.com", "example.com") {
		t.Fatal("forSite")
	}
}

// madeKey is a passkey as CDP says it, with a made-up key: these tests never sign.
func madeKey(id byte, rp string, count float64) *webauthn.Credential {
	return &webauthn.Credential{CredentialID: []byte{id}, RpID: rp, PrivateKey: []byte("private key " + string('a'+rune(id))),
		IsResidentCredential: true, UserHandle: []byte{7}, SignCount: count}
}

func TestParsePasskeysReadsTheAppsValueAndOneCDPPasskey(t *testing.T) {
	own, _ := json.Marshal(passkeySecret{Site: "github.com", Passkeys: []*webauthn.Credential{madeKey(1, "github.com", 3)}})
	if s, err := parsePasskeys(string(own)); err != nil || s.Site != "github.com" || len(s.Passkeys) != 1 || s.Passkeys[0].SignCount != 3 {
		t.Fatal(s, err)
	}
	// scripts/okta-signin.mjs keeps one passkey, as WebAuthn.getCredentials says it.
	one, _ := json.Marshal(madeKey(2, "agents.okta.com", 1))
	if s, err := parsePasskeys(string(one)); err != nil || s.Site != "agents.okta.com" || len(s.Passkeys) != 1 {
		t.Fatal(s, err)
	}
	for _, bad := range []string{"hunter2secret", `{"number":"4242"}`, `{"site":"x"}`, `[]`} {
		if _, err := parsePasskeys(bad); err == nil {
			t.Fatal(bad)
		}
	}
}

// Each passkey a page makes is added, each sign-in replaces its passkey with its new sign
// count, and a passkey for another site is not kept. A new secret has Ask before use; one
// the person turned it off for keeps it off.
func TestThePasskeySaverKeepsEachPasskeyAndItsSignCount(t *testing.T) {
	_, _, d := fillSetUp(t, nil)
	p := &sessionPasskey{secret: "GITHUB_AGENT_PASSKEY", site: "github.com"}
	save := d.passkeySaver("", p)
	kept := func() passkeySecret {
		t.Helper()
		v, ok, _ := d.localSecret("", p.secret)
		if !ok {
			t.Fatal("not saved")
		}
		s, err := parsePasskeys(v)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	save(madeKey(1, "github.com", 0))
	if s := kept(); s.Site != "github.com" || len(s.Passkeys) != 1 {
		t.Fatal(s)
	}
	if !isSealedSecret(d.personalHome(), p.secret) {
		t.Fatal("an agent's new passkey has no Ask before use")
	}
	save(madeKey(1, "github.com", 1))
	save(madeKey(2, "github.com", 0))
	save(madeKey(3, "gitlab.com", 0))
	s := kept()
	if len(s.Passkeys) != 2 || s.Passkeys[0].SignCount != 1 || s.Passkeys[1].CredentialID[0] != 2 {
		t.Fatalf("%+v", s.Passkeys)
	}
	// The person turned Ask before use off: a sign-in's save keeps it off.
	v, _, _ := d.localSecret("", p.secret)
	if err := d.saveSecret(p.secret, v, false); err != nil {
		t.Fatal(err)
	}
	save(madeKey(1, "github.com", 2))
	if isSealedSecret(d.personalHome(), p.secret) {
		t.Fatal("a sign-in turned Ask before use on again")
	}
	if got, _ := d.keptPasskeys("", p.secret, "github.com"); len(got) != 2 || got[0].SignCount != 2 {
		t.Fatalf("%+v", got)
	}
	if _, refusal := d.keptPasskeys("", p.secret, "gitlab.com"); !strings.Contains(refusal, "keeps passkeys for github.com, not gitlab.com") {
		t.Fatal(refusal)
	}
	if got, refusal := d.keptPasskeys("", "NOT_SET_YET", "github.com"); got != nil || refusal != "" {
		t.Fatal(got, refusal)
	}
}

func TestPasskeyNeedsTheBrowsersTabs(t *testing.T) {
	m, _, d := fillSetUp(t, nil)
	r := m.browserTool(2, passkeyName, map[string]any{"secret": "GITHUB_AGENT_PASSKEY", "site": "github.com"})
	if !r.IsError || !strings.Contains(replyText(r), "call browser_navigate first") {
		t.Fatalf("%+v", r)
	}
	if len(d.passkeys) != 0 {
		t.Fatal("a passkey kept with no tabs")
	}
}
