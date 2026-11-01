package hosted

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// fakeDisk is a disk of a set size, whose free bytes a test changes.
type fakeDisk struct {
	mu    sync.Mutex
	space Space
	reads int
}

func (f *fakeDisk) read() (Space, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads++
	return f.space, nil
}

func (f *fakeDisk) set(free int64) {
	f.mu.Lock()
	f.space.Free = free
	f.mu.Unlock()
}

// #3121: past the disk's high-water mark, a write that grows an account's store is
// refused with a LimitError that names no plan; one that grows nothing still goes through.
func TestAFullDiskRefusesWritesThatGrow(t *testing.T) {
	ctx := context.Background()
	f := &fakeDisk{space: Space{Total: 1000, Free: 500}}
	now := time.Now()
	d := &disk{read: f.read, now: func() time.Time { return now }}
	l := limited(plans[PlanFree])
	l.diskFull = d.full
	var refused []string
	l.onRefuse = func(limit string) { refused = append(refused, limit) }
	if _, err := l.Put(ctx, "v1/a.json", []byte("one"), store.Always); err != nil {
		t.Fatal(err)
	}
	// 90% used: full. The reading is kept until diskReadEvery has passed.
	f.set(100)
	if _, err := l.Put(ctx, "v1/b.json", []byte("two"), store.Always); err != nil {
		t.Fatal("the disk was read again before diskReadEvery:", err)
	}
	now = now.Add(diskReadEvery)
	_, err := l.Put(ctx, "v1/c.json", []byte("three"), store.Always)
	var limit *LimitError
	if !errors.As(err, &limit) || limit.Limit != limitDisk || strings.Contains(err.Error(), "plan") {
		t.Fatalf("%v", err)
	}
	if o, _ := l.Get(ctx, "v1/c.json"); o != nil {
		t.Fatal("a refused write was written")
	}
	if len(refused) != 1 || refused[0] != limitDisk {
		t.Fatal(refused)
	}
	// A rewrite no larger, and a delete, still go through.
	if _, err := l.Put(ctx, "v1/a.json", []byte("one"), store.Always); err != nil {
		t.Fatal(err)
	}
	if err := l.Delete(ctx, "v1/b.json"); err != nil {
		t.Fatal(err)
	}
	if f.reads != 2 {
		t.Fatalf("the disk was read %d times", f.reads)
	}
	// Room again: writes go through.
	f.set(500)
	now = now.Add(diskReadEvery)
	if _, err := l.Put(ctx, "v1/c.json", []byte("three"), store.Always); err != nil {
		t.Fatal(err)
	}
}

// A disk that cannot be read refuses nothing: the plan's own limit still holds.
func TestADiskThatCannotBeReadIsNotFull(t *testing.T) {
	d := &disk{read: func() (Space, error) { return Space{}, errors.New("no") }, now: time.Now}
	if d.full() {
		t.Fatal("full")
	}
	if (*disk)(nil).full() {
		t.Fatal("no disk is full")
	}
}

// #3121: a new account whose plan's storage would take the plans' total past the disk
// waits at the front of the waitlist, as at the cap.
func TestANewAccountPastTheDiskWaits(t *testing.T) {
	st := store.NewMemory()
	// Room for two Free plans: 2.5 GB to 90%.
	f := &fakeDisk{space: Space{Total: 25 * gigabyte / 10, Free: 25 * gigabyte / 10}}
	s, browserFor := startWith(t, Config{Store: st, SignUp: SignUpOpen, Disk: f.read})
	for _, who := range []string{"u.501.one.400", "u.502.two.400"} {
		if res := browserFor().signIn(who); !madeAccount(res) {
			t.Fatal(who, "was not signed up")
		}
	}
	if _, page := browserFor().signInPage("u.503.three.400", ""); !strings.Contains(page, "number 1") || !strings.Contains(page, "as many accounts") {
		t.Fatal(page)
	}
	if n, _ := s.accounts.count(context.Background()); n != 2 {
		t.Fatalf("%d accounts past the disk", n)
	}
	text, err := s.metricsText(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`agents_hosted_disk_bytes{kind="total"} 2684354560`,
		"agents_hosted_storage_promised_bytes 2147483648", "agents_hosted_storage_total_bytes 2415919050",
		"agents_hosted_disk_high_water_bytes 2415919050"} {
		if !strings.Contains(text, want) {
			t.Errorf("no %s in\n%s", want, text)
		}
	}
}

// #3121: a configured total is used over the disk, and with neither, nothing is refused.
func TestTheStorageTotal(t *testing.T) {
	s := &Service{cfg: Config{StorageTotal: 5 * gigabyte}, disk: &disk{read: (&fakeDisk{space: Space{Total: 1}}).read, now: time.Now}}
	if most, ok := s.storageTotal(); !ok || most != 5*gigabyte {
		t.Fatal(most, ok)
	}
	s = &Service{disk: &disk{}}
	if _, ok := s.storageTotal(); ok {
		t.Fatal("a total with no disk")
	}
}

// #3121: an upgrade whose Pro storage would take the plans' total past the disk is
// refused before Stripe, in words, and counted.
func TestAnUpgradePastTheTotalIsRefused(t *testing.T) {
	f := &fakeStripe{}
	// Room for the Free account, not for it on Pro.
	s, newBrowser := startWith(t, Config{Store: store.NewMemory(), SignUp: SignUpOpen, Stripe: f, StripePrice: "price_pro",
		StripeWebhookSecret: webhookSecret, StorageTotal: 10 * gigabyte})
	b := newBrowser()
	if !madeAccount(b.signIn("good")) {
		t.Fatal("not signed up")
	}
	acc, err := s.accounts.byGitHub(context.Background(), 42)
	if err != nil || acc == nil {
		t.Fatal("no account", err)
	}
	res, page := b.post("https://"+domain+"/account/upgrade", url.Values{"token": {s.sessions.form(acc.ID)}})
	if res.StatusCode != http.StatusOK || !strings.Contains(page, "no room for more Pro plans") {
		t.Fatalf("%d %s", res.StatusCode, page)
	}
	if len(f.checkouts) != 0 {
		t.Fatal("a checkout past the total")
	}
	s.metrics.mu.Lock()
	defer s.metrics.mu.Unlock()
	if s.metrics.refusals["upgrade_full"] != 1 {
		t.Fatal(s.metrics.refusals)
	}
}
