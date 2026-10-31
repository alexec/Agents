package controllink

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Version is ControlAuth.version.
const Version = 1

// The exchange is three messages at the start of every WebSocket: the server's hello
// with a nonce, the peer's auth with a nonce and a MAC, and the server's ok with a MAC
// of its own, or refused. Each MAC is HMAC-SHA256 under a key both sides can derive and
// nobody else can:
//
//   - a client (c:<UUID>) or a host (h:<id>): HKDF of the ECDH of its key and the
//     control plane's;
//   - someone holding a code (p:<id>, e:<id>): HKDF of the code's secret;
//   - another copy (x:<copy>): HKDF of the control plane's private key alone.
//
// It runs inside TLS, which is what stops a relay in the middle: the MACs are not bound
// to the TLS session, so the peer must check the certificate or its pin.

// Hello is the server's first line. Control is the control plane's public key, X9.63,
// base64url.
type Hello = wire.ControlHello

// Auth is the peer's answer. Kind is mac, iphone, ipad, browser, host, relay or copy. For
// is a relayed device's id: agents-relay opens the socket for it (R10). Epoch is the epoch
// of the endpoints this peer holds (R16); nil from a build that keeps none.
type Auth = wire.ControlAuth

// OK is the server's proof back. Endpoints and Epoch say where the control plane answers
// now, and from when (R16).
type OK = wire.ControlOK

// NewKeyOffer is the control plane's new key in an ok, with its proof (#997).
type NewKeyOffer = wire.ControlNewKey

// Reasons a connection is refused, as ControlAuth.Reason says them.
const (
	Unknown           = "unknown"
	Forgotten         = "forgotten"
	Expired           = "expired"
	Spent             = "spent"
	BadProof          = "bad-proof"
	WrongControlPlane = "wrong-control-plane"
	BadMessage        = "bad-message"
	// The control plane could not tell, for now: its store could not be read, or a
	// handover is filling it. Try again; it says nothing about the member (#81).
	Unavailable = "unavailable"
	// The client's person was suspended by their org provider (#1002, D13). The client
	// keeps its key: it connects again once the suspension ends. A build from before it
	// reads it as a failed dial.
	Suspended = "suspended"
	// The client's key, or its person, holds as many sockets as it may (#2150): too many tabs
	// open in one browser, say. Try again; the page says to close one (#2194). A build from
	// before it reads it as a failed dial, as it did unavailable.
	Crowded = "crowded"
)

// Refusal is a refused exchange, with its reason.
type Refusal struct{ Reason string }

func (r *Refusal) Error() string { return "refused: " + r.Reason }

// Refuse makes a Refusal.
func Refuse(reason string) error { return &Refusal{reason} }

// Message is one line of the exchange: exactly one of its fields is set.
type Message struct {
	Hello   *Hello
	Auth    *Auth
	OK      *OK
	Refused string
}

// Line is the message as it goes on the wire: {"hello":{…}}, {"auth":{…}}, {"ok":{…}}
// or {"refused":{"reason":…}}.
func (m Message) Line() string {
	var body any
	tag := ""
	switch {
	case m.Hello != nil:
		tag, body = "hello", m.Hello
	case m.Auth != nil:
		tag, body = "auth", m.Auth
	case m.OK != nil:
		tag, body = "ok", m.OK
	default:
		tag, body = "refused", map[string]string{"reason": m.Refused}
	}
	b, _ := json.Marshal(map[string]any{tag: body})
	return string(b)
}

// ParseMessage reads a line of the exchange, or says it is not one.
func ParseMessage(line string) (Message, bool) {
	var m map[string]json.RawMessage
	if json.Unmarshal([]byte(line), &m) != nil || len(m) != 1 {
		return Message{}, false
	}
	for tag, raw := range m {
		switch tag {
		case "hello":
			var h Hello
			if json.Unmarshal(raw, &h) != nil {
				return Message{}, false
			}
			return Message{Hello: &h}, true
		case "auth":
			var a Auth
			if json.Unmarshal(raw, &a) != nil {
				return Message{}, false
			}
			return Message{Auth: &a}, true
		case "ok":
			var o OK
			if json.Unmarshal(raw, &o) != nil {
				return Message{}, false
			}
			return Message{OK: &o}, true
		case "refused":
			var r struct{ Reason string }
			if json.Unmarshal(raw, &r) != nil || !knownReason(r.Reason) {
				return Message{}, false
			}
			return Message{Refused: r.Reason}, true
		}
	}
	return Message{}, false
}

func knownReason(r string) bool {
	switch r {
	case Unknown, Forgotten, Expired, Spent, BadProof, WrongControlPlane, BadMessage, Unavailable, Suspended:
		return true
	}
	return false
}

// Identity is who a peer says it is.
type Identity struct {
	// 'c' client (a UUID, upper case), 's' a client signing in with no code (#995), 'h'
	// host, 'p' a client code's id, 'e' a host code's id, 'x' another copy, 'w' a host
	// carrying a page from its loopback listener (#1480), proved with the host's own key.
	Kind byte
	ID   string
}

func (i Identity) Text() string { return string(i.Kind) + ":" + i.ID }

// ParseIdentity reads an identity as ControlAuth.Identity(text:) does.
func ParseIdentity(text string) (Identity, bool) {
	if len(text) < 2 || text[1] != ':' {
		return Identity{}, false
	}
	rest := text[2:]
	switch text[0] {
	case 'c':
		return Identity{'c', strings.ToUpper(rest)}, IsUUID(rest)
	case 's':
		// A client signing in with no code (#995): the UUID it will pair as.
		return Identity{'s', strings.ToUpper(rest)}, IsUUID(rest)
	case 'h', 'w':
		return Identity{text[0], rest}, IsHostID(rest)
	case 'p', 'e':
		return Identity{text[0], rest}, IsCodeID(rest)
	case 'x':
		return Identity{'x', rest}, rest != "" && len([]rune(rest)) <= 64
	}
	return Identity{}, false
}

