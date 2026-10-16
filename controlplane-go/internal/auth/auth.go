// Package auth is ControlAuth.swift, ControlCode.swift and the key derivations of
// ControlAgreement.swift in Go: the hello/auth/ok exchange every client, host and copy
// makes at the start of a WebSocket (058, R6, contracts/wire.md), and the v2 codes.
//
// The client half is the #1125 spike's internal/control/auth.go; this file adds the
// server's half and the codes a control plane makes.
package auth

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
	Version    = 1
	clientSalt = "agents-control-client-v1"
	hostSalt   = "agents-control-host-v1"
	codeSalt   = "agents-control-code-v1"
	copySalt   = "agents-copy-v1"
	codesSalt  = "agents-codes-v1"
)

// Reasons a connection is refused, as ControlAuth.Reason says them.
const (
	Unknown           = "unknown"
	Forgotten         = "forgotten"
	Expired           = "expired"
	Spent             = "spent"
	BadProof          = "bad-proof"
	WrongControlPlane = "wrong-control-plane"
	BadMessage        = "bad-message"
	Unavailable       = "unavailable"
)

// Refusal is a refused exchange, with its reason.
type Refusal struct{ Reason string }

func (r *Refusal) Error() string { return "refused: " + r.Reason }

func Refuse(reason string) error { return &Refusal{reason} }

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

func HMAC(key []byte, parts ...[]byte) []byte {
	m := hmac.New(sha256.New, key)
	for _, p := range parts {
		m.Write(p)
	}
	return m.Sum(nil)
}

// Keys

func NewPrivateKey() []byte {
	k, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	return k.Bytes()
}

func PublicKey(private []byte) ([]byte, error) {
	k, err := ecdh.P256().NewPrivateKey(private)
	if err != nil {
		return nil, err
	}
	return k.PublicKey().Bytes(), nil
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

// ClientKey is what a client (c:<UUID>) and the control plane share.
func ClientKey(private, peer []byte, client string) ([]byte, error) {
	shared, err := SharedSecret(private, peer)
	if err != nil {
		return nil, err
	}
	return hkdf32(shared, []byte(clientSalt), []byte(client)), nil
}

// HostKey is what a host (h:<id>) and the control plane share.
func HostKey(private, peer []byte, host string) ([]byte, error) {
	shared, err := SharedSecret(private, peer)
	if err != nil {
		return nil, err
	}
	return hkdf32(shared, []byte(hostSalt), []byte(host)), nil
}

// CopyKey is what every copy shares: from the control plane's private key alone.
func CopyKey(controlPrivate []byte) []byte { return hkdf32(controlPrivate, []byte(copySalt), nil) }

// CodeKey is what the holder of a code proves it with.
func CodeKey(secret []byte) []byte { return hkdf32(secret, []byte(codeSalt), nil) }

// Codes

func codeTag(controlPrivate, id []byte) []byte {
	key := hkdf32(controlPrivate, []byte(codesSalt), nil)
	return HMAC(key, []byte("agents-code-v1"), id)[:16]
}

// MakeCodeSecret is 16 random bytes and 16 bytes of tag only a copy can make, so any copy
// can check a code another showed, and the store holds only the id.
func MakeCodeSecret(controlPrivate []byte) (id string, secret []byte) {
	raw := make([]byte, 16)
	rand.Read(raw)
	return hex.EncodeToString(raw), append(raw, codeTag(controlPrivate, raw)...)
}

// CodeSecret is the secret a copy expects for a code id, or nil.
func CodeSecret(controlPrivate []byte, id string) []byte {
	raw, err := hex.DecodeString(id)
	if err != nil || len(raw) != 16 {
		return nil
	}
	return append(raw, codeTag(controlPrivate, raw)...)
}

// Code is a version 2 code: agents-control:2:<c|h>:<operator|->:<key>:<secret>:<url>:<pin|->:<name>.
type Code struct {
	Host       bool
	ControlKey []byte
	Secret     []byte
	URL        string
	Pin        string
	Name       string
}

// escape is addingPercentEncoding(withAllowedCharacters: alphanumerics + ".-_").
func escape(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func (c *Code) Text() string {
	kind, grant := "c", "operator"
	if c.Host {
		kind, grant = "h", "-"
	}
	pin := c.Pin
	if pin == "" {
		pin = "-"
	}
	return strings.Join([]string{"agents-control", "2", kind, grant, ToB64URL(c.ControlKey), ToB64URL(c.Secret),
		escape(c.URL), pin, escape(c.Name)}, ":")
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

func PeerMAC(key, serverNonce, peerNonce []byte, identity, origin string) []byte {
	return HMAC(key, []byte("c"), transcript(serverNonce, peerNonce, identity, origin))
}

func ServerMAC(key, serverNonce, peerNonce []byte, identity, origin string) []byte {
	return HMAC(key, []byte("s"), transcript(serverNonce, peerNonce, identity, origin))
}

func Nonce() []byte {
	b := make([]byte, 32)
	rand.Read(b)
	return b
}

// Messages

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
	For   string `json:"for,omitempty"`
	Epoch *int   `json:"epoch,omitempty"`
}

type OK struct {
	MAC       string          `json:"mac"`
	Grant     string          `json:"grant,omitempty"`
	Host      string          `json:"host,omitempty"`
	Relayed   *bool           `json:"relayed,omitempty"`
	Endpoints json.RawMessage `json:"endpoints,omitempty"`
	Epoch     *int            `json:"epoch,omitempty"`
}

func Line(tag string, body any) string {
	b, _ := json.Marshal(map[string]any{tag: body})
	return string(b)
}

func RefusedLine(reason string) string { return Line("refused", map[string]string{"reason": reason}) }

// ReadAuth reads a peer's {"auth":{…}} line.
func ReadAuth(line string) (*Auth, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &m); err != nil || len(m) != 1 {
		return nil, Refuse(BadMessage)
	}
	raw, ok := m["auth"]
	if !ok {
		return nil, Refuse(BadMessage)
	}
	var a Auth
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, Refuse(BadMessage)
	}
	return &a, nil
}

