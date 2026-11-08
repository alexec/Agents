// Package secretrelease is the second layer of a secret with Ask before use on Linux (#4058,
// the spike #4013): no store on Linux keeps one program of a user from another, and the
// machine's key is a 0600 file an agent can read. So the machine also seals each flagged
// value to a release key whose private half only its control plane keeps, and the control
// plane opens that layer only for an approval that a client of the person's lock signed,
// once. The control plane never sees the value: the machine keeps it sealed to its own key
// as well (Principle 6), and the control plane is given only the encapsulated key.
//
// The layer is HPKE (RFC 9180; DHKEM X25519, HKDF-SHA256, export only) to the release key.
// The machine exports a 32-byte key with the context "sealedsecret.release.v1|"+name and
// seals the value with it under AES-256-GCM; the control plane makes the same key from the
// encapsulated key and the private half (Release), and gives back only that key.
package secretrelease

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/hpke"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

// Info is the HPKE info of every release layer.
const Info = "agents-secret-release/1"

// ApproveMethod is what a client signs when it allows a use: not a method anyone calls, the
// name of what the signature is for.
const ApproveMethod = "secrets/approveUse"

// ApprovalLifetime is how old a signed approval may be when the control plane takes it. A
// person answers a card that is in front of them, so minutes, not the day a kept prompt has.
const ApprovalLifetime = 10 * time.Minute

// KeySize is the size of the key that opens one value's layer.
const KeySize = 32

var (
	// ErrNotApproval: a signed delivery that is not an approval of a use.
	ErrNotApproval = errors.New("it is not a signed approval of a use")
	// ErrStale: an approval older than ApprovalLifetime.
	ErrStale = errors.New("the approval is older than 10 minutes; answer again")
	// ErrNotClient: an approval signed by a key that is not a client of the lock.
	ErrNotClient = errors.New("the approval is not signed by one of your devices")
)

// Layer is one value sealed to a release key: the encapsulated key, then the nonce, the
// sealed value and its tag.
type Layer struct {
	Encapsulated []byte `json:"enc"`
	Sealed       []byte `json:"sealed"`
}

func suite() (hpke.KDF, hpke.AEAD) { return hpke.HKDFSHA256(), hpke.ExportOnly() }

func exportContext(name string) string { return "sealedsecret.release.v1|" + name }

// NewKey makes a release key pair.
func NewKey() (*ecdh.PrivateKey, error) { return ecdh.X25519().GenerateKey(rand.Reader) }

// Seal seals value, named name, to the release key's public half. ad binds where it is kept.
func Seal(publicKey []byte, name, value string, ad []byte) (Layer, error) {
	pub, err := ecdh.X25519().NewPublicKey(publicKey)
	if err != nil {
		return Layer{}, fmt.Errorf("the release key is not an X25519 key: %w", err)
	}
	pk, err := hpke.NewDHKEMPublicKey(pub)
	if err != nil {
		return Layer{}, err
	}
	kdf, aead := suite()
	enc, sender, err := hpke.NewSender(pk, kdf, aead, []byte(Info))
	if err != nil {
		return Layer{}, err
	}
	key, err := sender.Export(exportContext(name), KeySize)
	if err != nil {
		return Layer{}, err
	}
	defer clear(key)
	gcm, err := gcmOf(key)
	if err != nil {
		return Layer{}, err
	}
	nonce := make([]byte, gcm.NonceSize())
	rand.Read(nonce)
	return Layer{Encapsulated: enc, Sealed: gcm.Seal(nonce, nonce, []byte(value), ad)}, nil
}

// Release is the control plane's half: the key for one value's layer, from the private half
// and the encapsulated key. It never sees the value.
func Release(private *ecdh.PrivateKey, name string, encapsulated []byte) ([]byte, error) {
	sk, err := hpke.NewDHKEMPrivateKey(private)
	if err != nil {
		return nil, err
	}
	kdf, aead := suite()
	r, err := hpke.NewRecipient(encapsulated, sk, kdf, aead, []byte(Info))
	if err != nil {
		return nil, fmt.Errorf("the encapsulated key does not read: %w", err)
	}
	return r.Export(exportContext(name), KeySize)
}

// Open opens a layer with the key Release gave.
func Open(key []byte, l Layer, ad []byte) (string, error) {
	gcm, err := gcmOf(key)
	if err != nil {
		return "", err
	}
	if len(l.Sealed) < gcm.NonceSize() {
		return "", errors.New("not a sealed value")
	}
	plain, err := gcm.Open(nil, l.Sealed[:gcm.NonceSize()], l.Sealed[gcm.NonceSize():], ad)
	if err != nil {
		return "", errors.New("it does not open with the key the control plane gave")
	}
	return string(plain), nil
}

func gcmOf(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// Approval is what a client signs when a person allows a use: the request and what it names.
type Approval struct {
	Request wire.UUID `json:"request"`
	Name    string    `json:"name"`
	Use     string    `json:"use"`
	Place   string    `json:"place"`
	Action  string    `json:"action"`
}

// SignApproval is a client's signature of its answer, to the machine host: for the tests, and
// for a client that signs in Go.
func SignApproval(key *ecdsa.PrivateKey, host string, a Approval, at time.Time) (wire.LockDelivery, error) {
	params, err := json.Marshal(a)
	if err != nil {
		return wire.LockDelivery{}, err
	}
	s, err := machinelock.SignRequest(key, host, ApproveMethod, params, at)
	if err != nil {
		return wire.LockDelivery{}, err
	}
	return wire.LockDelivery{Method: ApproveMethod, Params: string(params), Lock: s}, nil
}

// CheckApproval checks a signed approval for the machine host against the person's lock:
// signed to that machine by a client of the lock, at most ApprovalLifetime old. It says
// what was approved; the caller checks that it is the use it asks for, and that it has not
// taken the same signature before (machinelock.SignedID).
func CheckApproval(state *machinelock.State, host string, d wire.LockDelivery, now time.Time) (Approval, error) {
	var a Approval
	if d.Method != ApproveMethod {
		return a, ErrNotApproval
	}
	if d.Lock.To == nil || *d.Lock.To != host {
		return a, fmt.Errorf("%w: it is not for this machine", machinelock.ErrForged)
	}
	if state == nil {
		return a, errors.New("there is no lock to check the approval against")
	}
	m, err := machinelock.CheckRequest(state, host, d.Method, []byte(d.Params), d.Lock, now)
	if err != nil {
		return a, err
	}
	if !m.Client() {
		return a, ErrNotClient
	}
	if at := time.Unix(d.Lock.At, 0); now.Sub(at) > ApprovalLifetime {
		return a, ErrStale
	}
	if err := json.Unmarshal([]byte(d.Params), &a); err != nil || a.Request == "" || a.Name == "" {
		return Approval{}, ErrNotApproval
	}
	return a, nil
}
