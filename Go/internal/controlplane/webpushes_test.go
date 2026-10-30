package controlplane

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/webpush"
	"github.com/alexec/agents/Go/wire"
)

// fakeWebPusher keeps every Web Push, and answers with what it is told to.
type fakeWebPusher struct {
	mu     sync.Mutex
	pushes []webpush.Push
	answer error
}

func (f *fakeWebPusher) Send(_ context.Context, p webpush.Push) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pushes = append(f.pushes, p)
	return f.answer
}

func (f *fakeWebPusher) PublicKey() string { return "BVAPIDKEY" }

func (f *fakeWebPusher) sent() []webpush.Push {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]webpush.Push(nil), f.pushes...)
}

const webPushEndpoint = "https://fcm.googleapis.com/fcm/send/abc"

// webPushKeys is a browser's two keys, as PushSubscription.toJSON() gives them.
func webPushKeys(t *testing.T) map[string]string {
	t.Helper()
	key, _ := ecdh.P256().GenerateKey(rand.Reader)
	auth := make([]byte, 16)
	_, _ = rand.Read(auth)
	return map[string]string{"endpoint": webPushEndpoint, "p256dh": base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()),
		"auth": base64.RawURLEncoding.EncodeToString(auth)}
}

// browserWithWebPush signs a browser in and gives its subscription over its own session,
// as the page does.
func (p *plane) browserWithWebPush() (*controllink.ClientMembership, *controllink.Session) {
	m, session := p.client("browser")
	if err := p.s.Records().ChangeClient(context.Background(), m.Client, func(c *records.ClientRecord) bool {
		c.Kind = records.KindBrowser
		return true
	}); err != nil {
		p.t.Fatal(err)
	}
	call(p.t, session, "", "clients/setWebPush", webPushKeys(p.t))
	return m, session
}

func webPushItem(t *testing.T, push webpush.Push) wire.ControlPushItem {
	t.Helper()
	var item wire.ControlPushItem
	if err := json.Unmarshal(push.Payload, &item); err != nil {
		t.Fatal(err)
	}
	return item
}

// With no iPhone, the need goes to the browser that subscribed, by Web Push (#1486). No
// APNs key is needed.
func TestANeedGoesToASubscribedBrowserByWebPush(t *testing.T) {
	t.Parallel()
	web := &fakeWebPusher{}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.WebPush = web })
	box := p.host("MACHINE-2")
	m, _ := p.browserWithWebPush()
	if record := p.s.Records().Client(m.Client); record.WebPush == nil || record.WebPush.Endpoint != webPushEndpoint || len(record.WebPush.Auth) != 16 {
		t.Fatal(record.WebPush)
	}
	if _, err := p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(pushNeed)); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool { return len(web.sent()) == 1 }, "a Web Push")
	push := web.sent()[0]
	if push.Endpoint != webPushEndpoint || !push.Urgent || push.Topic == "" || len(push.Topic) > 32 {
		t.Fatal(push)
	}
	if item := webPushItem(t, push); !item.Alert || item.Headline == nil || item.Headline.H2 != "Fix the gallery" || item.NeedID.Permission == nil {
		t.Fatal(item)
	}
	// Met, it is not taken back by a push: one that shows nothing costs a browser its
	// subscription. The page takes it back when it comes into view.
	_, _ = p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(`{"withdraw":{"permission":"E0000000-0000-4000-8000-000000000005"}}`))
	time.Sleep(200 * time.Millisecond)
	if n := len(web.sent()); n != 1 {
		t.Fatal(n, "Web Pushes: a withdrawal was sent")
	}
	// The subscription is the browser's alone: clients/list does not say it.
	_, session := p.client("window")
	if list := string(call(t, session, "", "clients/list", nil)); strings.Contains(list, "fcm.googleapis.com") || strings.Contains(list, "webPush") {
		t.Fatal(list)
	}
}

