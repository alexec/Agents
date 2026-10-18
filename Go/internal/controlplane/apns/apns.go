// Package apns posts the control plane's own pushes to Apple (#1460, public-security.md
// §5): for a device whose person has no Mac host relaying notices through iCloud. Token
// auth with the one .p8 key, HTTP/2. What is pushed is a generic alert and a sealed item;
// the Remote's Notification Service Extension opens it and shows the real words.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Topic is the one app id the key is scoped to: the Remote.
const Topic = "com.alexecollins.agents.remote"

// Apple's two hosts: a Debug build's tokens are the sandbox's.
const (
	Production  = "https://api.push.apple.com"
	Development = "https://api.sandbox.push.apple.com"
)

// Title is all a push says in clear: the same words CloudKit's subscription shows.
const Title = "An agent needs you"

// Config is what the control plane is given to push: the key's file, its id and the team.
type Config struct {
	KeyFile string
	KeyID   string
	TeamID  string
	// The app id; "" is Topic.
	Topic string
	// The two hosts, by environment, when not Apple's (tests).
	Hosts map[wire.PushEnvironment]string
	// The HTTP/2 client; nil is one of its own.
	HTTP *http.Client
	// The clock; nil is time.Now.
	Now func() time.Time
}

var keyID = regexp.MustCompile(`^[A-Z0-9]{10}$`)

// Client posts pushes with one key.
type Client struct {
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string
	topic  string
	hosts  map[wire.PushEnvironment]string
	http   *http.Client
	now    func() time.Time

	mu      sync.Mutex
	bearer  string
	issued  time.Time
	refused bool
}

// New reads the key. A key that is not there, or not a P-256 private key, is an error
// that names the file and never its contents.
func New(cfg Config) (*Client, error) {
	if !keyID.MatchString(cfg.KeyID) {
		return nil, errors.New("the APNs Key ID is 10 letters and digits, as the developer account shows it")
	}
	if !keyID.MatchString(cfg.TeamID) {
		return nil, errors.New("the Team ID is 10 letters and digits, as the developer account shows it")
	}
	data, err := os.ReadFile(cfg.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("could not read the APNs key %s", cfg.KeyFile)
	}
	key, err := parseKey(data)
	if err != nil {
		return nil, fmt.Errorf("the APNs key %s: %w", cfg.KeyFile, err)
	}
	c := &Client{key: key, keyID: cfg.KeyID, teamID: cfg.TeamID, topic: cfg.Topic, hosts: cfg.Hosts, http: cfg.HTTP, now: cfg.Now}
	if c.topic == "" {
		c.topic = Topic
	}
	if c.hosts == nil {
		c.hosts = map[wire.PushEnvironment]string{wire.PushEnvironmentProduction: Production,
			wire.PushEnvironmentDevelopment: Development}
	}
	if c.http == nil {
		// http.Transport speaks HTTP/2 to a TLS server that offers it, which Apple's do.
		c.http = &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{ForceAttemptHTTP2: true}}
	}
	if c.now == nil {
		c.now = time.Now
	}
	return c, nil
}

func parseKey(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("not a .p8 file (no PEM block)")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("not a PKCS #8 private key")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve.Params().Name != "P-256" {
		return nil, errors.New("not a P-256 key")
	}
	return key, nil
}

// token is the provider token: an ES256 JWT, made again every 40 minutes. Apple refuses
// one older than an hour and one made again more often than every 20 minutes.
func (c *Client) token() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.bearer != "" && !c.refused && now.Sub(c.issued) < 40*time.Minute {
		return c.bearer, nil
	}
	header := b64(mustJSON(map[string]string{"alg": "ES256", "kid": c.keyID}))
	claims := b64(mustJSON(map[string]any{"iss": c.teamID, "iat": now.Unix()}))
	signing := header + "." + claims
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS's ES256 signature is r and s, 32 bytes each, not DER.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	c.bearer, c.issued, c.refused = signing+"."+b64(sig), now, false
	return c.bearer, nil
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func mustJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}

// Push is one notification to one device.
type Push struct {
	// The device's token, hex, and which APNs it is from.
	Token       string
	Environment wire.PushEnvironment
	// An alert the extension opens (and may buzz), or a background push the app wakes for:
	// a move that must not buzz, or a withdrawal.
	Alert bool
	// apns-collapse-id: a later push for the same need replaces the banner.
	CollapseID string
	Sealed     wire.SealedEnvelope
}

// Payload is the JSON body: an aps that says only that an agent needs the person (or
// nothing, for a background push), and the sealed item under "agents".
func (p Push) Payload() []byte {
	aps := map[string]any{"content-available": 1}
	if p.Alert {
		aps = map[string]any{"alert": map[string]string{"title": Title}, "sound": "default", "mutable-content": 1}
	}
	return mustJSON(map[string]any{"aps": aps, "agents": wire.ControlPush{Sealed: p.Sealed}})
}

// MaxPayload is APNs's limit on a body, in bytes.
const MaxPayload = 4096

// ErrGone is a token Apple says is no longer the device's: forget it.
var ErrGone = errors.New("the device's push token is no longer valid")

var hexToken = regexp.MustCompile(`^[0-9a-f]{16,400}$`)

// ValidToken says whether a token is what a device's APNs token looks like: hex.
func ValidToken(token string) bool { return hexToken.MatchString(token) }

// Send posts one push. A refusal is an error with Apple's reason; ErrGone when the token
// should be forgotten.
func (c *Client) Send(ctx context.Context, p Push) error {
	host, ok := c.hosts[p.Environment]
	if !ok {
		return fmt.Errorf("no APNs for %q", p.Environment)
	}
	if !ValidToken(p.Token) {
		return ErrGone
	}
	body := p.Payload()
	if len(body) > MaxPayload {
		return fmt.Errorf("the push is %d bytes, more than APNs takes", len(body))
	}
	bearer, err := c.token()
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+p.Token, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("authorization", "bearer "+bearer)
	request.Header.Set("apns-topic", c.topic)
	request.Header.Set("content-type", "application/json")
	if p.Alert {
		request.Header.Set("apns-push-type", "alert")
		request.Header.Set("apns-priority", "10")
	} else {
		request.Header.Set("apns-push-type", "background")
		request.Header.Set("apns-priority", "5")
	}
	if p.CollapseID != "" {
		request.Header.Set("apns-collapse-id", p.CollapseID)
	}
	response, err := c.http.Do(request)
	if err != nil {
		return fmt.Errorf("APNs: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusOK {
		return nil
	}
	var reason struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&reason)
	switch {
	case response.StatusCode == http.StatusGone, reason.Reason == "BadDeviceToken", reason.Reason == "Unregistered",
		reason.Reason == "DeviceTokenNotForTopic":
		return ErrGone
	case reason.Reason == "ExpiredProviderToken", reason.Reason == "InvalidProviderToken":
		// Made again on the next push.
		c.mu.Lock()
		c.refused = true
		c.mu.Unlock()
	}
	return fmt.Errorf("APNs refused the push: %d %s", response.StatusCode, strings.TrimSpace(reason.Reason))
}