// IsHostID is ControlWire.isHostID: 1 to 64 of a–z, 0–9 and '-'.
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

// Origin is ControlAuth.origin: scheme://host:port, lower case, with the default port
// written out, so both ends agree whatever the dialled URL looked like. wss counts as
// https.
func Origin(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" || u.Hostname() == "" {
		return "", fmt.Errorf("%q has no origin", raw)
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
	// Foundation's URL.host gives an IPv6 address without its brackets, as Hostname does.
	return fmt.Sprintf("%s://%s:%s", scheme, strings.ToLower(u.Hostname()), port), nil
}

func transcript(serverNonce, peerNonce []byte, identity, origin string) []byte {
	b := []byte("agents-auth-v1")
	b = append(b, serverNonce...)
	b = append(b, peerNonce...)
	b = append(b, identity...)
	return append(b, origin...)
}

// PeerMAC is what the peer proves its key with.
func PeerMAC(key, serverNonce, peerNonce []byte, identity, origin string) []byte {
	return HMAC(key, []byte("c"), transcript(serverNonce, peerNonce, identity, origin))
}

// ServerMAC is what the server proves its key with.
func ServerMAC(key, serverNonce, peerNonce []byte, identity, origin string) []byte {
	return HMAC(key, []byte("s"), transcript(serverNonce, peerNonce, identity, origin))
}

// Nonce is 32 random bytes.
func Nonce() []byte {
	b := make([]byte, 32)
	rand.Read(b)
	return b
}

// Answer is the peer's side: what a client, a host or a copy says to hello, and the MAC
// it then expects in ok. controlKey is the key it already trusts (nil for none yet); a
// hello with any other is not its control plane.
func Answer(h *Hello, id Identity, key []byte, origin, kind string, controlKey []byte, device string, epoch *int) (*Auth, []byte, error) {
	serverNonce, err := FromB64URL(h.Nonce)
	if h.V != int64(Version) || err != nil || len(serverNonce) != 32 {
		return nil, nil, Refuse(BadMessage)
	}
	if controlKey != nil && !trusted(h, controlKey) {
		return nil, nil, Refuse(WrongControlPlane)
	}
	peerNonce := Nonce()
	text := id.Text()
	mac := PeerMAC(key, serverNonce, peerNonce, text, origin)
	expect := ServerMAC(key, serverNonce, peerNonce, text, origin)
	auth := &Auth{ID: text, Nonce: B64URL(peerNonce), Mac: B64URL(mac), Kind: kind}
	if device != "" {
		auth.For = &device
	}
	if epoch != nil {
		auth.Epoch = new(int64(*epoch))
	}
	return auth, expect, nil
}

// trusted is whether a hello is from the control plane a member trusts: its key now, or
// the one before it rotated (#997), which the member then proves itself with.
func trusted(h *Hello, controlKey []byte) bool {
	if theirs, err := FromB64URL(h.Control); err == nil && Same(theirs, controlKey) {
		return true
	}
	if h.Previous == nil {
		return false
	}
	before, err := FromB64URL(*h.Previous)
	return err == nil && Same(before, controlKey)
}

// NewKey is the control plane's new key from an ok (#997), checked against the member's
// shared key from the key it trusts: nil when the ok gives none, and a refusal when its
// proof is not the previous key's holder's.
func NewKey(ok *OK, shared []byte) ([]byte, error) {
	if ok == nil || ok.NewKey == nil {
		return nil, nil
	}
	key, err1 := FromB64URL(ok.NewKey.Key)
	proof, err2 := FromB64URL(ok.NewKey.Proof)
	if err1 != nil || err2 != nil || !ValidPublicKey(key) || !Same(proof, NewKeyProof(shared, key)) {
		return nil, Refuse(WrongControlPlane)
	}
	return key, nil
}

// Check is the peer's side: the server's ok against what Answer said to expect.
func Check(ok *OK, expect []byte) error {
	mac, err := FromB64URL(ok.Mac)
	if err != nil || !Same(mac, expect) {
		return Refuse(WrongControlPlane)
	}
	return nil
}

// Verify is the server's side: it checks a peer's auth for a hello this copy sent. key
// finds the shared key for an identity, or refuses. A control plane that answers at
// several places (R16) gives each origin: the peer's MAC may bind any one of them, and
// the server's binds the same one. It returns who the peer is and the server's MAC.
func Verify(a *Auth, serverNonce []byte, origins []string, key func(Identity) ([]byte, error)) (Identity, []byte, error) {
	id, ok := ParseIdentity(a.ID)
	peerNonce, err1 := FromB64URL(a.Nonce)
	mac, err2 := FromB64URL(a.Mac)
	if !ok || err1 != nil || len(peerNonce) != 32 || err2 != nil {
		return id, nil, Refuse(BadMessage)
	}
	shared, err := key(id)
	if err != nil {
		return id, nil, err
	}
	for _, origin := range origins {
		// The MAC binds the identity as the peer wrote it.
		if Same(mac, PeerMAC(shared, serverNonce, peerNonce, a.ID, origin)) {
			return id, ServerMAC(shared, serverNonce, peerNonce, a.ID, origin), nil
		}
	}
	return id, nil, Refuse(BadProof)
}
