package apns

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// FakeAPNs is Apple's push service as far as a test needs it: HTTP/2 over TLS, and every
// request kept.
type FakeAPNs struct {
	Server *httptest.Server
	mu     sync.Mutex
	got    []Request
	// What it answers: 200, or a status and a reason.
	Status int
	Reason string
}

// Request is one push as the fake saw it.
type Request struct {
	Proto  int
	Path   string
	Header http.Header
	Body   []byte
}

func NewFakeAPNs(t *testing.T) *FakeAPNs {
	f := &FakeAPNs{Status: http.StatusOK}
	f.Server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		f.mu.Lock()
		f.got = append(f.got, Request{r.ProtoMajor, r.URL.Path, r.Header.Clone(), body})
		status, reason := f.Status, f.Reason
		f.mu.Unlock()
		w.Header().Set("apns-id", "00000000-0000-4000-8000-000000000001")
		w.WriteHeader(status)
		if reason != "" {
			json.NewEncoder(w).Encode(map[string]string{"reason": reason})
		}
	}))
	f.Server.EnableHTTP2 = true
	f.Server.StartTLS()
	t.Cleanup(f.Server.Close)
	return f
}

func (f *FakeAPNs) Requests() []Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Request(nil), f.got...)
}

func (f *FakeAPNs) answer(status int, reason string) {
	f.mu.Lock()
	f.Status, f.Reason = status, reason
	f.mu.Unlock()
}

// writeKey makes a .p8 as the developer account gives one: PKCS #8, P-256, PEM.
func writeKey(t *testing.T) (string, *ecdsa.PrivateKey) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	file := filepath.Join(t.TempDir(), "AuthKey_ABCDE12345.p8")
	os.WriteFile(file, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
	return file, key
}

