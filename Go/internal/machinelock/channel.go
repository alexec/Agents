package machinelock

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strconv"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Requests checked end to end (#3492, specs/3399-machine-lock D6, D7). A machine takes a
// request from the control plane only when a key of its person's lock vouches for it, in
// one of two ways:
//
//   - A channel (lock/hello). The client sends a new ECDH key, signed with its signing key;
//     the machine answers with one of its own, signed with its machine key. Each checks the
//     other against the lock, and HKDF-SHA256 makes a key for each direction. Every request
//     and every answer then ends with "lock":{"n":…,"mac":…}: HMAC-SHA256 over the count and
//     the message without that member. A count no higher than the last one is a replay.
//   - A signed request (LockSignature): a client's kept request for a machine that was not
//     there, or a machine's call to another of its person's machines. ECDSA over the
//     method and the params as sent, with when and to which machine.
//
// The control plane passes each message on as it came, so the bytes a sender MACs are the
// bytes the other side reads.

const (
	channelDomain = "agents-lock-channel/1\n"
	requestDomain = "agents-lock-request/1\n"
	clientInfo    = "agents-lock-channel/1 client"
	machineInfo   = "agents-lock-channel/1 machine"
)

// RequestLifetime is how old a signed request may be when it comes: a kept prompt waits
// for its machine to start, at most this long (D6).
const RequestLifetime = 24 * time.Hour

// requestSkew is how far ahead of this machine's clock a signed request may say it was made.
const requestSkew = 5 * time.Minute

// The ways a request fails its check.
var (
	// ErrUnsigned: the request carries no MAC or signature.
	ErrUnsigned = errors.New("the request is not signed by one of your devices")
	// ErrBadMAC: the MAC does not check, or the channel has no keys.
	ErrBadMAC = errors.New("the request's MAC does not check")
	// ErrReplayed: a count or a signed request seen before.
	ErrReplayed = errors.New("the request was sent before")
	// ErrNotMember: the key is not one the lock names for that.
	ErrNotMember = errors.New("the key is not in your lock")
	// ErrStale: a signed request older than RequestLifetime, or from the future.
	ErrStale = errors.New("the signed request is too old")
)

func cat(parts ...[]byte) []byte { return bytes.Join(parts, nil) }

// SignData is ECDSA P-256 with SHA-256 over data, r then s: what CryptoKit's
// signature(for:) and WebCrypto's ECDSA make.
func SignData(key *ecdsa.PrivateKey, data []byte) ([]byte, error) {
	sum := sha256.Sum256(data)
	r, s, err := ecdsa.Sign(rand.Reader, key, sum[:])
	if err != nil {
		return nil, err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return sig, nil
}

// VerifyData checks SignData's signature by the public key (X9.63).
func VerifyData(public, data, sig []byte) bool {
	key, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), public)
	if err != nil || len(sig) != 64 {
		return false
	}
	sum := sha256.Sum256(data)
	return ecdsa.Verify(key, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
}

// MachineSigner is a machine's key as a signer: its key, the one it proves itself with and
// that its addMachine names (raw P-256 scalar, as controllink keeps it).
func MachineSigner(private []byte) (*ecdsa.PrivateKey, error) {
	return ecdsa.ParseRawPrivateKey(elliptic.P256(), private)
}

func clientHelloData(ephemeral []byte) []byte {
	return cat([]byte(channelDomain), []byte("client\n"), ephemeral)
}

func machineHelloData(clientEphemeral, machineEphemeral, clientKey []byte) []byte {
	return cat([]byte(channelDomain), []byte("machine\n"), clientEphemeral, machineEphemeral, clientKey)
}

// Channel is one side of a checked channel: a key for what it sends and one for what it
// hears, and the counts in each direction.
type Channel struct {
	send, hear []byte
	// Member is who the other side is in the lock: the client, on a machine's side.
	Member Member
	mu     sync.Mutex
	sent   uint64
	heard  uint64
}

func keys(shared, clientEphemeral, machineEphemeral []byte) (client, machine []byte, err error) {
	salt := cat(clientEphemeral, machineEphemeral)
	if client, err = hkdf.Key(sha256.New, shared, salt, clientInfo, 32); err != nil {
		return nil, nil, err
	}
	machine, err = hkdf.Key(sha256.New, shared, salt, machineInfo, 32)
	return client, machine, err
}

// Hello is a client's side of lock/hello before the answer: the hello to send, and the
// ephemeral key it keeps for Finish.
type Hello struct {
	Params    wire.LockHello
	ephemeral *ecdh.PrivateKey
}

