// Package controllink is both ends of the link between a host or client and the control
// plane, as the Swift code speaks it (058, contracts/wire.md): a version 2 code, the
// hello/auth/ok key exchange of ControlAuth.swift, then channels on one WebSocket
// (ControlWire.swift). The host side is #1136's (the Go agentsd); the control plane's side
// is #1137's, which owns this package.
package controllink

import (
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

const (
	authVersion = 1
	hostSalt    = "agents-control-host-v1"
	codeSalt    = "agents-control-code-v1"
)

// Code is a version 2 control code: agents-control:2:<c|h>:<grant>:<key>:<secret>:<url>:<pin>:<name>.
type Code struct {
	Host       bool
	ControlKey []byte // X9.63, 65 bytes
	Secret     []byte // 32 bytes: a 16-byte id and a 16-byte tag
	URL        string
	Pin        string // base64url SHA-256 of the certificate's SPKI, or ""
	Name       string
}

func ParseCode(text string) (*Code, error) {
	parts := strings.Split(strings.TrimSpace(text), ":")
	if len(parts) != 9 || parts[0] != "agents-control" || parts[1] != "2" {
		return nil, errors.New("not a version 2 control code")
	}
	key, err := B64URL(parts[4])
	if err != nil || len(key) != 65 || key[0] != 4 {
		return nil, errors.New("the code's key is not a P-256 public key")
	}
	secret, err := B64URL(parts[5])
	if err != nil || len(secret) != 32 {
		return nil, errors.New("the code's secret is not 32 bytes")
	}
	where, err := url.PathUnescape(parts[6])
	if err != nil {
		return nil, err
	}
	name, err := url.PathUnescape(parts[8])
	if err != nil {
		return nil, err
	}
	c := &Code{Host: parts[2] == "h", ControlKey: key, Secret: secret, URL: where, Name: name}
	if parts[7] != "-" {
		c.Pin = parts[7]
	}
	return c, nil
}

// ID is what the holder of the code presents: hex of the secret's first 16 bytes.
func (c *Code) ID() string { return hex.EncodeToString(c.Secret[:16]) }

func B64URL(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
}
func ToB64URL(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func hkdf32(ikm, salt, info []byte) []byte {
	if len(salt) == 0 {
		salt = make([]byte, 32)
	}
	out, err := hkdf.Key(sha256.New, ikm, salt, string(info), 32)
	if err != nil {
		panic(err)
	}
	return out
}

func hmac256(key []byte, parts ...[]byte) []byte {
	m := hmac.New(sha256.New, key)
	for _, p := range parts {
		m.Write(p)
	}
	return m.Sum(nil)
}

// CodeKey is ControlAgreement.codeKey.
func CodeKey(secret []byte) []byte { return hkdf32(secret, []byte(codeSalt), nil) }

// HostKey is ControlAgreement.hostKey: HKDF of the ECDH of the host's key and the control plane's.
func HostKey(private, controlPublic []byte, host string) ([]byte, error) {
	shared, err := SharedSecret(private, controlPublic)
	if err != nil {
		return nil, err
	}
	return hkdf32(shared, []byte(hostSalt), []byte(host)), nil
}

func SharedSecret(private, peer []byte) ([]byte, error) {
	k, err := ecdh.P256().NewPrivateKey(private)
	if err != nil {
		return nil, err
	}
	p, err := ecdh.P256().NewPublicKey(peer)
	if err != nil {
		return nil, err
	}
	return k.ECDH(p)
}

func PublicKey(private []byte) ([]byte, error) {
	k, err := ecdh.P256().NewPrivateKey(private)
	if err != nil {
		return nil, err
	}
	return k.PublicKey().Bytes(), nil
}

func NewPrivateKey() []byte {
	k, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	return k.Bytes()
}

// Origin is ControlAuth.origin: scheme://host:port, wss as https, default port written out.
func Origin(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	scheme := strings.ToLower(u.Scheme)
	switch scheme {
	case "wss":
		scheme = "https"
	case "ws":
		scheme = "http"
	}
	port := u.Port()
	if port == "" {
		port = "80"
		if scheme == "https" {
			port = "443"
		}
	}
	return fmt.Sprintf("%s://%s:%s", scheme, strings.ToLower(u.Hostname()), port), nil
}

func transcript(serverNonce, peerNonce []byte, identity, origin string) []byte {
	var b []byte
	b = append(b, "agents-auth-v1"...)
	b = append(b, serverNonce...)
	b = append(b, peerNonce...)
	b = append(b, identity...)
	b = append(b, origin...)
	return b
}

type Hello struct {
	V       int    `json:"v"`
	Name    string `json:"name"`
	Control string `json:"control"`
	Nonce   string `json:"nonce"`
	Copy    string `json:"copy"`
}

type Auth struct {
	ID    string `json:"id"`
	Nonce string `json:"nonce"`
	MAC   string `json:"mac"`
	Kind  string `json:"kind"`
	Epoch *int   `json:"epoch,omitempty"`
}

type OK struct {
	MAC       string          `json:"mac"`
	Host      string          `json:"host,omitempty"`
	Endpoints json.RawMessage `json:"endpoints,omitempty"`
	Epoch     *int            `json:"epoch,omitempty"`
}

// Credentials are who a peer proves it is, and the key it proves it with.
type Credentials struct {
	Identity   string // e:<id> or h:<host>
	Key        []byte
	Kind       string
	ControlKey []byte
	Epoch      *int
}

// Answer reads the server's hello and says the auth line, and the MAC the ok must carry.
func Answer(helloLine string, cr Credentials, origin string) (authLine string, expect []byte, err error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(helloLine), &m); err != nil {
		return "", nil, err
	}
	raw, ok := m["hello"]
	if !ok {
		return "", nil, fmt.Errorf("expected hello, got %s", helloLine)
	}
	var h Hello
	if err := json.Unmarshal(raw, &h); err != nil {
		return "", nil, err
	}
	serverNonce, err := B64URL(h.Nonce)
	if h.V != authVersion || err != nil || len(serverNonce) != 32 {
		return "", nil, errors.New("bad-message")
	}
	if control, _ := B64URL(h.Control); cr.ControlKey != nil && subtle.ConstantTimeCompare(control, cr.ControlKey) != 1 {
		return "", nil, errors.New("wrong-control-plane")
	}
	peerNonce := make([]byte, 32)
	rand.Read(peerNonce)
	t := transcript(serverNonce, peerNonce, cr.Identity, origin)
	mac := hmac256(cr.Key, []byte("c"), t)
	expect = hmac256(cr.Key, []byte("s"), t)
	line, _ := json.Marshal(map[string]Auth{"auth": {ID: cr.Identity, Nonce: ToB64URL(peerNonce), MAC: ToB64URL(mac), Kind: cr.Kind, Epoch: cr.Epoch}})
	return string(line), expect, nil
}

// Check reads the server's ok (or refused) against what Answer said to expect.
func Check(line string, expect []byte) (*OK, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		return nil, err
	}
	if raw, ok := m["refused"]; ok {
		return nil, fmt.Errorf("refused: %s", raw)
	}
	var ok OK
	if err := json.Unmarshal(m["ok"], &ok); err != nil {
		return nil, err
	}
	mac, _ := B64URL(ok.MAC)
	if !hmac.Equal(mac, expect) {
		return nil, errors.New("wrong-control-plane: the ok's MAC does not match")
	}
	return &ok, nil
}
