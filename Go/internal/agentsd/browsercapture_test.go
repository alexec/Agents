package agentsd

import (
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/skillcatalog"
)

// capture_secret (#4028): the shown value is saved and hidden, and never said.

func TestCaptureSecretIsListedWithTheBrowserTools(t *testing.T) {
	m, _, _ := fillSetUp(t, nil)
	_, list := m.post("tools/list", nil, 2)
	if !strings.Contains(string(list["result"]), `"name":"capture_secret"`) {
		t.Fatal("no capture_secret")
	}
	if got := appToolMethod(captureSecretName); got != "secrets/capture" {
		t.Fatal(got)
	}
}

func TestCaptureSecretSavesTheMatchAndNeverSaysIt(t *testing.T) {
	m, page, d := fillSetUp(t, nil)
	const token = "glpat-abcdefghij0123456789"
	page.value = "Your new token: " + token + " (shown once)"
	r := m.browserTool(2, "capture_secret", map[string]any{"secret": "GITLAB_TOKEN", "target": "e7", "pattern": `glpat-[A-Za-z0-9_-]{20,}`})
	if r.IsError || replyText(r) != "GITLAB_TOKEN saved (26 characters)." {
		t.Fatalf("%+v", r)
	}
	// An agent's write: Ask before use is on (#4014), so it is sealed, not in secrets.env.
	if skillcatalog.LoadSecrets(skillcatalog.SecretsPath(d.personalHome())).IsSet("GITLAB_TOKEN") {
		t.Fatal("a captured secret is in secrets.env")
	}
	if saved, _, _ := d.localSecret("", "GITLAB_TOKEN"); saved != token {
		t.Fatal("not saved")
	}
	if r := m.browserTool(3, "browser_snapshot", nil); strings.Contains(replyText(r), token) || !strings.Contains(replyText(r), "<secret GITLAB_TOKEN>") {
		t.Fatal("the value came back")
	}
	assertNotUnder(t, d.Store.Loc.Root, token)
	assertNotUnder(t, d.personalHome(), token)

	// It exists now: refused, unless replace, which keeps the old one.
	if r := m.browserTool(4, "capture_secret", map[string]any{"secret": "GITLAB_TOKEN", "target": "e7"}); !r.IsError || !strings.Contains(replyText(r), "exists") {
		t.Fatalf("%+v", r)
	}
	page.value = "glpat-ZYXWVUTSRQ9876543210"
	if r := m.browserTool(5, "capture_secret", map[string]any{"secret": "GITLAB_TOKEN", "target": "e7", "replace": true}); r.IsError {
		t.Fatalf("%+v", r)
	}
	if prev, _, _ := d.localSecret("", "GITLAB_TOKEN_PREVIOUS"); prev != token {
		t.Fatal("the old value was not kept")
	}
}

func TestCaptureSecretRefusesNoMatchAndSaysNothingItSaw(t *testing.T) {
	m, page, d := fillSetUp(t, nil)
	page.value = "app password hunter2secret"
	for i, args := range []map[string]any{
		{"secret": "MAIL_PASSWORD", "target": "e1", "pattern": `dop_v1_[a-f0-9]{64}`},
		{"secret": "MAIL_PASSWORD", "target": "e1", "pattern": `hun`},
		{"secret": "MAIL_PASSWORD", "target": "e1", "pattern": `(`},
	} {
		r := m.browserTool(2+i, "capture_secret", args)
		if !r.IsError || !strings.HasPrefix(replyText(r), "Nothing was saved: ") || strings.Contains(replyText(r), "hunter2") {
			t.Fatalf("%v: %+v", args, r)
		}
	}
	if skillcatalog.LoadSecrets(skillcatalog.SecretsPath(d.personalHome())).IsSet("MAIL_PASSWORD") || isSealedSecret(d.personalHome(), "MAIL_PASSWORD") {
		t.Fatal("saved")
	}
}
