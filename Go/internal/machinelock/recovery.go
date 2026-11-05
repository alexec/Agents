package machinelock

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"strings"
)

// The recovery key (#3493, D4): when the root is made, the client makes a recovery key and
// shows its secret once, for the person to keep in a password manager. The secret is 16
// random bytes; the person sees them with a 4-byte check, as 32 letters and digits in
// groups of four (Crockford's base32), so a typo is found before anything is sent.
//
// The recovery key itself is a P-256 signing key made at random. Its public half is the
// recovery entry's key, a signer of the lock. Its private half goes in the same entry,
// sealed: AES-256-GCM under a key that HKDF-SHA256 makes from the secret, with the public
// half as the additional data. A new client that is typed the secret opens it, and signs
// its own addClient with it. The control plane keeps the sealed key, but without the
// secret it cannot open it.

// RecoverySecretSize is the size of the secret the person keeps: 128 bits.
const RecoverySecretSize = 16

const (
	recoveryCheckDomain = "agents-lock-recovery-check/1\n"
	recoverySealDomain  = "agents-lock-recovery/1\n"
	recoveryCheckSize   = 4
	// crockford is Crockford's base32 alphabet: no I, L, O or U.
	crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
)

var (
	// ErrRecoveryTypo: the text is not a recovery key, or its check does not match.
	ErrRecoveryTypo = errors.New("that is not a recovery key; check it for a typo")
	// ErrRecoveryNotThisLock: the secret does not open this lock's recovery key.
	ErrRecoveryNotThisLock = errors.New("that recovery key is not this lock's")
)

func recoveryCheck(secret []byte) []byte {
	sum := sha256.Sum256(append([]byte(recoveryCheckDomain), secret...))
	return sum[:recoveryCheckSize]
}

// RecoveryText is the secret as the person sees it: "ABCD-EFGH-…", eight groups of four.
func RecoveryText(secret []byte) string {
	raw := append(append([]byte{}, secret...), recoveryCheck(secret)...)
	var out strings.Builder
	var bits, n uint
	var acc uint64
	for _, b := range raw {
		acc = acc<<8 | uint64(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			if n > 0 && n%4 == 0 {
				out.WriteByte('-')
			}
			out.WriteByte(crockford[acc>>bits&31])
			n++
		}
	}
	return out.String()
}

// ParseRecovery reads a secret as the person typed it: any case, with or without the
// dashes and spaces, O read as 0, and I and L as 1.
func ParseRecovery(text string) ([]byte, error) {
	var raw []byte
	var bits uint
	var acc uint64
	count := 0
	for _, c := range strings.ToUpper(text) {
		switch c {
		case '-', ' ', '\t', '\n':
			continue
		case 'O':
			c = '0'
		case 'I', 'L':
			c = '1'
		}
		v := strings.IndexRune(crockford, c)
		if v < 0 {
			return nil, ErrRecoveryTypo
		}
		count++
		acc = acc<<5 | uint64(v)
		bits += 5
		if bits >= 8 {
			bits -= 8
			raw = append(raw, byte(acc>>bits))
		}
	}
	if count != 32 || len(raw) != RecoverySecretSize+recoveryCheckSize {
		return nil, ErrRecoveryTypo
	}
	secret := raw[:RecoverySecretSize]
	if string(recoveryCheck(secret)) != string(raw[RecoverySecretSize:]) {
		return nil, ErrRecoveryTypo
	}
	return secret, nil
}

func recoveryAEAD(secret, public []byte) (cipher.AEAD, error) {
	key, err := hkdf.Key(sha256.New, secret, nil, recoverySealDomain+string(public), 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// SealRecovery seals a recovery key's private half (32 bytes) under the secret: a 12-byte
// nonce, then the sealed bytes and the tag.
func SealRecovery(secret []byte, key *ecdsa.PrivateKey) ([]byte, error) {
	private, err := key.Bytes()
	if err != nil {
		return nil, err
	}
	public := PublicKey(key)
	aead, err := recoveryAEAD(secret, public)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	rand.Read(nonce)
	return aead.Seal(nonce, nonce, private, public), nil
}

// OpenRecovery opens the sealed private half of the recovery key whose public half is
// public, with the secret the person typed.
func OpenRecovery(secret, public, sealed []byte) (*ecdsa.PrivateKey, error) {
	aead, err := recoveryAEAD(secret, public)
	if err != nil {
		return nil, err
	}
	if len(sealed) < aead.NonceSize() {
		return nil, ErrRecoveryNotThisLock
	}
	private, err := aead.Open(nil, sealed[:aead.NonceSize()], sealed[aead.NonceSize():], public)
	if err != nil {
		return nil, ErrRecoveryNotThisLock
	}
	key, err := InviteKey(private)
	if err != nil || string(PublicKey(key)) != string(public) {
		return nil, ErrRecoveryNotThisLock
	}
	return key, nil
}

// RecoverySealed is the sealed private half of the lock's recovery key, as its newest
// recovery entry carries it; nil when the lock has none.
func (s *State) RecoverySealed() []byte { return s.recoverySealed }
