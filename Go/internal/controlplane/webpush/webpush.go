// Package webpush posts the control plane's own notices to a browser (#1486): Web Push,
// with the payload sealed to the browser's keys (RFC 8291, the aes128gcm coding of RFC
// 8188), and the control plane named by its VAPID key (RFC 8292). The push service sees
// only the endpoint and the sealed bytes.
//
// It is written on the standard library: webpush-go, the one Go library for it, has had
// no release since January 2025, and what it does is about 200 lines here.
package webpush

import (
	"bytes"
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
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// MaxPayload is the most plaintext one push carries: a push service takes 4096 bytes,
// less the header (86), the tag (16) and the record's delimiter (1).
const MaxPayload = 4096 - 86 - 16 - 1

// ErrGone is a push service's 404 or 410: the subscription is over, and is forgotten.
var ErrGone = errors.New("the browser's subscription is gone")

// Subscription is where one browser's pushes go and the keys they are sealed with.
type Subscription struct {
	Endpoint string
	// The browser's P-256 public key, X9.63, and its 16-byte auth secret.
	P256dh, Auth []byte
}

// Push is one push: the plaintext to seal, and how the push service holds it.
type Push struct {
	Subscription
	Payload []byte
	// Urgent asks the push service to wake the browser now (an alert); otherwise normal.
	Urgent bool
	// Topic replaces a push of the same topic still waiting in the push service.
	Topic string
}

// Config is what the control plane is given to push: the VAPID key's file and who to
// write to about it.
type Config struct {
	KeyFile string
	// A mailto: or https: address the push service may write to; "" is the project's.
	Subject string
	// The HTTP client; nil is one of its own.
	HTTP *http.Client
	// The clock; nil is time.Now.
	Now func() time.Time
}

// services are the push services the browsers use, by the end of their host names: Chrome
// and Edge's FCM, Firefox's, Safari's and Windows'. A subscription elsewhere is refused, so
// a page cannot have the control plane post to an address of its choosing.
var services = []string{".googleapis.com", ".push.services.mozilla.com", ".push.apple.com", ".notify.windows.com"}

// KnownService says whether an endpoint is an https address at one of the browsers' push
// services.
func KnownService(endpoint string) bool {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" {
		return false
	}
	host := "." + strings.ToLower(u.Hostname())
	for _, service := range services {
		if strings.HasSuffix(host, service) {
			return true
		}
	}
	return false
}

// Subject is the address a push service is given when none is configured.
const Subject = "https://github.com/alexec/Agents"

// ttl is how long a push service keeps a push for a browser that is not running.
const ttl = 24 * time.Hour

// Client posts pushes with one VAPID key.
type Client struct {
	key     *ecdsa.PrivateKey
	public  []byte
	subject string
	http    *http.Client
	now     func() time.Time

	mu     sync.Mutex
	tokens map[string]token
}

type token struct {
	jwt    string
	issued time.Time
}

// New reads the VAPID key: a P-256 private key, PEM, as SEC 1 or PKCS #8. A key that is
// not there, or not one, is an error that names the file and never its contents.
func New(cfg Config) (*Client, error) {
	data, err := os.ReadFile(cfg.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("could not read the VAPID key %s: %w", cfg.KeyFile, err)
	}
	key, err := parseKey(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", cfg.KeyFile, err)
	}
	public, _ := key.PublicKey.Bytes()
	c := &Client{key: key, public: public, subject: cfg.Subject, http: cfg.HTTP, now: cfg.Now, tokens: map[string]token{}}
	if c.subject == "" {
		c.subject = Subject
	}
	if c.http == nil {
		c.http = &http.Client{Timeout: 30 * time.Second}
	}
	if c.now == nil {
		c.now = time.Now
	}
	return c, nil
}

func parseKey(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("the VAPID key is not PEM")
	}
	if key, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
		if key.Curve != elliptic.P256() {
			return nil, errors.New("the VAPID key is not P-256")
		}
		return key, nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("the VAPID key is not a private key")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("the VAPID key is not P-256")
	}
	return key, nil
}

// PublicKey is the VAPID public key as a page gives it to pushManager.subscribe:
// X9.63, base64url without padding.
func (c *Client) PublicKey() string { return base64.RawURLEncoding.EncodeToString(c.public) }

