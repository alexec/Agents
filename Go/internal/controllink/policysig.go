package controllink

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"math/big"
)

// The organisation's policy is signed by the control key (#998, spec 998 FR-004): ECDSA
// P-256 with SHA-256 over the policy's canonical JSON. The control key is a P-256 key, and
// each member already trusts its public half, so a machine checks a policy with the key it
// joined with and needs no other (data-model.md names Ed25519; the control key is not an
// Ed25519 key). Both sides are here: agents-control signs, agentsd checks.

// PolicyAlg is the signature's alg.
const PolicyAlg = "es256"

// CanonicalJSON is raw with its keys sorted and no spaces, its numbers as they were
// written. A signature is over these bytes, so a field this build does not know is
// signed and checked too.
func CanonicalJSON(raw []byte) ([]byte, error) {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	if d.More() {
		return nil, errors.New("more than one JSON value")
	}
	var out bytes.Buffer
	e := json.NewEncoder(&out)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(out.Bytes(), []byte("\n")), nil
}

// KeyID names a control key in a signature: the first 8 bytes of the SHA-256 of its X9.63
// public key, base64url.
func KeyID(public []byte) string {
	sum := sha256.Sum256(public)
	return B64URL(sum[:8])
}

// SignPolicy signs raw's canonical JSON with the control key: r then s, 32 bytes each.
func SignPolicy(private, raw []byte) ([]byte, error) {
	key, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), private)
	if err != nil {
		return nil, err
	}
	canonical, err := CanonicalJSON(raw)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(canonical)
	r, s, err := ecdsa.Sign(rand.Reader, key, sum[:])
	if err != nil {
		return nil, err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return sig, nil
}

// VerifyPolicy says sig is the control key's signature of raw's canonical JSON.
func VerifyPolicy(public, raw, sig []byte) bool {
	if len(sig) != 64 {
		return false
	}
	key, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), public)
	if err != nil {
		return false
	}
	canonical, err := CanonicalJSON(raw)
	if err != nil {
		return false
	}
	sum := sha256.Sum256(canonical)
	return ecdsa.Verify(key, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
}
