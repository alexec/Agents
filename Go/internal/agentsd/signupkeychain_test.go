package agentsd

import (
	"errors"
	"slices"
	"testing"
)

type fakeKeychain struct {
	items map[string]string
	reads []string
}

func (k *fakeKeychain) services() ([]string, error) {
	out := make([]string, 0, len(k.items))
	for s := range k.items {
		out = append(out, s)
	}
	slices.Sort(out)
	return out, nil
}

func (k *fakeKeychain) password(service string) (string, error) {
	k.reads = append(k.reads, service)
	if v := k.items[service]; v != "" {
		return v, nil
	}
	return "", errors.New("prompt not answered")
}

func TestSignupSecretName(t *testing.T) {
	for domain, want := range map[string]string{
		"gitlab.com":              "GITLAB_PASSWORD",
		"digitalocean.com":        "DIGITALOCEAN_PASSWORD",
		"aws.amazon.com":          "AWS_PASSWORD",
		"workspace.google.com":    "GOOGLE_WORKSPACE_PASSWORD",
		"okta-integrator-3285196": "OKTA_INTEGRATOR_PASSWORD",
		"auth0.com":               "AUTH0_PASSWORD",
		"":                        "",
		"3com.com":                "",
	} {
		if got := signupSecretName(domain); got != want {
			t.Errorf("%q: %q, want %q", domain, got, want)
		}
	}
}

func TestSignupServicesReadsNoValue(t *testing.T) {
	dump := []byte(`keychain: "/Users/x/Library/Keychains/login.keychain-db"
attributes:
    "acct"<blob>="agents@example.com"
    "svce"<blob>="agents-signup:gitlab.com"
attributes:
    "svce"<blob>="Claude Code-credentials"
attributes:
    "svce"<blob>="agents-signup:aws.amazon.com"
    "svce"<blob>="agents-signup:gitlab.com"
`)
	if got := signupServices(dump); !slices.Equal(got, []string{"agents-signup:aws.amazon.com", "agents-signup:gitlab.com"}) {
		t.Fatal(got)
	}
}

// #5043: each old sign-up password is copied into the store with Ask before use on and a
// description; a name already set keeps its value and its item is not even read; an item
// that does not read is left for the next start.
func TestMoveSignupKeychain(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	if err := d.saveSecret("GITLAB_PASSWORD", "newer-reset-not-real", true); err != nil {
		t.Fatal(err)
	}
	k := &fakeKeychain{items: map[string]string{
		"agents-signup:gitlab.com":        "old-gitlab-not-real",
		"agents-signup:aws.amazon.com":    "aws-5043-not-real",
		"agents-signup:atlassian.com":     "",
		"agents-signup:okta-integrator-1": "okta-5043-not-real",
	}}
	old := signupKeychain
	signupKeychain = k
	defer func() { signupKeychain = old }()

	n, err := d.moveSignupKeychain()
	if err != nil || n != 2 {
		t.Fatalf("%d %v", n, err)
	}
	for name, want := range map[string]string{
		"GITLAB_PASSWORD":          "newer-reset-not-real",
		"AWS_PASSWORD":             "aws-5043-not-real",
		"OKTA_INTEGRATOR_PASSWORD": "okta-5043-not-real",
	} {
		if v, ok, _ := d.localSecret("", name); !ok || v != want {
			t.Errorf("%s: %q %v", name, v, ok)
		}
		if !isSealedSecret(home, name) {
			t.Errorf("%s does not ask before use", name)
		}
	}
	if slices.Contains(k.reads, "agents-signup:gitlab.com") {
		t.Error("an item whose name is set was read")
	}
	if secretIsSet(home, "ATLASSIAN_PASSWORD") {
		t.Error("an item that did not read was saved")
	}
	if got := readSecretDescriptions(home)["AWS_PASSWORD"]; got == "" {
		t.Error("no description")
	}

	// The next start copies only what is still missing.
	k.reads = nil
	if n, _ := d.moveSignupKeychain(); n != 0 || !slices.Equal(k.reads, []string{"agents-signup:atlassian.com"}) {
		t.Fatalf("%d %v", n, k.reads)
	}
}