// An iPhone is the default before a browser: the need goes through APNs, not Web Push.
func TestAnIPhoneComesBeforeABrowser(t *testing.T) {
	t.Parallel()
	pusher, web := &fakePusher{}, &fakeWebPusher{}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.Push, c.WebPush = pusher, web })
	box := p.host("MACHINE-2")
	p.browserWithWebPush()
	p.phoneWithToken()
	_, _ = p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(pushNeed))
	p.waitFor(func() bool { return len(pusher.sent()) == 1 }, "a push")
	time.Sleep(100 * time.Millisecond)
	if n := len(web.sent()); n != 0 {
		t.Fatal(n, "Web Pushes beside the iPhone's")
	}
}

// A relay host carries nothing to a browser: with one online, the browser still gets its
// Web Push from the control plane, and the relay hears of none.
func TestABrowserGetsWebPushBesideARelay(t *testing.T) {
	t.Parallel()
	web := &fakeWebPusher{}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.WebPush = web })
	_, relay := p.rawHost("relay mac", true)
	box := p.host("MACHINE-2")
	p.browserWithWebPush()
	if _, err := p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(pushNeed)); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool { return len(web.sent()) == 1 }, "a Web Push")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	for {
		line, err := relay.Read(ctx)
		if err != nil {
			break
		}
		if strings.Contains(line, "relay/deliver") {
			t.Fatal("the relay was given a browser's notice:", line)
		}
	}
}

// Only a browser sets a subscription, only its own, only a real one, and only where there
// is a VAPID key to push with; one its push service says is gone is forgotten.
func TestOnlyABrowserSetsItsOwnWebPush(t *testing.T) {
	t.Parallel()
	web := &fakeWebPusher{answer: webpush.ErrGone}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.WebPush = web })
	_, window := p.client("window")
	if key := string(call(t, window, "", "clients/webPushKey", nil)); key != `{"publicKey":"BVAPIDKEY"}` {
		t.Fatal(key)
	}
	_, phone := p.client("phone")
	if e := callError(t, phone, "", "clients/setWebPush", webPushKeys(t)); !strings.Contains(e, "browser") {
		t.Fatal(e)
	}
	m, browser := p.browserWithWebPush()
	bad := webPushKeys(t)
	for _, endpoint := range []string{"http://fcm.googleapis.com/x", "https://169.254.169.254/latest"} {
		bad["endpoint"] = endpoint
		if e := callError(t, browser, "", "clients/setWebPush", bad); !strings.Contains(e, "push service") {
			t.Fatal(endpoint, e)
		}
	}
	bad = webPushKeys(t)
	bad["auth"] = "AAAA"
	if e := callError(t, browser, "", "clients/setWebPush", bad); !strings.Contains(e, "keys") {
		t.Fatal(e)
	}
	// Gone at the push service: forgotten.
	box := p.host("MACHINE-2")
	_, _ = p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(pushNeed))
	p.waitFor(func() bool { return p.s.Records().Client(m.Client).WebPush == nil }, "the gone subscription forgotten")
	// No endpoint takes it away.
	call(t, browser, "", "clients/setWebPush", webPushKeys(t))
	call(t, browser, "", "clients/setWebPush", map[string]string{})
	if p.s.Records().Client(m.Client).WebPush != nil {
		t.Fatal("not taken away")
	}

	// With no VAPID key: no key to give, and no subscription taken.
	q := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, qw := q.client("window")
	if key := string(call(t, qw, "", "clients/webPushKey", nil)); key != `{}` {
		t.Fatal(key)
	}
	qm, qs := q.client("browser")
	_ = q.s.Records().ChangeClient(context.Background(), qm.Client, func(c *records.ClientRecord) bool { c.Kind = records.KindBrowser; return true })
	if e := callError(t, qs, "", "clients/setWebPush", webPushKeys(t)); !strings.Contains(e, "VAPID") {
		t.Fatal(e)
	}
}
