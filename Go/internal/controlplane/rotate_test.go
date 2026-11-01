package controlplane

import (
	"bytes"
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// #997 (spec 736 US9 AS3): an admin rotates the control key, and every client and
// machine takes the new one over its next connection, proved by the old one; nobody
// pairs again. A member away at the time takes it when it comes back, after a restart
// too, until the previous key is let go.
func TestRotatingTheControlKeyPairsNobodyAgain(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	keeper := kms.File{Path: filepath.Join(root, "control-key")}
	key, err := keeper.ControlKey(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	st := store.NewFolder(filepath.Join(root, "store"))
	withKeeper := func(c *Config) { c.KeyKeeper = keeper }
	p := startPlaneWith(t, st, key, withKeeper)
	h := p.host("MACHINE-2")
	admin, window := p.client("Window")
	away, phone := p.client("Phone")
	phone.Close()
	old := append([]byte(nil), admin.ControlKey...)

	call(t, window, "", "control/rotate", map[string]any{})
	fresh := p.s.publicKey()
	if bytes.Equal(fresh, old) {
		t.Fatal("the key did not change")
	}
	// The machine connects again with the old key and keeps the new one.
	p.waitFor(func() bool {
		m, err := controllink.LoadMembership(h.root)
		return err == nil && bytes.Equal(m.ControlKey, fresh)
	}, "the machine to keep the new key")
	p.waitFor(func() bool { s, ok := p.s.Router().State(h.member.Host); return ok && s.online() }, "the machine back online")
	// So does the window, when it dials again.
	again, err := controllink.DialClient(context.Background(), admin)
	if err != nil {
		t.Fatal(err)
	}
	again.Close()
	if !bytes.Equal(admin.ControlKey, fresh) {
		t.Fatal("the window did not take the new key")
	}

	// A restart keeps both keys: the phone, away all along, still comes back.
	h.stop()
	p.s.Stop()
	next, err := keeper.ControlKey(context.Background())
	if err != nil || !bytes.Equal(publicOf(t, next), fresh) {
		t.Fatalf("the key file was not rotated: %v", err)
	}
	q := startPlaneWith(t, store.NewFolder(filepath.Join(root, "store")), next, withKeeper)
	away.URL = q.url
	s, err := controllink.DialClient(context.Background(), away)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	if !bytes.Equal(away.ControlKey, fresh) {
		t.Fatal("the phone did not take the new key")
	}

	// Thirty days on, the previous key goes, and a member still on it is a stranger.
	late, err := controllink.PairClient(context.Background(), q.code(false), "Late")
	if err != nil {
		t.Fatal(err)
	}
	late.ControlKey = old
	month := records.At(time.Now().Add(-previousKeyKept - time.Hour))
	if _, err := q.s.records.ChangeSettings(context.Background(), func(s *records.Settings) { s.RotatedAt = &month }); err != nil {
		t.Fatal(err)
	}
	q.s.dropPreviousKey(context.Background())
	if _, err := controllink.DialClient(context.Background(), late); err == nil {
		t.Fatal("a member on a key let go connected")
	}
	if prev, _ := keeper.Previous(context.Background()); prev != nil {
		t.Fatal("the previous key's file was kept")
	}
}

// A key handed in has nowhere to keep a new one, and is not rotated.
func TestAKeyHandedInIsNotRotated(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Window")
	if e := callError(t, window, "", "control/rotate", map[string]any{}); !strings.Contains(e, "given its key") {
		t.Fatal(e)
	}
}

// A new key in ok with a proof the previous key's holder did not make is refused.
func TestANewKeyWithoutItsProofIsRefused(t *testing.T) {
	t.Parallel()
	shared := []byte("0123456789abcdef0123456789abcdef")
	public := publicOf(t, controllink.NewPrivateKey())
	offer := newKeyFor(shared, public)
	if got, err := controllink.NewKey(&controllink.OK{NewKey: offer}, shared); err != nil || !bytes.Equal(got, public) {
		t.Fatalf("%v", err)
	}
	if _, err := controllink.NewKey(&controllink.OK{NewKey: offer}, []byte("another shared key, 32 bytes....")); err == nil {
		t.Fatal("a proof under another key was taken")
	}
}

func publicOf(t *testing.T, private []byte) []byte {
	t.Helper()
	public, err := controllink.PublicKey(private)
	if err != nil {
		t.Fatal(err)
	}
	return public
}

// The proof Swift and the page check (ControlAuthTests, auth.test.mjs): the same bytes.
func TestTheNewKeyProofIsTheClientsOwn(t *testing.T) {
	t.Parallel()
	shared := bytes.Repeat([]byte{1}, 32)
	key := append([]byte{4}, bytes.Repeat([]byte{2}, 64)...)
	if got := controllink.B64URL(controllink.NewKeyProof(shared, key)); got != "v9-kYG-84IN39u6AMjxueMV9PJ0RFPVWlUAghG140Wg" {
		t.Fatal(got)
	}
}

// H20261031-1: a rotation of the control key never makes a server's backup unreadable.
// A backup made before the rotation, and one made after it and before the restart, open
// after the restart with the new key, and still open once the previous key is let go.
func TestBackupsOpenAfterTheControlKeyIsRotated(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	root := t.TempDir()
	keeper := kms.File{Path: filepath.Join(root, "control-key")}
	key, err := keeper.ControlKey(ctx)
	if err != nil {
		t.Fatal(err)
	}
	withKeeper := func(c *Config) { c.KeyKeeper = keeper }
	p := startPlaneWith(t, store.NewFolder(filepath.Join(root, "store")), key, withKeeper)
	_, window := p.client("Window")
	before, after := []byte("made before the rotation"), []byte("made after the rotation")
	first, err := putBackup(t, p.s.backups, "a", "20261020T120000Z", [][]byte{before}, 3)
	if err != nil {
		t.Fatal(err)
	}
	call(t, window, "", "control/rotate", map[string]any{})
	second, err := putBackup(t, p.s.backups, "a", "20261020T130000Z", [][]byte{after}, 3)
	if err != nil {
		t.Fatal(err)
	}
	window.Close()
	p.s.Stop()

	restart := func() *plane {
		t.Helper()
		next, err := keeper.ControlKey(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return startPlaneWith(t, store.NewFolder(filepath.Join(root, "store")), next, withKeeper)
	}
	opens := func(q *plane, when string) {
		t.Helper()
		for _, b := range []struct {
			id   string
			data []byte
		}{{first.ID, before}, {second.ID, after}} {
			out, err := q.s.backups.said("backups/download", "b", raw(t, wire.BackupStorePartRequest{ID: b.id, Part: 0}))
			if err != nil {
				t.Fatalf("%s, %s does not open: %v", when, b.id, err)
			}
			if !bytes.Equal(out.(wire.BackupStorePart).Data, b.data) {
				t.Fatalf("%s, %s came back changed", when, b.id)
			}
		}
	}
	q := restart()
	opens(q, "after the restart")

	// Thirty days on, the previous key goes; the backups do not.
	month := records.At(time.Now().Add(-previousKeyKept - time.Hour))
	if _, err := q.s.records.ChangeSettings(ctx, func(s *records.Settings) { s.RotatedAt = &month }); err != nil {
		t.Fatal(err)
	}
	q.s.dropPreviousKey(ctx)
	q.s.Stop()
	opens(restart(), "with the previous key let go")
}
