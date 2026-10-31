package controllink

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// CodeLifetime is how long a code works: five minutes, once.
const CodeLifetime = 5 * time.Minute

// Code is ControlCode, version 2: what a new client or host needs and nothing more.
//
//	agents-control:2:<c|h>:-:<key>:<secret>:<url>:<pin or ->:<name>
//
// with the key and the secret in base64url, and the URL and name percent-encoded. The
// fourth field was a client's grant; every client may do everything now (#111), so it is
// always "-" and not read. The pin is the SHA-256 of the certificate's public key,
// base64url, when that certificate is not publicly trusted. A version 1 code (a list of
// addresses) is not read: no control plane has made one since the first build.
type Code struct {
	Host       bool
	ControlKey []byte // X9.63, 65 bytes
	Secret     []byte // a 16-byte id and a 16-byte tag
	URL        string
	Pin        string // "" for none
	Name       string
}

// Text is the code as one line, to paste or to put in a QR code.
func (c *Code) Text() string {
	kind := "c"
	if c.Host {
		kind = "h"
	}
	pin := c.Pin
	if pin == "" {
		pin = "-"
	}
	return strings.Join([]string{"agents-control", "2", kind, "-", B64URL(c.ControlKey), B64URL(c.Secret),
		escape(c.URL), pin, escape(c.Name)}, ":")
}

// ParseCode reads a version 2 code back from its text; whitespace around it, as a paste
// brings, is let go.
func ParseCode(text string) (*Code, error) {
	parts := strings.Split(strings.TrimSpace(text), ":")
	if len(parts) != 9 || parts[0] != "agents-control" || parts[1] != "2" {
		return nil, errors.New("not a version 2 control code")
	}
	key, err := FromB64URL(parts[4])
	if err != nil || len(key) != 65 || key[0] != 4 {
		return nil, errors.New("the code's key is not a P-256 public key")
	}
	secret, err := FromB64URL(parts[5])
	if err != nil || len(secret) != 32 {
		return nil, errors.New("the code's secret is not 32 bytes")
	}
	where, err1 := url.PathUnescape(parts[6])
	name, err2 := url.PathUnescape(parts[8])
	if err1 != nil || err2 != nil {
		return nil, errors.New("the code's address or name is not percent-encoded")
	}
	// https only, except on this machine: a walk or a test on loopback.
	u, err := url.Parse(where)
	if err != nil || u.Hostname() == "" {
		return nil, errors.New("the code's address is not a URL")
	}
	loopback := u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost" || u.Hostname() == "::1"
	if !(u.Scheme == "https" || u.Scheme == "wss" || u.Scheme == "http" && loopback) {
		return nil, errors.New("the code's address is not https")
	}
	pin := parts[7]
	if pin == "-" {
		pin = ""
	} else if b, err := FromB64URL(pin); err != nil || len(b) != 32 {
		return nil, errors.New("the code's pin is not 32 bytes")
	}
	c := &Code{ControlKey: key, Secret: secret, URL: where, Pin: pin, Name: name}
	switch {
	case parts[2] == "c" && parts[3] != "":
	case parts[2] == "h" && parts[3] == "-":
		c.Host = true
	default:
		return nil, errors.New("the code is neither a client's nor a host's")
	}
	return c, nil
}

// ID is what the holder of the code presents: hex of the secret's first 16 bytes.
func (c *Code) ID() string { return hex.EncodeToString(c.Secret[:16]) }

// escape is addingPercentEncoding(withAllowedCharacters: alphanumerics + ".-_"), for
// ASCII (Swift's alphanumerics take other letters too, but no URL or name a control
// plane makes has them unescaped: Foundation escapes them in UTF-8 as here).
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

// A code's secret is its id and a tag only a copy can make: 16 random bytes, then 16
// bytes of HMAC under a key from the control plane's private key. Any copy can check a
// code another copy showed, and the store holds only the id (rule 7).
func codeTag(controlPrivate, id []byte) []byte {
	key := HKDF(controlPrivate, []byte(CodesSalt), nil, 32)
	return HMAC(key, []byte("agents-code-v1"), id)[:16]
}

// MakeCodeSecret is a new code's id and secret.
func MakeCodeSecret(controlPrivate []byte) (id string, secret []byte) {
	raw := make([]byte, 16)
	rand.Read(raw)
	return hex.EncodeToString(raw), append(raw, codeTag(controlPrivate, raw)...)
}

// CodeSecret is the secret a copy expects for a code id, or nil if the id is not one.
func CodeSecret(controlPrivate []byte, id string) []byte {
	raw, err := hex.DecodeString(id)
	if err != nil || len(raw) != 16 {
		return nil
	}
	return append(raw, codeTag(controlPrivate, raw)...)
}

// IsCodeID says whether s is 32 hex digits.
func IsCodeID(s string) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == 16
}

// B64URL is base64url with no padding.
func B64URL(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// FromB64URL reads base64url, with or without its padding.
func FromB64URL(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
}
