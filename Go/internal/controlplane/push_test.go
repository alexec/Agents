package controlplane

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/apns"
	"github.com/alexec/agents/Go/internal/controlplane/notices"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// fakePusher keeps every push, and answers with what it is told to.
type fakePusher struct {
	mu     sync.Mutex
	pushes []apns.Push
	answer error
}

func (f *fakePusher) Send(_ context.Context, p apns.Push) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pushes = append(f.pushes, p)
	return f.answer
}

func (f *fakePusher) sent() []apns.Push {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]apns.Push(nil), f.pushes...)
}

const pushDeviceToken = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"

// phoneWithToken pairs a phone that may notify and gives its push token over its own
// session, as the Remote does.
func (p *plane) phoneWithToken() (*controllink.ClientMembership, *controllink.Session) {
	m, session := p.client("phone")
	yes := true
	if err := p.s.Records().ChangeClient(context.Background(), m.Client, func(c *records.ClientRecord) bool {
		c.Kind, c.MayNotify = records.KindIPhone, &yes
		return true
	}); err != nil {
		p.t.Fatal(err)
	}
	call(p.t, session, "", "clients/setPushToken", map[string]string{"token": strings.ToUpper(pushDeviceToken), "environment": "development"})
	return m, session
}

func openPush(t *testing.T, m *controllink.ClientMembership, push apns.Push) wire.ControlPushItem {
	t.Helper()
	key, err := ecdh.P256().NewPrivateKey(m.Private)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := apns.Open(key, apns.Purpose, push.Sealed)
	if err != nil {
		t.Fatal(err)
	}
	var item wire.ControlPushItem
	json.Unmarshal(plaintext, &item)
	return item
}

const pushNeed = `{"need":{"id":{"permission":"E0000000-0000-4000-8000-000000000005"},"agentID":"A0000000-0000-4000-8000-000000000001",` +
	`"folder":"file:///work","kind":"permission","raisedAt":800000000,"headline":{"h1":"work","h2":"Fix the gallery","h3":"may run"}},"buzz":true}`

// With no Mac host relaying, the control plane pushes the need itself: sealed to the
// phone that gave its token, then a background push that takes it back (#1460).
func TestANeedIsPushedThroughAPNsWithNoRelay(t *testing.T) {
	pusher := &fakePusher{}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.Push = pusher })
	box := p.host("MACHINE-2")
	m, _ := p.phoneWithToken()
	record := p.s.Records().Client(m.Client)
	if record.PushToken == nil || record.PushToken.Token != pushDeviceToken || record.PushToken.Environment != "development" {
		t.Fatal(record.PushToken)
	}

	if _, err := p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(pushNeed)); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool { return len(pusher.sent()) == 1 }, "a push")
	push := pusher.sent()[0]
	if push.Token != pushDeviceToken || push.Environment != wire.PushEnvironmentDevelopment || !push.Alert ||
		push.CollapseID != "permission:E0000000-0000-4000-8000-000000000005" {
		t.Fatal(push)
	}
	if body := string(push.Payload()); strings.Contains(body, "Fix the gallery") || strings.Contains(body, "E0000000") {
		t.Fatal("legible:", body)
	}
	item := openPush(t, m, push)
	if !item.Alert || item.Headline == nil || item.Headline.H2 != "Fix the gallery" || item.NeedID.Permission == nil {
		t.Fatal(item)
	}

	// The same need again changes nothing; met, it is taken back, quietly.
	p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(pushNeed))
	p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(`{"withdraw":{"permission":"E0000000-0000-4000-8000-000000000005"}}`))
	p.waitFor(func() bool { return len(pusher.sent()) == 2 }, "the withdrawal")
	time.Sleep(100 * time.Millisecond)
	if n := len(pusher.sent()); n != 2 {
		t.Fatal(n, "pushes: one arrived twice")
	}
	withdrawal := pusher.sent()[1]
	if withdrawal.Alert {
		t.Fatal("a withdrawal buzzed")
	}
	if item := openPush(t, m, withdrawal); item.Headline != nil || item.Alert {
		t.Fatal(item)
	}
	// The token is the device's alone: clients/list does not say it.
	_, session := p.client("window")
	if list := string(call(t, session, "", "clients/list", nil)); strings.Contains(list, pushDeviceToken) || strings.Contains(list, "pushToken") {
		t.Fatal(list)
	}
}