// NewHello makes a client's lock/hello, signed with its signing key.
func NewHello(signer *ecdsa.PrivateKey) (*Hello, error) {
	eph, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	public := eph.PublicKey().Bytes()
	sig, err := SignData(signer, clientHelloData(public))
	if err != nil {
		return nil, err
	}
	return &Hello{Params: wire.LockHello{Key: PublicKey(signer), Ephemeral: public, Sig: sig}, ephemeral: eph}, nil
}

// Finish checks a machine's answer against the client's lock and makes the client's side
// of the channel. host is the machine's id; "" is any machine (the window's "mac"). A
// machine the lock names must answer with the key its addMachine names. One the lock does
// not name yet (it waits for approval) is taken on its word, as before the lock: its
// answers are only as good as the control plane's, but the requests to it are still the
// client's alone.
func (h *Hello) Finish(state *State, host string, reply wire.LockHelloReply) (*Channel, error) {
	m, ok := state.Member(reply.Key)
	switch {
	case ok && (m.Kind != wire.LockEntryKindAddMachine || host != "" && m.ID != "" && m.ID != host):
		return nil, fmt.Errorf("%w: the key is not this machine's addMachine", ErrNotMember)
	case !ok && state.Names(host):
		return nil, fmt.Errorf("%w: the machine's key is not the one its addMachine names", ErrNotMember)
	}
	if !VerifyData(reply.Key, machineHelloData(h.Params.Ephemeral, reply.Ephemeral, h.Params.Key), reply.Sig) {
		return nil, fmt.Errorf("%w: the machine's hello is not signed by its key", ErrForged)
	}
	peer, err := ecdh.P256().NewPublicKey(reply.Ephemeral)
	if err != nil {
		return nil, fmt.Errorf("%w: the machine's ephemeral key is not P-256", ErrInvalid)
	}
	shared, err := h.ephemeral.ECDH(peer)
	if err != nil {
		return nil, err
	}
	client, machine, err := keys(shared, h.Params.Ephemeral, reply.Ephemeral)
	if err != nil {
		return nil, err
	}
	return &Channel{send: client, hear: machine, Member: m}, nil
}

// Names says the lock names the machine host with an addMachine.
func (s *State) Names(host string) bool {
	if host == "" {
		return false
	}
	for _, m := range s.members {
		if m.Kind == wire.LockEntryKindAddMachine && m.ID == host {
			return true
		}
	}
	return false
}

// Answer is a machine's side of lock/hello: it checks that the lock names the client's key
// as a client and that the client signed its ephemeral key, and answers with its own,
// signed with the machine's key.
func Answer(state *State, machine *ecdsa.PrivateKey, hello wire.LockHello) (*Channel, wire.LockHelloReply, error) {
	var reply wire.LockHelloReply
	m, ok := state.Member(hello.Key)
	if !ok || !m.Client() {
		return nil, reply, fmt.Errorf("%w: this device is not one of your devices yet; approve it on another", ErrNotMember)
	}
	if !VerifyData(hello.Key, clientHelloData(hello.Ephemeral), hello.Sig) {
		return nil, reply, fmt.Errorf("%w: the hello is not signed by the key it names", ErrForged)
	}
	peer, err := ecdh.P256().NewPublicKey(hello.Ephemeral)
	if err != nil {
		return nil, reply, fmt.Errorf("%w: the ephemeral key is not P-256", ErrInvalid)
	}
	eph, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, reply, err
	}
	shared, err := eph.ECDH(peer)
	if err != nil {
		return nil, reply, err
	}
	public := eph.PublicKey().Bytes()
	client, mine, err := keys(shared, hello.Ephemeral, public)
	if err != nil {
		return nil, reply, err
	}
	sig, err := SignData(machine, machineHelloData(hello.Ephemeral, public, hello.Key))
	if err != nil {
		return nil, reply, err
	}
	reply = wire.LockHelloReply{Key: PublicKey(machine), Ephemeral: public, Sig: sig}
	return &Channel{send: mine, hear: client, Member: m}, reply, nil
}

// macOf is HMAC-SHA256 over the count, 8 bytes big-endian, then the message.
func macOf(key []byte, n uint64, body string) []byte {
	h := hmac.New(sha256.New, key)
	var count [8]byte
	binary.BigEndian.PutUint64(count[:], n)
	h.Write(count[:])
	h.Write([]byte(body))
	return h.Sum(nil)
}

// tail is the "lock" member a MAC'd message ends with. The MAC is standard base64 of 32
// bytes, 44 characters with one "=".
var tail = regexp.MustCompile(`,"lock":\{"n":([0-9]{1,19}),"mac":"([A-Za-z0-9+/]{43}=)"\}\}$`)

