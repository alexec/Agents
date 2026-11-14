package controlplane

// A backup restores a control plane in a new home (#2137), its providers' secrets too
// (#2138): the drill of the HADR review (H20261021-2), as a test.

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/kms"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
)

// homePlane starts a control plane from a home as serve --home keeps one: the key in
// control-key, the keeper for secrets in secrets-key, the store in store/.
func homePlane(t *testing.T, home string, port int) (*Service, error) {
	t.Helper()
	key, err := kms.File{Path: filepath.Join(home, "control-key")}.ControlKey(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	keeper, err := kms.LocalKeeper(filepath.Join(home, "secrets-key"))
	if err != nil {
		t.Fatal(err)
	}
	url := "http://127.0.0.1:" + itoa(port)
	s, err := New(Config{Store: store.NewFolder(filepath.Join(home, "store")), PrivateKey: key, URL: url, Bind: "127.0.0.1",
		Port: port, Name: "Home plane", MachineID: "MACHINE-1", SecretKeeper: keeper, ProviderHome: home})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(context.Background()); err != nil {
		return nil, err
	}
	t.Cleanup(s.Stop)
	return s, nil
}

func TestABackupRestoresAControlPlaneInANewHome(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	old, port := t.TempDir(), freePort(t)
	s, err := homePlane(t, old, port)
	if err != nil {
		t.Fatal(err)
	}
	_, pin, err := SelfSigned(filepath.Join(old, "tls"), "control.test")
	if err != nil {
		t.Fatal(err)
	}
	p := &plane{t: t, s: s, url: s.cfg.URL}
	member, _ := p.client("Window")
	s.Stop()
	// The VAPID key (#3651): without it, every browser's push subscription stops working.
	if err := os.WriteFile(filepath.Join(old, "webpush-key.pem"), []byte("scratch VAPID key"), 0o600); err != nil {
		t.Fatal(err)
	}

	backup := filepath.Join(t.TempDir(), "backup")
	list, err := Backup(ctx, store.NewFolder(filepath.Join(old, "store")), HomePartsIn(old), backup)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"control-key", "secrets-key", filepath.Join("tls", "cert.pem"), filepath.Join("tls", "key.pem"), "webpush-key.pem"} {
		if !strings.Contains(strings.Join(list.Files, " "), want) {
			t.Fatalf("the backup has %v, not %s", list.Files, want)
		}
	}
	if info, err := os.Stat(filepath.Join(backup, "control-key")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("the key in the backup: %v", err)
	}
	if _, err := Backup(ctx, store.NewFolder(filepath.Join(old, "store")), HomePartsIn(old), backup); err == nil {
		t.Fatal("a backup went over another")
	}
	// The machine is lost.
	os.RemoveAll(old)

	// The store alone, in a new home: another key's store does not start.
	alone := t.TempDir()
	if _, _, err := CopyStore(ctx, store.NewFolder(filepath.Join(backup, "store")), store.NewFolder(filepath.Join(alone, "store"))); err != nil {
		t.Fatal(err)
	}
	if _, err := homePlane(t, alone, freePort(t)); err == nil || !strings.Contains(err.Error(), "another key") {
		t.Fatalf("a store with a new key started: %v", err)
	}

	// The whole backup: the member connects with what it holds, and the provider's
	// secrets open.
	home := t.TempDir()
	if _, err := Restore(ctx, backup, HomePartsIn(home), store.NewFolder(filepath.Join(home, "store")), false); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(ctx, backup, HomePartsIn(home), store.NewFolder(filepath.Join(home, "store")), false); err == nil {
		t.Fatal("a restore went over a home")
	}
	if _, err := homePlane(t, home, port); err != nil {
		t.Fatal(err)
	}
	session, err := controllink.DialClient(ctx, member)
	if err != nil {
		t.Fatalf("the member was refused by the restored control plane: %v", err)
	}
	session.Close()
	if b, err := os.ReadFile(filepath.Join(home, "webpush-key.pem")); err != nil || string(b) != "scratch VAPID key" {
		t.Fatalf("the restored VAPID key: %q, %v", b, err)
	}
	// The certificate members are pinned to.
	if _, again, err := SelfSigned(filepath.Join(home, "tls"), "control.test"); err != nil || again != pin {
		t.Fatalf("the restored certificate's pin is %s, not %s (%v)", again, pin, err)
	}
}

// A VAPID key given as a secret (a cloud machine's, read only) is left as it is on a restore,
// as the APNs key is (#3651).
func TestARestoreLeavesAVAPIDKeyGivenAsASecret(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	old := t.TempDir()
	if err := os.WriteFile(filepath.Join(old, "webpush-key.pem"), []byte("old VAPID key"), 0o600); err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(t.TempDir(), "backup")
	if _, err := Backup(ctx, store.NewFolder(filepath.Join(old, "store")), HomeParts{WebPushKey: filepath.Join(old, "webpush-key.pem")}, backup); err != nil {
		t.Fatal(err)
	}
	secret := filepath.Join(t.TempDir(), "vapid-key")
	if err := os.WriteFile(secret, []byte("the secret's VAPID key"), 0o400); err != nil {
		t.Fatal(err)
	}
	list, err := Restore(ctx, backup, HomeParts{WebPushKey: secret}, store.NewFolder(filepath.Join(t.TempDir(), "store")), false)
	if err != nil {
		t.Fatal(err)
	}
	if len(list.Kept) != 1 || list.Kept[0] != secret {
		t.Fatalf("kept %v, not the secret", list.Kept)
	}
	if b, _ := os.ReadFile(secret); string(b) != "the secret's VAPID key" {
		t.Fatalf("the secret became %q", b)
	}
}
