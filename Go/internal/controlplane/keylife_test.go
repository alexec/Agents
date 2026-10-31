package controlplane

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// #997 (spec 736 US9): a key lives its lifetime from pairing, is renewed when it is used
// near its end, and is refused as expired once it has passed.
func TestAKeyInUseRenewsAndAnUnusedOneExpires(t *testing.T) {
	t.Parallel()
	life := 3 * time.Hour
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.KeyLifetime = life })
	member, window := p.client("Window")
	window.Close()
	ctx := context.Background()
	c := p.s.records.Client(member.Client)
	if c.Expires == nil || time.Until(c.Expires.Time) < life-time.Minute {
		t.Fatalf("a client paired now lives its lifetime: %+v", c.Expires)
	}

	// Near its end, a connection renews it.
	setExpires(t, p, member.Client, time.Now().Add(30*time.Minute))
	again, err := controllink.DialClient(ctx, member)
	if err != nil {
		t.Fatal(err)
	}
	again.Close()
	p.waitFor(func() bool {
		e := p.s.records.Client(member.Client).Expires
		return e != nil && time.Until(e.Time) > life-time.Minute
	}, "the key to be renewed")

	// Past its end, it is refused as expired, and kept so its person sees it.
	setExpires(t, p, member.Client, time.Now().Add(-time.Minute))
	if _, err := controllink.DialClient(ctx, member); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("an expired key connected: %v", err)
	}
	if p.s.records.Client(member.Client) == nil {
		t.Fatal("an expired client's record went")
	}
}

func TestAMachinesKeyRenewsAndExpires(t *testing.T) {
	t.Parallel()
	life := 3 * time.Hour
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.KeyLifetime = life })
	h := p.host("MACHINE-2")
	id := h.member.Host
	if e := p.s.records.Host(id).Expires; e == nil || time.Until(e.Time) < life-time.Minute {
		t.Fatalf("a machine joined now lives its lifetime: %+v", e)
	}
	// Connected, it is renewed by the hour's round.
	saveHostExpires(t, p, id, time.Now().Add(10*time.Minute))
	p.s.renewConnected(context.Background())
	if e := p.s.records.Host(id).Expires; time.Until(e.Time) < life-time.Minute {
		t.Fatalf("a connected machine was not renewed: %v", e)
	}
	h.stop()
	saveHostExpires(t, p, id, time.Now().Add(-time.Minute))
	if _, _, _, err := p.s.key(controllink.Identity{Kind: 'h', ID: id}); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("an expired machine's key was taken: %v", err)
	}
}

// A key paired before #997 has no expiry: it counts from when it was last used, and one
// long unused gets a whole lifetime from now rather than being cut off by the upgrade.
func TestAKeyPairedBeforeLifetimesCountsFromItsLastUse(t *testing.T) {
	t.Parallel()
	now := time.Now()
	life := 90 * 24 * time.Hour
	if e := renewing(nil, now.Add(-10*24*time.Hour), now, life); e.Sub(now) > 81*24*time.Hour || e.Sub(now) < 79*24*time.Hour {
		t.Fatalf("used ten days ago: %v", e)
	}
	if e := renewing(nil, now.Add(-200*24*time.Hour), now, life); e.Sub(now) < life-time.Minute {
		t.Fatalf("unused for longer than a lifetime: %v", e)
	}
	far := records.At(now.Add(60 * 24 * time.Hour))
	if renewing(&far, now, now, life) != nil {
		t.Fatal("a key with 60 days left was renewed")
	}
	near := records.At(now.Add(20 * 24 * time.Hour))
	if e := renewing(&near, now, now, life); e == nil || e.Sub(now) < life-time.Minute {
		t.Fatalf("a key with 20 days left: %v", e)
	}
}

func setExpires(t *testing.T, p *plane, client string, at time.Time) {
	t.Helper()
	stamp := records.At(at)
	if err := p.s.records.ChangeClient(context.Background(), client, func(c *records.ClientRecord) bool {
		c.Expires = &stamp
		return true
	}); err != nil {
		t.Fatal(err)
	}
}

func saveHostExpires(t *testing.T, p *plane, id string, at time.Time) {
	t.Helper()
	h := p.s.records.Host(id)
	stamp := records.At(at)
	h.Expires = &stamp
	if err := p.s.records.SaveHost(context.Background(), *h); err != nil {
		t.Fatal(err)
	}
}
