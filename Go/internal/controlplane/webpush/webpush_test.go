package webpush

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/rand"
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
	"testing"
	"time"
)

func b64(t *testing.T, s string) []byte {
	t.Helper()
	data, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// RFC 8291, Appendix A: the same keys and salt seal to the same bytes.
func TestSealIsRFC8291(t *testing.T) {
	ephemeral, err := ecdh.P256().NewPrivateKey(b64(t, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
	if err != nil {
		t.Fatal(err)
	}
	sub := Subscription{
		P256dh: b64(t, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"),
		Auth:   b64(t, "BTBZMqHH6r4Tts7J_aSIgg"),
	}
	got, err := seal(sub, []byte("When I grow up, I want to be a watermelon"), ephemeral, b64(t, "DGv6ra1nlYgDCS1FRnbzlw"))
	if err != nil {
		t.Fatal(err)
	}
	want := "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
	if s := base64.RawURLEncoding.EncodeToString(got); s != want {
		t.Fatalf("sealed\n%s\nwant\n%s", s, want)
	}
}

func TestSealRefusesWhatItCannotSeal(t *testing.T) {
	browser, _ := ecdh.P256().GenerateKey(rand.Reader)
	good := Subscription{P256dh: browser.PublicKey().Bytes(), Auth: make([]byte, 16)}
	if _, err := Seal(good, make([]byte, MaxPayload)); err != nil {
		t.Fatalf("the most a push carries: %v", err)
	}
	if _, err := Seal(good, make([]byte, MaxPayload+1)); err == nil {
		t.Fatal("one byte too many was sealed")
	}
	if _, err := Seal(Subscription{P256dh: good.P256dh, Auth: make([]byte, 8)}, nil); err == nil {
		t.Fatal("a short auth secret was taken")
	}
	if _, err := Seal(Subscription{P256dh: []byte("nope"), Auth: good.Auth}, nil); err == nil {
		t.Fatal("a key that is not one was taken")
	}
}

func writeKey(t *testing.T) (string, *ecdsa.PrivateKey) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	file := filepath.Join(t.TempDir(), "vapid-key")
	if err := os.WriteFile(file, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	return file, key
}

func TestNewReadsOnlyAP256Key(t *testing.T) {
	file, key := writeKey(t)
	c, err := New(Config{KeyFile: file})
	if err != nil {
		t.Fatal(err)
	}
	public, _ := key.PublicKey.Bytes()
	if c.PublicKey() != base64.RawURLEncoding.EncodeToString(public) {
		t.Fatal("the public key is not the key's")
	}
	sec1, _ := x509.MarshalECPrivateKey(key)
	other := filepath.Join(t.TempDir(), "sec1")
	_ = os.WriteFile(other, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: sec1}), 0o600)
	if _, err := New(Config{KeyFile: other}); err != nil {
		t.Fatalf("SEC 1: %v", err)
	}
	p384, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(p384)
	_ = os.WriteFile(other, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
	if _, err := New(Config{KeyFile: other}); err == nil || strings.Contains(err.Error(), "BEGIN") {
		t.Fatalf("a P-384 key: %v", err)
	}
	if _, err := New(Config{KeyFile: filepath.Join(t.TempDir(), "none")}); err == nil {
		t.Fatal("no file was taken")
	}
}

// open is what a browser does with a push: RFC 8291 from its side.
func open(t *testing.T, browser *ecdh.PrivateKey, auth, body []byte) []byte {
	t.Helper()
	salt, idlen := body[:16], int(body[20])
	serverKey := body[21 : 21+idlen]
	server, err := ecdh.P256().NewPublicKey(serverKey)
	if err != nil {
		t.Fatal(err)
	}
	shared, _ := browser.ECDH(server)
	info := append(append([]byte("WebPush: info\x00"), browser.PublicKey().Bytes()...), serverKey...)
	ikm, _ := hkdf.Key(sha256.New, shared, auth, string(info), 32)
	prk, _ := hkdf.Extract(sha256.New, ikm, salt)
	cek, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: aes128gcm\x00", 16)
	nonce, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: nonce\x00", 12)
	block, _ := aes.NewCipher(cek)
	gcm, _ := cipher.NewGCM(block)
	plain, err := gcm.Open(nil, nonce, body[21+idlen:], nil)
	if err != nil {
		t.Fatalf("the browser could not open it: %v", err)
	}
	if plain[len(plain)-1] != 2 {
		t.Fatal("not the last record")
	}
	return plain[:len(plain)-1]
}

func TestSendPostsASealedPushWithVAPID(t *testing.T) {
	file, key := writeKey(t)
	browser, _ := ecdh.P256().GenerateKey(rand.Reader)
	auth := make([]byte, 16)
	_, _ = rand.Read(auth)
	var got *http.Request
	var body []byte
	status := http.StatusCreated
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r
		body, _ = io.ReadAll(r.Body)
		w.WriteHeader(status)
	}))
	defer server.Close()
	now := time.Unix(1_800_000_000, 0)
	c, err := New(Config{KeyFile: file, Subject: "mailto:a@example.com", HTTP: server.Client(), Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	push := Push{Subscription: Subscription{Endpoint: server.URL + "/push/abc", P256dh: browser.PublicKey().Bytes(), Auth: auth},
		Payload: []byte(`{"alert":true}`), Urgent: true, Topic: "need1"}
	if err := c.Send(context.Background(), push); err != nil {
		t.Fatal(err)
	}
	if got.URL.Path != "/push/abc" || got.Header.Get("Content-Encoding") != "aes128gcm" || got.Header.Get("Urgency") != "high" ||
		got.Header.Get("Topic") != "need1" || got.Header.Get("TTL") != "86400" {
		t.Fatalf("headers: %v", got.Header)
	}
	if strings.Contains(string(body), "alert") || len(body) != 86+len(push.Payload)+1+16 {
		t.Fatalf("the body is not sealed: %d bytes", len(body))
	}
	if plain := open(t, browser, auth, body); string(plain) != `{"alert":true}` {
		t.Fatalf("opened: %q", plain)
	}
	// The VAPID token: signed by the key, for the push service's origin, from the subject.
	auth2 := got.Header.Get("Authorization")
	tPart, kPart, ok := strings.Cut(strings.TrimPrefix(auth2, "vapid t="), ", k=")
	if !ok || kPart != c.PublicKey() {
		t.Fatalf("Authorization: %q", auth2)
	}
	parts := strings.Split(tPart, ".")
	var claims struct {
		Aud string `json:"aud"`
		Exp int64  `json:"exp"`
		Sub string `json:"sub"`
	}
	_ = json.Unmarshal(b64(t, parts[1]), &claims)
	if claims.Aud != server.URL || claims.Sub != "mailto:a@example.com" || claims.Exp != now.Add(12*time.Hour).Unix() {
		t.Fatalf("claims: %+v", claims)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	signature := b64(t, parts[2])
	r, s := new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("the VAPID token is not signed by the key")
	}
	// A subscription the push service has forgotten is gone; another refusal is said.
	status = http.StatusGone
	if err := c.Send(context.Background(), push); !errors.Is(err, ErrGone) {
		t.Fatalf("410: %v", err)
	}
	status = http.StatusTooManyRequests
	if err := c.Send(context.Background(), push); err == nil || errors.Is(err, ErrGone) {
		t.Fatalf("429: %v", err)
	}
	push.Endpoint = "http://example.com/push"
	if err := c.Send(context.Background(), push); err == nil {
		t.Fatal("an http endpoint was posted to")
	}
}

func TestOnlyTheBrowsersPushServicesAreKnown(t *testing.T) {
	for _, endpoint := range []string{"https://fcm.googleapis.com/fcm/send/abc", "https://updates.push.services.mozilla.com/wpush/v2/x",
		"https://web.push.apple.com/QK", "https://wns2-par02p.notify.windows.com/w/?token=x"} {
		if !KnownService(endpoint) {
			t.Error("refused:", endpoint)
		}
	}
	for _, endpoint := range []string{"http://fcm.googleapis.com/x", "https://example.com/push", "https://169.254.169.254/",
		"https://evilgoogleapis.com/x", "https://fcm.googleapis.com:8443/x", "https://a@fcm.googleapis.com/x", "not a url"} {
		if KnownService(endpoint) {
			t.Error("taken:", endpoint)
		}
	}
}