// Seal is a message (a JSON object) with the next count and its MAC as its last member.
// The caller writes what Seal returns before it seals the next one, so the counts go out
// in order.
func (c *Channel) Seal(message string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.sealLocked(message)
}

func (c *Channel) sealLocked(message string) string {
	return message[:len(message)-1] + `,"lock":` + c.tailLocked(message) + `}`
}

// Tail is the "lock" member for a message, with the next count, without the message: what
// a fan-out frame carries for each channel it names, which the control plane adds to that
// channel's copy (#3541). The caller writes the frame before this channel's next message.
func (c *Channel) Tail(message string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.tailLocked(message)
}

func (c *Channel) tailLocked(message string) string {
	c.sent++
	mac := base64.StdEncoding.EncodeToString(macOf(c.send, c.sent, message))
	return `{"n":` + strconv.FormatUint(c.sent, 10) + `,"mac":"` + mac + `"}`
}

// Sealed says a message ends with a MAC member, whether or not it checks.
func Sealed(message string) bool { return tail.MatchString(message) }

// Open checks a message's MAC and count and gives it back without its "lock" member.
func (c *Channel) Open(message string) (string, error) {
	match := tail.FindStringSubmatchIndex(message)
	if match == nil {
		return "", ErrUnsigned
	}
	n, err := strconv.ParseUint(message[match[2]:match[3]], 10, 64)
	if err != nil {
		return "", ErrBadMAC
	}
	got, err := base64.StdEncoding.DecodeString(message[match[4]:match[5]])
	if err != nil {
		return "", ErrBadMAC
	}
	body := message[:match[0]] + "}"
	c.mu.Lock()
	defer c.mu.Unlock()
	if !hmac.Equal(got, macOf(c.hear, n, body)) {
		return "", ErrBadMAC
	}
	if n <= c.heard {
		return "", ErrReplayed
	}
	c.heard = n
	return body, nil
}

// RequestData is what a LockSignature signs: the domain, to, at, the method and the params
// as sent, each but the last ended by a newline.
func RequestData(to string, at int64, method string, params []byte) []byte {
	return cat([]byte(requestDomain), []byte(to), []byte("\n"), []byte(strconv.FormatInt(at, 10)), []byte("\n"),
		[]byte(method), []byte("\n"), params)
}

// SignRequest signs a request for the machine to (its id; "" for any of the person's).
func SignRequest(key *ecdsa.PrivateKey, to, method string, params []byte, at time.Time) (wire.LockSignature, error) {
	sig, err := SignData(key, RequestData(to, at.Unix(), method, params))
	if err != nil {
		return wire.LockSignature{}, err
	}
	s := wire.LockSignature{At: at.Unix(), Key: PublicKey(key), Sig: sig}
	if to != "" {
		s.To = &to
	}
	return s, nil
}

// CheckRequest checks a signed request for the machine host: the signature, its age, and
// that the lock names its key. It gives back the signer; the caller says whether that
// member may ask for the method, and remembers the signature so it is taken once.
func CheckRequest(state *State, host, method string, params []byte, s wire.LockSignature, now time.Time) (Member, error) {
	to := ""
	if s.To != nil {
		to = *s.To
	}
	if to != "" && to != host {
		return Member{}, fmt.Errorf("%w: it is for another machine", ErrForged)
	}
	if !VerifyData(s.Key, RequestData(to, s.At, method, params), s.Sig) {
		return Member{}, fmt.Errorf("%w: its signature does not check", ErrForged)
	}
	at := time.Unix(s.At, 0)
	if now.Sub(at) > RequestLifetime || at.Sub(now) > requestSkew {
		return Member{}, ErrStale
	}
	m, ok := state.Member(s.Key)
	if !ok || m.Kind != wire.LockEntryKindAddMachine && !m.Client() {
		return Member{}, ErrNotMember
	}
	if m.Kind == wire.LockEntryKindAddMachine && to == "" {
		return m, nil
	}
	if to == "" {
		return Member{}, fmt.Errorf("%w: a client's request names no machine", ErrForged)
	}
	return m, nil
}

// SignatureOf is the "lock" member of a request, when it is a LockSignature.
func SignatureOf(raw json.RawMessage) (wire.LockSignature, bool) {
	var s wire.LockSignature
	if len(raw) == 0 || json.Unmarshal(raw, &s) != nil || len(s.Sig) == 0 || len(s.Key) == 0 {
		return s, false
	}
	return s, true
}

// SignedID is what a machine remembers of a signed request it took: the SHA-256 of its
// signature.
func SignedID(s wire.LockSignature) string {
	sum := sha256.Sum256(s.Sig)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}
