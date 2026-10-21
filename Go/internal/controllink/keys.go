// Package controllink is both sides of the exchange between the control plane and its
// members (058, research R6, contracts/wire.md): the P-256 agreement and key derivations
// of ControlAgreement.swift, the hello/auth/ok exchange of ControlAuth.swift, and the
// codes of ControlCode.swift. The bytes are Swift's: Web/test/vectors.json holds the two
// to the same answers. Shared by agents-control (the server's side) and agentsd (a
// host's side).
package controllink

import (
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const (
	ClientSalt = "agents-control-client-v1"
	HostSalt   = "agents-control-host-v1"
	CodeSalt   = "agents-control-code-v1"
	CopySalt   = "agents-copy-v1"
	CodesSalt  = "agents-codes-v1"
)

// HKDF is HKDF-SHA256 (RFC 5869) as ControlAgreement.hkdfSHA256 has it: an empty salt is
// 32 zero bytes.
func HKDF(ikm, salt, info []byte, length int) []byte {
	if len(salt) == 0 {
		salt = make([]byte, 32)
	}
	out, err := hkdf.Key(sha256.New, ikm, salt, string(info), length)
	if err != nil {
		panic(err)
	}
	return out
}

// HMAC is HMAC-SHA256 of the parts, one after the other.
func HMAC(key []byte, parts ...[]byte) []byte {
	m := hmac.New(sha256.New, key)
	for _, p := range parts {
		m.Write(p)
	}
	return m.Sum(nil)
}

// NewKeyProof is how a control plane that rotated its key (#997, spec 736 FR-043) shows a
// member the new key comes from it: an HMAC of the new public key under the member's
// shared key from the previous one, which only the previous key's holder can derive.
func NewKeyProof(shared, newKey []byte) []byte {
	return HMAC(shared, []byte("k"), []byte("agents-newkey-v1"), newKey)
}

// NewPrivateKey is a new P-256 private key, 32 bytes.
func NewPrivateKey() []byte {
	k, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	return k.Bytes()
}

// ValidPrivateKey says whether b is a scalar CryptoKit would take: 32 bytes, not zero,
// and below the group order.
func ValidPrivateKey(b []byte) bool {
	_, err := ecdh.P256().NewPrivateKey(b)
	return err == nil
}

// ValidPublicKey says whether b is a P-256 point, X9.63.
func ValidPublicKey(b []byte) bool {
	_, err := ecdh.P256().NewPublicKey(b)
	return err == nil
}

// PublicKey is the 65-byte X9.63 point of a private key.
func PublicKey(private []byte) ([]byte, error) {
	k, err := ecdh.P256().NewPrivateKey(private)
	if err != nil {
		return nil, err
	}
	return k.PublicKey().Bytes(), nil
}

// SharedSecret is the x coordinate both ends feed to HKDF.
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

// ClientKey is what a client and the control plane share. client is the UUID as Swift's
// uuidString writes it: upper case.
func ClientKey(private, peer []byte, client string) ([]byte, error) {
	shared, err := SharedSecret(private, peer)
	if err != nil {
		return nil, err
	}
	return HKDF(shared, []byte(ClientSalt), []byte(client), 32), nil
}

// HostKey is what a host and the control plane share.
func HostKey(private, peer []byte, host string) ([]byte, error) {
	shared, err := SharedSecret(private, peer)
	if err != nil {
		return nil, err
	}
	return HKDF(shared, []byte(HostSalt), []byte(host), 32), nil
}

// CopyKey is what every copy shares, and only copies: it comes from the control plane's
// private key, which only they hold (FR-010).
func CopyKey(controlPrivate []byte) []byte { return HKDF(controlPrivate, []byte(CopySalt), nil, 32) }

// CodeKey is what the holder of a code proves it with.
func CodeKey(secret []byte) []byte { return HKDF(secret, []byte(CodeSalt), nil, 32) }

// LoadOrMakeKey is ControlAgreement.loadOrMake: the key in file, or a new one written
// 0600. The new key is written whole to a file of its own, synced, and only then linked
// into place (#212), so two processes making it at once end with one key, the first one
// linked. A file too short to be a key, and older than a moment, is a torn write, and is
// made again.
func LoadOrMakeKey(file string) ([]byte, error) {
	if stored, err := os.ReadFile(file); err == nil && ValidPrivateKey(stored) {
		return stored, nil
	}
	if info, err := os.Lstat(file); err == nil && info.Size() < 32 && time.Since(info.ModTime()) > 5*time.Second {
		// Only the file found torn: another process mending it at the same moment may
		// already have linked its key in its place, and that one is the key.
		if now, err := os.Lstat(file); err == nil && os.SameFile(info, now) {
			os.Remove(file)
		}
	}
	made := NewPrivateKey()
	dir := filepath.Dir(file)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	b := make([]byte, 8)
	rand.Read(b)
	tmp := filepath.Join(dir, fmt.Sprintf(".%s.%x.tmp", filepath.Base(file), b))
	w, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp)
	_, err = w.Write(made)
	if err == nil {
		err = w.Sync()
	}
	if cerr := w.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return nil, err
	}
	// Linked only if absent: Agents Host and the launcher it just started may make the
	// key at the same moment.
	err = os.Link(tmp, file)
	if err == nil {
		return made, nil
	}
	if !errors.Is(err, syscall.EEXIST) && !errors.Is(err, os.ErrExist) {
		return nil, err
	}
	// Another got there first: theirs is the key. A moment's grace still, for one
	// written in place by an older build.
	for range 50 {
		if stored, err := os.ReadFile(file); err == nil && ValidPrivateKey(stored) {
			return stored, nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return nil, fmt.Errorf("%s is not a key", file)
}

// Same compares two MACs in time that does not depend on where they differ.
func Same(a, b []byte) bool { return len(a) == len(b) && hmac.Equal(a, b) }