func newClient(t *testing.T, f *FakeAPNs, now func() time.Time) (*Client, *ecdsa.PrivateKey) {
	file, key := writeKey(t)
	c, err := New(Config{KeyFile: file, KeyID: "ABCDE12345", TeamID: "6T4RVD5724", Now: now, HTTP: f.Server.Client(),
		Hosts: map[wire.PushEnvironment]string{wire.PushEnvironmentDevelopment: f.Server.URL, wire.PushEnvironmentProduction: f.Server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	return c, key
}

func verify(token string, key *ecdsa.PublicKey) bool {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return false
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	return ecdsa.Verify(key, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
}

func claims(t *testing.T, token string) (header, body map[string]any) {
	parts := strings.Split(token, ".")
	h, _ := base64.RawURLEncoding.DecodeString(parts[0])
	b, _ := base64.RawURLEncoding.DecodeString(parts[1])
	json.Unmarshal(h, &header)
	json.Unmarshal(b, &body)
	return
}

const deviceToken = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"

func device(t *testing.T) *ecdh.PrivateKey {
	k, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// An alert goes over HTTP/2 to the device's path, with a provider token Apple can check
// with the key's public half, the one app id, and nothing legible but the generic title.
func TestAnAlertIsPostedOverHTTP2WithTokenAuth(t *testing.T) {
	f := NewFakeAPNs(t)
	c, key := newClient(t, f, nil)
	phone := device(t)
	headline := wire.Headline{H1: "brushwise", H2: "Rehang the gallery", H3: "Wants to write hello.txt"}
	need := wire.UUID("E0000000-0000-4000-8000-000000000005")
	item, _ := json.Marshal(wire.ControlPushItem{NeedID: wire.NeedID{Permission: &need}, Alert: true, Headline: &headline})
	sealed, err := Seal(phone.PublicKey().Bytes(), Purpose, item)
	if err != nil {
		t.Fatal(err)
	}
	push := Push{Token: deviceToken, Environment: wire.PushEnvironmentDevelopment, Alert: true,
		CollapseID: CollapseID(wire.NeedID{Permission: &need}), Sealed: sealed}
	if err := c.Send(context.Background(), push); err != nil {
		t.Fatal(err)
	}
	got := f.Requests()
	if len(got) != 1 {
		t.Fatal(len(got))
	}
	r := got[0]
	if r.Proto != 2 {
		t.Fatalf("HTTP/%d, not HTTP/2", r.Proto)
	}
	if r.Path != "/3/device/"+deviceToken {
		t.Fatal(r.Path)
	}
	for name, want := range map[string]string{"apns-topic": Topic, "apns-push-type": "alert", "apns-priority": "10",
		"apns-collapse-id": "permission:E0000000-0000-4000-8000-000000000005"} {
		if r.Header.Get(name) != want {
			t.Errorf("%s: %q, not %q", name, r.Header.Get(name), want)
		}
	}
	bearer := strings.TrimPrefix(r.Header.Get("authorization"), "bearer ")
	if !verify(bearer, &key.PublicKey) {
		t.Fatal("the provider token is not signed by the key")
	}
	header, body := claims(t, bearer)
	if header["alg"] != "ES256" || header["kid"] != "ABCDE12345" || body["iss"] != "6T4RVD5724" || body["iat"] == nil {
		t.Fatal(header, body)
	}
	// Apple reads the alert: only the generic title, and nothing of the need.
	for _, word := range []string{"brushwise", "Rehang", "hello.txt", "Wants to", "E0000000"} {
		if strings.Contains(string(r.Body), word) {
			t.Fatalf("%q is legible in %s", word, r.Body)
		}
	}
	var payload struct {
		APS struct {
			Alert          map[string]string `json:"alert"`
			MutableContent int               `json:"mutable-content"`
		} `json:"aps"`
		Agents wire.ControlPush `json:"agents"`
	}
	if err := json.Unmarshal(r.Body, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.APS.Alert["title"] != Title || len(payload.APS.Alert) != 1 || payload.APS.MutableContent != 1 {
		t.Fatal(string(r.Body))
	}
	// The device opens it, and only the device.
	plaintext, err := Open(phone, Purpose, payload.Agents.Sealed)
	if err != nil {
		t.Fatal(err)
	}
	var opened wire.ControlPushItem
	json.Unmarshal(plaintext, &opened)
	if opened.Headline == nil || opened.Headline.H2 != "Rehang the gallery" || !opened.Alert {
		t.Fatal(string(plaintext))
	}
	if _, err := Open(device(t), Purpose, payload.Agents.Sealed); err == nil {
		t.Fatal("another device opened it")
	}
	if _, err := Open(phone, "com.alexecollins.agents.headline.v1", payload.Agents.Sealed); err == nil {
		t.Fatal("opened as a headline")
	}
}

// A move that must not buzz, and a withdrawal, wake the app in the background instead.
func TestAQuietPushIsABackgroundPush(t *testing.T) {
	f := NewFakeAPNs(t)
	c, _ := newClient(t, f, nil)
	sealed, _ := Seal(device(t).PublicKey().Bytes(), Purpose, []byte(`{}`))
	if err := c.Send(context.Background(), Push{Token: deviceToken, Environment: wire.PushEnvironmentProduction, Sealed: sealed}); err != nil {
		t.Fatal(err)
	}
	r := f.Requests()[0]
	if r.Header.Get("apns-push-type") != "background" || r.Header.Get("apns-priority") != "5" {
		t.Fatal(r.Header)
	}
	if !strings.Contains(string(r.Body), `"content-available":1`) || strings.Contains(string(r.Body), Title) {
		t.Fatal(string(r.Body))
	}
}

// A Live Activity's update goes to the activity's topic as a liveactivity push, with its
// content state in the aps and a timestamp; an end says when it leaves the Lock Screen
// (#1744).
func TestALiveActivityPushHasItsOwnTopicAndType(t *testing.T) {
	f := NewFakeAPNs(t)
	c, _ := newClient(t, f, nil)
	at := time.Unix(1_800_000_000, 0)
	state := json.RawMessage(`{"phase":"working","startedAt":800000000}`)
	if err := c.Send(context.Background(), Push{Token: deviceToken, Environment: wire.PushEnvironmentDevelopment,
		Activity: &Activity{State: state, Timestamp: at}}); err != nil {
		t.Fatal(err)
	}
	end := Push{Token: deviceToken, Environment: wire.PushEnvironmentDevelopment,
		Activity: &Activity{State: state, Timestamp: at, End: true, Dismiss: at.Add(15 * time.Minute), Urgent: true}}
	if err := c.Send(context.Background(), end); err != nil {
		t.Fatal(err)
	}
	update, ended := f.Requests()[0], f.Requests()[1]
	if update.Path != "/3/device/"+deviceToken || update.Header.Get("apns-topic") != "com.alexecollins.agents.remote.push-type.liveactivity" ||
		update.Header.Get("apns-push-type") != "liveactivity" || update.Header.Get("apns-priority") != "5" {
		t.Fatal(update.Path, update.Header)
	}
	if got := string(update.Body); got != `{"aps":{"content-state":{"phase":"working","startedAt":800000000},"event":"update","timestamp":1800000000}}` {
		t.Fatal(got)
	}
	if ended.Header.Get("apns-priority") != "10" {
		t.Fatal(ended.Header)
	}
	if got := string(ended.Body); !strings.Contains(got, `"event":"end"`) || !strings.Contains(got, `"dismissal-date":1800000900`) {
		t.Fatal(got)
	}
}

// One provider token for 40 minutes, then a new one; and a new one at once after Apple
// says it has expired.
func TestTheProviderTokenIsMadeAgain(t *testing.T) {
	f := NewFakeAPNs(t)
	now := time.Unix(2_000_000_000, 0)
	c, _ := newClient(t, f, func() time.Time { return now })
	sealed, _ := Seal(device(t).PublicKey().Bytes(), Purpose, []byte(`{}`))
	send := func() string {
		c.Send(context.Background(), Push{Token: deviceToken, Environment: wire.PushEnvironmentProduction, Sealed: sealed})
		got := f.Requests()
		return got[len(got)-1].Header.Get("authorization")
	}
	first := send()
	now = now.Add(39 * time.Minute)
	if send() != first {
		t.Fatal("made again too soon")
	}
	now = now.Add(2 * time.Minute)
	second := send()
	if second == first {
		t.Fatal("not made again after 40 minutes")
	}
	f.answer(http.StatusForbidden, "ExpiredProviderToken")
	if err := c.Send(context.Background(), Push{Token: deviceToken, Environment: wire.PushEnvironmentProduction, Sealed: sealed}); err == nil ||
		!strings.Contains(err.Error(), "ExpiredProviderToken") {
		t.Fatal(err)
	}
	f.answer(http.StatusOK, "")
	now = now.Add(time.Second)
	if send() == second {
		t.Fatal("an expired token was used again")
	}
}

// A token Apple no longer knows is ErrGone, so it is forgotten; another refusal is not.
func TestAGoneTokenSaysSo(t *testing.T) {
	f := NewFakeAPNs(t)
	c, _ := newClient(t, f, nil)
	sealed, _ := Seal(device(t).PublicKey().Bytes(), Purpose, []byte(`{}`))
	push := Push{Token: deviceToken, Environment: wire.PushEnvironmentProduction, Sealed: sealed}
	for _, refusal := range []struct {
		status int
		reason string
	}{{http.StatusGone, "Unregistered"}, {http.StatusBadRequest, "BadDeviceToken"}} {
		f.answer(refusal.status, refusal.reason)
		if err := c.Send(context.Background(), push); !errors.Is(err, ErrGone) {
			t.Fatal(refusal, err)
		}
	}
	f.answer(http.StatusTooManyRequests, "TooManyRequests")
	if err := c.Send(context.Background(), push); err == nil || errors.Is(err, ErrGone) {
		t.Fatal(err)
	}
	push.Token = "not hex"
	if err := c.Send(context.Background(), push); !errors.Is(err, ErrGone) {
		t.Fatal(err)
	}
}

// A key that is not there or not Apple's kind, or a Key ID that is not one, starts no
// client, and the error names no part of the key.
func TestABadKeyIsRefused(t *testing.T) {
	file, _ := writeKey(t)
	if _, err := New(Config{KeyFile: file, KeyID: "short", TeamID: "6T4RVD5724"}); err == nil {
		t.Fatal("a bad Key ID")
	}
	if _, err := New(Config{KeyFile: file, KeyID: "ABCDE12345", TeamID: ""}); err == nil {
		t.Fatal("no Team ID")
	}
	if _, err := New(Config{KeyFile: filepath.Join(t.TempDir(), "none.p8"), KeyID: "ABCDE12345", TeamID: "6T4RVD5724"}); err == nil {
		t.Fatal("no file")
	}
	rsaKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(rsaKey)
	other := filepath.Join(t.TempDir(), "rsa.p8")
	text := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	os.WriteFile(other, text, 0o600)
	_, err := New(Config{KeyFile: other, KeyID: "ABCDE12345", TeamID: "6T4RVD5724"})
	if err == nil || !strings.Contains(err.Error(), "P-256") {
		t.Fatal(err)
	}
	if strings.Contains(err.Error(), string(text[30:60])) {
		t.Fatal("the error holds the key")
	}
}

// A need's token is Swift's NeedID.token, and its collapse id names no file.
func TestTokensAndCollapseIDs(t *testing.T) {
	id := wire.UUID("e0000000-0000-4000-8000-000000000005")
	if got := Token(wire.NeedID{Permission: &id}); got != "permission:E0000000-0000-4000-8000-000000000005" {
		t.Fatal(got)
	}
	if got := Token(wire.NeedID{Report: &wire.NeedIDReport{AgentID: id, At: 800000000}}); got != "report:E0000000-0000-4000-8000-000000000005:800000000.0" {
		t.Fatal(got)
	}
	if got := Token(wire.NeedID{Report: &wire.NeedIDReport{AgentID: id, At: 800000000.25}}); !strings.HasSuffix(got, ":800000000.25") {
		t.Fatal(got)
	}
	guarded := wire.NeedID{GuardedChange: &wire.NeedIDGuardedChange{Folder: "file:///Users/me/secret-folder/", Path: "plan.md"}}
	if got := Token(guarded); got != "guarded:/Users/me/secret-folder/:plan.md" {
		t.Fatal(got)
	}
	if c := CollapseID(guarded); strings.Contains(c, "secret") || len(c) != 64 {
		t.Fatal(c)
	}
	notice := "e0000000-0000-4000-8000-000000000006"
	if got := Token(wire.NeedID{Notice: &notice}); got != "notice:"+notice {
		t.Fatal(got)
	}
}

// Cut before it is sealed, as Headline.truncating does.
func TestAHeadlineIsCutToItsBudget(t *testing.T) {
	long := strings.Repeat("ü", 150)
	h := Truncated(wire.Headline{H1: "  ", H2: long, H3: "ok", Answers: []wire.QuickAnswer{
		{Kind: wire.QuickAnswerKindReply, ID: "r"}, {Kind: wire.QuickAnswerKindChoice, ID: "allow", Title: long}}})
	if h.H1 != "Agents" || len([]rune(h.H2)) != Budget || !strings.HasSuffix(h.H2, "…") || h.H3 != "ok" {
		t.Fatal(h)
	}
	if h.Answers[0].Title != "Reply" || len([]rune(h.Answers[1].Title)) != AnswerBudget {
		t.Fatal(h.Answers)
	}
}

// The fixture the Remote's own test opens (ControlPushTests): a push sealed here, with
// the device key that opens it. Written again with APNS_WRITE_FIXTURE=1; checked here
// to open, so the file is never stale.
func TestTheSwiftFixtureOpens(t *testing.T) {
	file := filepath.Join("testdata", "control-push.json")
	type fixture struct {
		DevicePrivateKey []byte          `json:"devicePrivateKey"`
		Push             json.RawMessage `json:"push"`
		Item             json.RawMessage `json:"item"`
	}
	if os.Getenv("APNS_WRITE_FIXTURE") == "1" {
		phone := device(t)
		agent := wire.UUID("A0000000-0000-4000-8000-000000000001")
		headline := Truncated(wire.Headline{H1: "brushwise", H2: "Rehang the gallery", H3: "Wants to write hello.txt",
			Answers: []wire.QuickAnswer{{Kind: wire.QuickAnswerKindChoice, ID: "allow", Title: "Allow"}}})
		item, _ := json.Marshal(wire.ControlPushItem{NeedID: wire.NeedID{Report: &wire.NeedIDReport{AgentID: agent, At: 800000000.5}},
			Alert: true, Headline: &headline})
		sealed, err := Seal(phone.PublicKey().Bytes(), Purpose, item)
		if err != nil {
			t.Fatal(err)
		}
		push := Push{Token: deviceToken, Alert: true, Sealed: sealed}
		data, _ := json.MarshalIndent(fixture{phone.Bytes(), push.Payload(), item}, "", "  ")
		os.MkdirAll("testdata", 0o755)
		if err := os.WriteFile(file, append(data, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var f fixture
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	key, err := ecdh.P256().NewPrivateKey(f.DevicePrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	var payload struct {
		Agents wire.ControlPush `json:"agents"`
	}
	json.Unmarshal(f.Push, &payload)
	plaintext, err := Open(key, Purpose, payload.Agents.Sealed)
	if err != nil {
		t.Fatal(err)
	}
	var item bytes.Buffer
	json.Compact(&item, f.Item)
	if string(plaintext) != item.String() {
		t.Fatalf("%s\n%s", plaintext, item.String())
	}
	if strings.Contains(string(f.Push), "Rehang") {
		t.Fatal("legible")
	}
}
