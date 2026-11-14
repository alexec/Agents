package agentsd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/skillcatalog"
	"github.com/agentloops-dev/agent-loops/Go/wire"
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

// #4177: every write of a secret with the flag off goes to the sealed store, and a
// secrets.env found at start is sealed into it and removed, at each start that finds one.
// After a start, no file under the home holds a value as plain text.
func TestNoSecretsEnvAfterAStart(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	path := skillcatalog.SecretsPath(home)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("# mine\nOLD_TOKEN=old-4177-not-real\nKEPT_TOKEN=from-the-file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	d, _ := start(t, root)
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("secrets.env is still there: %v", err)
	}
	if got := d.secrets(); got["OLD_TOKEN"] != "old-4177-not-real" || got["KEPT_TOKEN"] != "from-the-file" {
		t.Fatalf("%v", got)
	}
	if s := readSealedSecrets(home).Secrets["OLD_TOKEN"]; !s.NoAsk {
		t.Fatalf("a moved secret is flagged: %+v", s)
	}

	// Each writer keeps its value in the store, with the flag off.
	if err := d.saveSecret("ASKED_BY_HAND", "asked-4177-not-real", false); err != nil {
		t.Fatal(err)
	}
	if err := d.setPlainSecrets(home, map[string]string{"MCP_TOKEN": "mcp-4177-not-real"}, ""); err != nil {
		t.Fatal(err)
	}
	if err := d.saveSecret("FLAGGED_TOKEN", "flagged-4177-not-real", true); err != nil {
		t.Fatal(err)
	}
	if err := d.setNeedsApproval(wire.SecretNeedsApprovalRequest{Name: "FLAGGED_TOKEN", NeedsApproval: false}); err != nil {
		t.Fatal(err)
	}
	// A write that is not the flag's own does not turn Ask before use off.
	if err := d.saveSecret("STILL_ASKS", "asks-4177-not-real", true); err != nil {
		t.Fatal(err)
	}
	if err := d.setPlainSecrets(home, map[string]string{"STILL_ASKS": "asks-4177-newer"}, ""); err != nil {
		t.Fatal(err)
	}
	if !isSealedSecret(home, "STILL_ASKS") {
		t.Fatal("a plain write turned the flag off")
	}
	got := d.secrets()
	for name, want := range map[string]string{"ASKED_BY_HAND": "asked-4177-not-real", "MCP_TOKEN": "mcp-4177-not-real",
		"FLAGGED_TOKEN": "flagged-4177-not-real"} {
		if got[name] != want {
			t.Fatalf("%s: %q", name, got[name])
		}
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a write made secrets.env again")
	}
	if err := d.forgetPlainSecret(home, "MCP_TOKEN"); err != nil || secretIsSet(home, "MCP_TOKEN") {
		t.Fatalf("forget: %v", err)
	}
	d.Shutdown()

	// A file that comes back (a hand edit) is moved at the next start; the store's record
	// of a name wins over the file's line, as every reader read it first.
	os.WriteFile(path, []byte("KEPT_TOKEN=stale-line\nNEW_TOKEN=new-4177-not-real\n"), 0o600)
	d2, _ := start(t, root)
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("secrets.env came back and stayed")
	}
	if got := d2.secrets(); got["KEPT_TOKEN"] != "from-the-file" || got["NEW_TOKEN"] != "new-4177-not-real" {
		t.Fatalf("%v", got)
	}
	for _, v := range []string{"old-4177-not-real", "from-the-file", "asked-4177-not-real", "flagged-4177-not-real",
		"asks-4177-newer", "new-4177-not-real", "stale-line"} {
		assertNotUnder(t, home, v)
		assertNotUnder(t, root, v)
	}
}

// #4177: a start whose key does not read leaves secrets.env as it is, and its readers read
// it until a start moves it.
func TestAMoveWithNoKeyKeepsTheFile(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	path := skillcatalog.SecretsPath(home)
	os.MkdirAll(filepath.Dir(path), 0o700)
	os.WriteFile(path, []byte("OLD_TOKEN=old-value\n"), 0o600)
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Shutdown()
	d.HostKey = nil
	d.MoveSecretsFile()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the file went with nothing to seal it: %v", err)
	}
	if got := d.secrets()["OLD_TOKEN"]; got != "old-value" {
		t.Fatalf("%q", got)
	}
}
