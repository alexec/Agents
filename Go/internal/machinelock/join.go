package machinelock

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

// Adding a client (#3490, D2): the new client sends a commitment to its key and a nonce, a
// signer then sends a nonce of its own, and only then does the new client show its nonce.
// Both screens make the six digits from the key and both nonces. A control plane in the
// middle must choose its key before it sees the signer's nonce, so it has one chance in a
// million, and a failed try shows on the screen (as Bluetooth's numeric comparison).

// NonceSize is the size of each side's nonce.
const NonceSize = 16

const (
	commitDomain = "agents-lock-join/1\n"
	digitsDomain = "agents-lock-digits/1\n"
)

// Commitment is what a new client sends first: SHA-256 of the domain, its key, its nonce.
func Commitment(key, nonce []byte) []byte {
	h := sha256.New()
	h.Write([]byte(commitDomain))
	h.Write(key)
	h.Write(nonce)
	return h.Sum(nil)
}

// Digits are the six digits both screens show: the first four bytes of SHA-256 of the
// domain, the new client's key, its nonce and the signer's nonce, big-endian, modulo a
// million, with leading zeros.
func Digits(key, clientNonce, signerNonce []byte) string {
	h := sha256.New()
	h.Write([]byte(digitsDomain))
	h.Write(key)
	h.Write(clientNonce)
	h.Write(signerNonce)
	sum := h.Sum(nil)
	return fmt.Sprintf("%06d", binary.BigEndian.Uint32(sum[:4])%1_000_000)
}