// Identity is who a peer says it is: c:<UUID>, h:<host>, p:<code id>, e:<code id>, x:<copy>.
type Identity struct {
	Kind byte // 'c', 'h', 'p', 'e', 'x'
	ID   string
}

func (i Identity) Text() string { return string(i.Kind) + ":" + i.ID }

func IsHostID(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

func isCodeID(s string) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == 16 && len(s) == 32
}

// IsUUID says whether s is a UUID as Swift's UUID(uuidString:) reads one.
func IsUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

func ParseIdentity(text string) (Identity, bool) {
	if len(text) < 3 || text[1] != ':' {
		return Identity{}, false
	}
	rest := text[2:]
	switch text[0] {
	case 'c':
		return Identity{'c', strings.ToUpper(rest)}, IsUUID(rest)
	case 'h':
		return Identity{'h', rest}, IsHostID(rest)
	case 'p', 'e':
		return Identity{text[0], rest}, isCodeID(rest)
	case 'x':
		return Identity{'x', rest}, len(rest) <= 64
	}
	return Identity{}, false
}

// Verify checks a peer's auth for a hello this copy sent. key finds the shared key for an
// identity, or refuses. Returns who it is and the server's MAC.
func Verify(a *Auth, serverNonce []byte, origins []string, key func(Identity) ([]byte, error)) (Identity, []byte, error) {
	id, ok := ParseIdentity(a.ID)
	peerNonce, err1 := B64URL(a.Nonce)
	mac, err2 := B64URL(a.MAC)
	if !ok || err1 != nil || len(peerNonce) != 32 || err2 != nil {
		return id, nil, Refuse(BadMessage)
	}
	shared, err := key(id)
	if err != nil {
		return id, nil, err
	}
	for _, origin := range origins {
		// The MAC binds the identity as the peer wrote it.
		if subtle.ConstantTimeCompare(mac, PeerMAC(shared, serverNonce, peerNonce, a.ID, origin)) == 1 {
			return id, ServerMAC(shared, serverNonce, peerNonce, a.ID, origin), nil
		}
	}
	return id, nil, Refuse(BadProof)
}
