package agentsd

import (
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/skillcatalog"
)

// generate_secret (#4000): the password is made, saved and filled, and never said.

func TestGenerateSecretIsListedWithTheBrowserTools(t *testing.T) {
	m, _, _ := fillSetUp(t, nil)
	_, list := m.post("tools/list", nil, 2)
	if !strings.Contains(string(list["result"]), `"name":"generate_secret"`) {
		t.Fatal("no generate_secret")
	}
	if got := appToolMethod(generateSecretName); got != "secrets/generate" {
		t.Fatal(got)
	}
}

func TestGenerateSecretSavesFillsAndNeverSaysIt(t *testing.T) {
	m, page, d := fillSetUp(t, nil)
	r := m.browserTool(2, "generate_secret", map[string]any{"secret": "GITLAB_PASSWORD", "target": "e12", "rules": "alphanumeric"})
	if r.IsError || replyText(r) != "GITLAB_PASSWORD made and filled." {
		t.Fatalf("%+v", r)
	}
	// An agent's write: Ask before use is on (#4014), so it is sealed, not in secrets.env.
	if skillcatalog.LoadSecrets(skillcatalog.SecretsPath(d.personalHome())).IsSet("GITLAB_PASSWORD") {
		t.Fatal("a made password is in secrets.env")
	}
	saved, _, _ := d.localSecret("", "GITLAB_PASSWORD")
	if len(saved) != generateLength || page.value != saved {
		t.Fatalf("saved %d characters, typed %d", len(saved), len(page.value))
	}
	if r := m.browserTool(3, "browser_snapshot", nil); strings.Contains(replyText(r), saved) {
		t.Fatal("the value came back")
	}
	assertNotUnder(t, d.Store.Loc.Root, saved)
	assertNotUnder(t, d.personalHome(), saved)

	// It exists now: refused, unless replace, which keeps the old one.
	if r := m.browserTool(4, "generate_secret", map[string]any{"secret": "GITLAB_PASSWORD", "target": "e12"}); !r.IsError || !strings.Contains(replyText(r), "exists") {
		t.Fatalf("%+v", r)
	}
	if r := m.browserTool(5, "generate_secret", map[string]any{"secret": "GITLAB_PASSWORD", "target": "e12", "replace": true}); r.IsError {
		t.Fatalf("%+v", r)
	}
	if prev, _, _ := d.localSecret("", "GITLAB_PASSWORD_PREVIOUS"); prev != saved {
		t.Fatal("the old value was not kept")
	}
	if now, _, _ := d.localSecret("", "GITLAB_PASSWORD"); now == saved {
		t.Fatal("not replaced")
	}
}

func TestGenerateSecretRefusesRulesNoPasswordMeets(t *testing.T) {
	m, page, _ := fillSetUp(t, nil)
	for i, rules := range []string{"minlength: 20; maxlength: 8", "required: lower; required: upper; maxlength: 1", "required: shouting", "allowed: [a]; max-consecutive: 1"} {
		if r := m.browserTool(2+i, "generate_secret", map[string]any{"secret": "PASS", "target": "e1", "rules": rules}); !r.IsError || !strings.HasPrefix(replyText(r), "Nothing was made: ") {
			t.Fatalf("%s: %+v", rules, r)
		}
	}
	if page.value != "" {
		t.Fatal("typed")
	}
}

func TestPasswordRules(t *testing.T) {
	cases := []struct {
		rules  string
		length int
		only   string
		needs  []string
	}{
		{"", 24, rulesLower + rulesUpper + rulesDigit + rulesSpecial, []string{rulesLower, rulesUpper, rulesDigit, rulesSpecial}},
		{"pin", 6, rulesDigit, nil},
		{"minlength: 12; maxlength: 16; required: lower, upper; required: digit; allowed: [-_]", 16, rulesLower + rulesUpper + rulesDigit + "-_", []string{rulesLower + rulesUpper, rulesDigit}},
		{"allowed: digit; minlength: 40", 40, rulesDigit, nil},
		{"required: [-,_]; maxlength: 200", generateLongest, "-,_", nil},
	}
	for _, c := range cases {
		r, err := parsePasswordRules(c.rules, 0)
		if err != nil {
			t.Fatalf("%q: %v", c.rules, err)
		}
		p, err := generatePassword(r)
		if err != nil || len(p) != c.length {
			t.Fatalf("%q: %d %v", c.rules, len(p), err)
		}
		if strings.Trim(p, c.only) != "" {
			t.Fatalf("%q: a character not allowed", c.rules)
		}
		for _, set := range c.needs {
			if !strings.ContainsAny(p, set) {
				t.Fatalf("%q: none of %q", c.rules, set)
			}
		}
	}
	r, _ := parsePasswordRules("pin", 4)
	if p, _ := generatePassword(r); len(p) != 4 {
		t.Fatal("pin length")
	}
	r, _ = parsePasswordRules("allowed: [ab]; max-consecutive: 1; maxlength: 30", 0)
	if p, _ := generatePassword(r); longestRun(p) > 1 {
		t.Fatal("max-consecutive")
	}
}