// Send seals one push and posts it to the browser's push service.
func (c *Client) Send(ctx context.Context, p Push) error {
	body, err := Seal(p.Subscription, p.Payload)
	if err != nil {
		return err
	}
	endpoint, err := url.Parse(p.Endpoint)
	if err != nil || endpoint.Scheme != "https" || endpoint.Host == "" {
		return errors.New("a push endpoint is an https address")
	}
	jwt, err := c.bearer(endpoint.Scheme + "://" + endpoint.Host)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.Endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Content-Encoding", "aes128gcm")
	req.Header.Set("TTL", strconv.Itoa(int(ttl.Seconds())))
	req.Header.Set("Authorization", "vapid t="+jwt+", k="+c.PublicKey())
	if p.Urgent {
		req.Header.Set("Urgency", "high")
	} else {
		req.Header.Set("Urgency", "normal")
	}
	if p.Topic != "" {
		req.Header.Set("Topic", p.Topic)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("could not reach the push service at %s: %w", endpoint.Host, err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	switch {
	case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
		return ErrGone
	case resp.StatusCode < 200 || resp.StatusCode > 299:
		return fmt.Errorf("the push service at %s said %d", endpoint.Host, resp.StatusCode)
	}
	return nil
}

// bearer is the VAPID token for one push service's origin: made again after an hour,
// good for twelve.
func (c *Client) bearer(audience string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if t, ok := c.tokens[audience]; ok && now.Sub(t.issued) < time.Hour {
		return t.jwt, nil
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"typ":"JWT","alg":"ES256"}`))
	claims, _ := json.Marshal(map[string]any{"aud": audience, "exp": now.Add(12 * time.Hour).Unix(), "sub": c.subject})
	signed := header + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signed))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	jwt := signed + "." + base64.RawURLEncoding.EncodeToString(signature)
	if len(c.tokens) >= 64 {
		clear(c.tokens)
	}
	c.tokens[audience] = token{jwt: jwt, issued: now}
	return jwt, nil
}

// Seal is RFC 8291: the plaintext as one aes128gcm record, sealed to the browser's keys
// with a key of its own.
func Seal(sub Subscription, plaintext []byte) ([]byte, error) {
	ephemeral, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	return seal(sub, plaintext, ephemeral, salt)
}

func seal(sub Subscription, plaintext []byte, ephemeral *ecdh.PrivateKey, salt []byte) ([]byte, error) {
	if len(plaintext) > MaxPayload {
		return nil, errors.New("too big for Web Push")
	}
	if len(sub.Auth) != 16 {
		return nil, errors.New("a browser's auth secret is 16 bytes")
	}
	browser, err := ecdh.P256().NewPublicKey(sub.P256dh)
	if err != nil {
		return nil, errors.New("a browser's key is a P-256 public key")
	}
	shared, err := ephemeral.ECDH(browser)
	if err != nil {
		return nil, err
	}
	server := ephemeral.PublicKey().Bytes()
	info := append(append([]byte("WebPush: info\x00"), sub.P256dh...), server...)
	ikm, err := hkdf.Key(sha256.New, shared, sub.Auth, string(info), 32)
	if err != nil {
		return nil, err
	}
	prk, err := hkdf.Extract(sha256.New, ikm, salt)
	if err != nil {
		return nil, err
	}
	cek, err := hkdf.Expand(sha256.New, prk, "Content-Encoding: aes128gcm\x00", 16)
	if err != nil {
		return nil, err
	}
	nonce, err := hkdf.Expand(sha256.New, prk, "Content-Encoding: nonce\x00", 12)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(cek)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	// The header: the salt, the record size, and the key the browser agrees a secret with.
	out := make([]byte, 0, 86+len(plaintext)+1+gcm.Overhead())
	out = append(out, salt...)
	out = binary.BigEndian.AppendUint32(out, 4096)
	out = append(out, 65) // the key's length: P-256, X9.63
	out = append(out, server...)
	// One record, the last: its delimiter is 2.
	return gcm.Seal(out, nonce, append(bytes.Clone(plaintext), 2), nil), nil
}