// With a relay host online, it carries the need as before, and nothing is pushed: one
// way, so one banner.
func TestARelayHostMeansNoPush(t *testing.T) {
	pusher := &fakePusher{}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.Push = pusher })
	_, relay := p.rawHost("relay mac", true)
	box := p.host("MACHINE-2")
	m, _ := p.phoneWithToken()
	p.s.tellRelayDevices()
	readUntil(t, relay, m.Client)
	if _, err := p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(pushNeed)); err != nil {
		t.Fatal(err)
	}
	if line := readUntil(t, relay, "relay/deliver"); !strings.Contains(line, `"h2":"Fix the gallery"`) {
		t.Fatal(line)
	}
	time.Sleep(200 * time.Millisecond)
	if n := len(pusher.sent()); n != 0 {
		t.Fatal(n, "pushed beside the relay")
	}
}

// Only a device sets a token, only its own, and only a token; a token Apple says is gone
// is forgotten.
func TestOnlyADeviceSetsItsOwnToken(t *testing.T) {
	pusher := &fakePusher{answer: apns.ErrGone}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.Push = pusher })
	_, window := p.client("window")
	if e := callError(t, window, "", "clients/setPushToken", map[string]string{"token": pushDeviceToken, "environment": "production"}); !strings.Contains(e, "iPhone") {
		t.Fatal(e)
	}
	box := p.host("MACHINE-2")
	m, phone := p.phoneWithToken()
	if e := callError(t, phone, "", "clients/setPushToken", map[string]string{"token": "not a token", "environment": "production"}); !strings.Contains(e, "not a push token") {
		t.Fatal(e)
	}
	if e := callError(t, phone, "", "clients/setPushToken", map[string]string{"token": pushDeviceToken, "environment": "staging"}); e == "" {
		t.Fatal(e)
	}
	p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(pushNeed))
	p.waitFor(func() bool { return p.s.Records().Client(m.Client).PushToken == nil }, "the gone token forgotten")
	// And with no token, the device sets none by saying none.
	call(t, phone, "", "clients/setPushToken", map[string]string{"token": pushDeviceToken, "environment": "production"})
	call(t, phone, "", "clients/setPushToken", map[string]string{"environment": "production"})
	if p.s.Records().Client(m.Client).PushToken != nil {
		t.Fatal("not taken away")
	}
}

// With no key, nothing is pushed, and the log says so once.
func TestNoKeyMeansNoPushesAndSaysSo(t *testing.T) {
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.host("MACHINE-2")
	p.phoneWithToken()
	p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(pushNeed))
	said := 0
	for {
		select {
		case line := <-p.lines:
			if strings.Contains(line, "no APNs key") {
				said++
			}
			if strings.Contains(line, "through APNs") {
				t.Fatal(line)
			}
			continue
		case <-time.After(200 * time.Millisecond):
		}
		break
	}
	if said != 1 {
		t.Fatal(said)
	}
}

// A push too big for APNs loses its buttons before it loses its words.
func TestAPushTooBigLosesItsButtonsFirst(t *testing.T) {
	key, _ := ecdh.P256().GenerateKey(rand.Reader)
	id := wire.UUID("E0000000-0000-4000-8000-000000000005")
	var answers []wire.QuickAnswer
	for i := range 60 {
		answers = append(answers, wire.QuickAnswer{Kind: wire.QuickAnswerKindChoice, ID: strings.Repeat("x", 30) + string(rune('a'+i%26)), Title: strings.Repeat("y", 40)})
	}
	delivery := notices.RelayDelivery{NeedID: wire.NeedID{Permission: &id}, Device: "D0000000-0000-4000-8000-000000000001",
		Headline: &wire.Headline{H1: "a", H2: "b", H3: "c", Answers: answers}, Alert: true}
	push, err := sealPush(delivery, key.PublicKey().Bytes(), records.PushToken{Token: pushDeviceToken, Environment: "production"})
	if err != nil {
		t.Fatal(err)
	}
	if len(push.Payload()) > apns.MaxPayload {
		t.Fatal(len(push.Payload()))
	}
	plaintext, _ := apns.Open(key, apns.Purpose, push.Sealed)
	var item wire.ControlPushItem
	json.Unmarshal(plaintext, &item)
	if item.Headline == nil || item.Headline.H2 != "b" || len(item.Headline.Answers) != 0 {
		t.Fatal(string(plaintext))
	}
}
