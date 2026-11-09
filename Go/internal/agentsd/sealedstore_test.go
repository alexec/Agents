package agentsd

import (
	"errors"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// #4176: a secret with Ask before use off is kept in the sealed store, and opens with no
// approval for every reader of secrets.env: d.secrets(), the readers that look a name up,
// and localSecret. It is no flagged secret.
func TestAnUnflaggedRecordOpensWithNoApproval(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	const value = "glpat-4176-not-real"
	if err := d.saveSealedSecret(home, "GITLAB_TOKEN", value, "", false); err != nil {
		t.Fatal(err)
	}
	s := readSealedSecrets(home).Secrets["GITLAB_TOKEN"]
	if !s.NoAsk || s.Release || len(s.Grants) != 0 || strings.Contains(string(s.Sealed), value) {
		t.Fatalf("%+v", s)
	}
	if isSealedSecret(home, "GITLAB_TOKEN") || d.secretIsSealed("", "GITLAB_TOKEN") || !secretIsSet(home, "GITLAB_TOKEN") {
		t.Fatal("an unflagged record reads as flagged, or as not set")
	}
	if got := d.secrets()["GITLAB_TOKEN"]; got != value {
		t.Fatalf("d.secrets(): %q", got)
	}
	if got, _ := d.plainSecrets(home).Value("GITLAB_TOKEN"); got != value {
		t.Fatalf("plainSecrets: %q", got)
	}
	agent := seeded(t, d, t.TempDir(), nil).ID
	if got, ok, _ := d.localSecret(agent, "GITLAB_TOKEN"); !ok || got != value {
		t.Fatalf("localSecret: %q %v", got, ok)
	}
	assertNotUnder(t, home, value)

	// The store's value goes before secrets.env's, and a new one is read once it is kept.
	if err := d.saveSecret("OTHER_TOKEN", "from-the-file", false); err != nil {
		t.Fatal(err)
	}
	if err := d.saveSealedSecret(home, "GITLAB_TOKEN", "glpat-4176-newer", "", false); err != nil {
		t.Fatal(err)
	}
	if got := d.secrets(); got["GITLAB_TOKEN"] != "glpat-4176-newer" || got["OTHER_TOKEN"] != "from-the-file" {
		t.Fatalf("%v", got)
	}

	// Turning the flag on seals it with the flag, and it leaves every plain reader.
	if err := d.setNeedsApproval(wire.SecretNeedsApprovalRequest{Name: "GITLAB_TOKEN", NeedsApproval: true}); err != nil {
		t.Fatal(err)
	}
	if !isSealedSecret(home, "GITLAB_TOKEN") || d.secrets()["GITLAB_TOKEN"] != "" {
		t.Fatal("a flagged secret is still read as unflagged")
	}
}

// #4176: the flag is bound in the associated data: a record whose flag is changed by hand
// does not open, either way.
func TestAnUnflaggedRecordsFlagChangedByHandDoesNotOpen(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	if err := d.saveSealedSecret(home, "PLAIN_TOKEN", "plain-value", "", false); err != nil {
		t.Fatal(err)
	}
	if err := d.saveSealedSecret(home, "ASKED_TOKEN", "asked-value", "", true); err != nil {
		t.Fatal(err)
	}
	f := readSealedSecrets(home)
	plain, asked := f.Secrets["PLAIN_TOKEN"], f.Secrets["ASKED_TOKEN"]
	plain.NoAsk, asked.NoAsk = false, true
	f.Secrets["PLAIN_TOKEN"], f.Secrets["ASKED_TOKEN"] = plain, asked
	writeSealedSecrets(home, f)
	if got := d.secrets(); got["ASKED_TOKEN"] != "" || got["PLAIN_TOKEN"] != "" {
		t.Fatalf("a flag changed by hand opened: %v", got)
	}
	if _, ok := d.sealedLocalSecret(home, "PLAIN_TOKEN"); ok {
		t.Fatal("an unflagged record turned flagged by hand opened")
	}
}

// #4176: a Linux machine with no control plane keeps a secret with the flag off: it has no
// release layer, so it needs no control plane and no signed approval.
func TestALinuxMachineWithNoControlPlaneKeepsAnUnflaggedSecret(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.secretReleaseOn = new(true)
	if d.keepsFlagged() {
		t.Fatal("a machine with no control plane keeps flagged secrets")
	}
	if err := d.saveSealedSecret(home, "GITLAB_TOKEN", "linux-value", "", false); err != nil {
		t.Fatal(err)
	}
	if s := readSealedSecrets(home).Secrets["GITLAB_TOKEN"]; s.Release || !s.NoAsk {
		t.Fatalf("%+v", s)
	}
	if got := d.secrets()["GITLAB_TOKEN"]; got != "linux-value" {
		t.Fatalf("%q", got)
	}
	if d.needsRelease("", "GITLAB_TOKEN") || d.releasePending("", "GITLAB_TOKEN") {
		t.Fatal("an unflagged secret waits on a release")
	}
}

type unreadableKey struct{}

func (unreadableKey) Load() ([]byte, bool, error) {
	return nil, false, errors.New("the Keychain item is another program's")
}
func (unreadableKey) Save([]byte) error { return errors.New("not saved") }

// #4176, #4045: when this machine's key does not read, every secret in the store says the
// same clear error, flag on or off, and nothing is read as set.
func TestAnUnreadableKeyGivesOneErrorForEverySecret(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	if err := d.saveSealedSecret(home, "PLAIN_TOKEN", "plain-value", "", false); err != nil {
		t.Fatal(err)
	}
	if err := d.saveSealedSecret(home, "ASKED_TOKEN", "asked-value", "", true); err != nil {
		t.Fatal(err)
	}
	d.HostKey = unreadableKey{}
	f := readSealedSecrets(home)
	var messages []string
	for _, name := range []string{"PLAIN_TOKEN", "ASKED_TOKEN"} {
		_, err := d.openSealedSecret(sealedLocal, name, f.Secrets[name])
		var keyErr machineKeyError
		if !errors.As(err, &keyErr) {
			t.Fatalf("%s: %v", name, err)
		}
		messages = append(messages, err.Error())
	}
	if messages[0] != messages[1] || !strings.Contains(messages[0], "no secret kept in sealed.json opens") {
		t.Fatalf("%q", messages)
	}
	if got := d.secrets()["PLAIN_TOKEN"]; got != "" {
		t.Fatalf("%q", got)
	}
	if err := d.saveSealedSecret(home, "NEW_TOKEN", "new", "", false); err == nil || !strings.Contains(err.Error(), "does not read") {
		t.Fatalf("%v", err)
	}
}
