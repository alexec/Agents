package machinelock

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// lockWith is a lock with the client mac, the machine dev-1 and a second client phone.
func lockWith(t *testing.T, mac, phone, machine *ecdsa.PrivateKey) *State {
	t.Helper()
	c := newChain(t, mac)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(phone), Name: ptr("iPhone"), ClientKind: ptr("remote")})
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: PublicKey(machine), SealingKey: PublicKey(machine), ID: ptr("dev-1"), Name: ptr("dev-1")})
	s, err := Check(c.entries)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func shake(t *testing.T, s *State, client, machine *ecdsa.PrivateKey) (mine, theirs *Channel) {
	t.Helper()
	hello, err := NewHello(client)
	if err != nil {
		t.Fatal(err)
	}
	theirs, reply, err := Answer(s, machine, hello.Params)
	if err != nil {
		t.Fatal(err)
	}
	mine, err = hello.Finish(s, "dev-1", reply)
	if err != nil {
		t.Fatal(err)
	}
	return mine, theirs
}

func TestAChannelCarriesCheckedRequestsBothWays(t *testing.T) {
	mac, phone, machine := key(t), key(t), key(t)
	s := lockWith(t, mac, phone, machine)
	client, host := shake(t, s, phone, machine)
	if !bytes.Equal(host.Member.Key, PublicKey(phone)) {
		t.Fatalf("the machine took the channel as %x", host.Member.Key)
	}
	request := `{"jsonrpc":"2.0","id":1,"method":"agents/start","params":{"folder":"/x"}}`
	sealed := client.Seal(request)
	if !Sealed(sealed) || !strings.HasPrefix(sealed, request[:len(request)-1]+`,"lock":{"n":1,"mac":"`) {
		t.Fatalf("sealed = %s", sealed)
	}
	got, err := host.Open(sealed)
	if err != nil || got != request {
		t.Fatalf("open = %q, %v", got, err)
	}
	// The same line again is a replay.
	if _, err := host.Open(sealed); !errors.Is(err, ErrReplayed) {
		t.Fatalf("a replay: %v", err)
	}
	// A changed byte does not check.
	forged := client.Seal(request)
	forged = strings.Replace(forged, `"/x"`, `"/y"`, 1)
	if _, err := host.Open(forged); !errors.Is(err, ErrBadMAC) {
		t.Fatalf("a changed request: %v", err)
	}
	// A request with no MAC.
	if _, err := host.Open(request); !errors.Is(err, ErrUnsigned) {
		t.Fatalf("an unsigned request: %v", err)
	}
	// The answer goes the other way with the other key: the client's own MAC is not one.
	answer := `{"jsonrpc":"2.0","id":1,"result":"A1"}`
	if _, err := client.Open(client.Seal(answer)); !errors.Is(err, ErrBadMAC) {
		t.Fatalf("a client's own MAC taken as the machine's: %v", err)
	}
	got, err = client.Open(host.Seal(answer))
	if err != nil || got != answer {
		t.Fatalf("the answer = %q, %v", got, err)
	}
}

func TestAHelloFromAKeyNotInTheLockIsRefused(t *testing.T) {
	mac, phone, machine, stranger := key(t), key(t), key(t), key(t)
	s := lockWith(t, mac, phone, machine)
	hello, _ := NewHello(stranger)
	if _, _, err := Answer(s, machine, hello.Params); !errors.Is(err, ErrNotMember) {
		t.Fatalf("a stranger's hello: %v", err)
	}
	// A machine's key is not a client's.
	hello, _ = NewHello(machine)
	if _, _, err := Answer(s, machine, hello.Params); !errors.Is(err, ErrNotMember) {
		t.Fatalf("a machine's hello: %v", err)
	}
	// A client's key with an ephemeral key it did not sign: a control plane in the middle.
	hello, _ = NewHello(phone)
	other, _ := NewHello(stranger)
	hello.Params.Ephemeral = other.Params.Ephemeral
	if _, _, err := Answer(s, machine, hello.Params); !errors.Is(err, ErrForged) {
		t.Fatalf("a swapped ephemeral key: %v", err)
	}
}

func TestAClientRefusesAMachineTheLockDoesNotName(t *testing.T) {
	mac, phone, machine, stranger := key(t), key(t), key(t), key(t)
	s := lockWith(t, mac, phone, machine)
	hello, _ := NewHello(phone)
	// A control plane that answers as a machine of its own.
	_, reply, err := Answer(s, stranger, hello.Params)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := hello.Finish(s, "dev-1", reply); !errors.Is(err, ErrNotMember) {
		t.Fatalf("a stranger machine: %v", err)
	}
	// The right machine's key, for another machine's id.
	_, reply, _ = Answer(s, machine, hello.Params)
	if _, err := hello.Finish(s, "dev-2", reply); !errors.Is(err, ErrNotMember) {
		t.Fatalf("the machine for another id: %v", err)
	}
	// A machine the lock does not name yet is taken on its word, as before the lock.
	_, reply, _ = Answer(s, stranger, hello.Params)
	if _, err := hello.Finish(s, "dev-9", reply); err != nil {
		t.Fatalf("a machine waiting for approval: %v", err)
	}
	// The machine's key with an ephemeral it did not sign.
	_, reply, _ = Answer(s, machine, hello.Params)
	_, other, _ := Answer(s, machine, hello.Params)
	reply.Ephemeral = other.Ephemeral
	if _, err := hello.Finish(s, "dev-1", reply); !errors.Is(err, ErrForged) {
		t.Fatalf("a swapped machine ephemeral: %v", err)
	}
}

func TestSignedRequests(t *testing.T) {
	mac, phone, machine, stranger := key(t), key(t), key(t), key(t)
	s := lockWith(t, mac, phone, machine)
	now := time.Now()
	params := []byte(`{"agentID":"A","text":"hi <b>"}`)
	sig, err := SignRequest(phone, "dev-1", "agents/prompt", params, now)
	if err != nil {
		t.Fatal(err)
	}
	m, err := CheckRequest(s, "dev-1", "agents/prompt", params, sig, now.Add(time.Hour))
	if err != nil || !m.Client() {
		t.Fatalf("a kept prompt: %v, %+v", err, m)
	}
	for name, c := range map[string]struct {
		host, method string
		params       []byte
		now          time.Time
		want         error
	}{
		"another machine": {"dev-2", "agents/prompt", params, now, ErrForged},
		"another method":  {"dev-1", "agents/start", params, now, ErrForged},
		"other params":    {"dev-1", "agents/prompt", []byte(`{"agentID":"B"}`), now, ErrForged},
		"a day later":     {"dev-1", "agents/prompt", params, now.Add(RequestLifetime + time.Minute), ErrStale},
	} {
		if _, err := CheckRequest(s, c.host, c.method, c.params, sig, c.now); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", name, err, c.want)
		}
	}
	// A key the lock does not name.
	sig, _ = SignRequest(stranger, "dev-1", "agents/prompt", params, now)
	if _, err := CheckRequest(s, "dev-1", "agents/prompt", params, sig, now); !errors.Is(err, ErrNotMember) {
		t.Fatalf("a stranger: %v", err)
	}
	// A client names the machine; a machine may leave it out (D7).
	sig, _ = SignRequest(phone, "", "agents/prompt", params, now)
	if _, err := CheckRequest(s, "dev-1", "agents/prompt", params, sig, now); !errors.Is(err, ErrForged) {
		t.Fatalf("a client's request for any machine: %v", err)
	}
	sig, _ = SignRequest(machine, "", "agents/start", params, now)
	if m, err := CheckRequest(s, "dev-2", "agents/start", params, sig, now); err != nil || m.Kind != wire.LockEntryKindAddMachine {
		t.Fatalf("a machine's start: %v, %+v", err, m)
	}
	if SignedID(sig) == "" {
		t.Fatal("no id")
	}
}

// The channel vectors (#3492): a hello both ways, the keys they make, a sealed line, and a
// signed request, all from Go. AgentsKit's MachineLockTests and Web/test/machineLock.test.mjs
// read the same file, so the three make the same keys and MACs and check the same signatures.
// go test ./internal/machinelock -run TestTheChannelVectors -args -write-channel-vectors
const channelVectors = "../../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/lock/channel.json"

var writeChannelVectors = flag.Bool("write-channel-vectors", false, "make the channel vectors afresh")

type channelVector struct {
	ClientKey           []byte              `json:"clientKey"`
	Hello               wire.LockHello      `json:"hello"`
	ClientEphemeralSeed []byte              `json:"clientEphemeralPrivate"`
	MachineKey          []byte              `json:"machineKey"`
	Reply               wire.LockHelloReply `json:"reply"`
	MachineEphemeralRaw []byte              `json:"machineEphemeralPrivate"`
	ClientSends         []byte              `json:"clientSends"`
	MachineSends        []byte              `json:"machineSends"`
	Message             string              `json:"message"`
	Sealed              string              `json:"sealed"`
	Answer              string              `json:"answer"`
	AnswerSealed        string              `json:"answerSealed"`
	Request             struct {
		Method string             `json:"method"`
		Params string             `json:"params"`
		Lock   wire.LockSignature `json:"lock"`
	} `json:"request"`
}

func makeChannelVector(t *testing.T) channelVector {
	client, machine := key(t), key(t)
	var v channelVector
	hello, err := NewHello(client)
	if err != nil {
		t.Fatal(err)
	}
	machineEph, _ := ecdh.P256().GenerateKey(rand.Reader)
	public := machineEph.PublicKey().Bytes()
	sig, _ := SignData(machine, machineHelloData(hello.Params.Ephemeral, public, hello.Params.Key))
	v.ClientKey, v.Hello, v.ClientEphemeralSeed = PublicKey(client), hello.Params, hello.ephemeral.Bytes()
	v.MachineKey, v.MachineEphemeralRaw = PublicKey(machine), machineEph.Bytes()
	v.Reply = wire.LockHelloReply{Key: PublicKey(machine), Ephemeral: public, Sig: sig}
	shared, _ := machineEph.ECDH(hello.ephemeral.PublicKey())
	v.ClientSends, v.MachineSends, _ = keys(shared, hello.Params.Ephemeral, public)
	v.Message = `{"jsonrpc":"2.0","id":7,"method":"agents/prompt","params":{"text":"héllo <b>"}}`
	v.Sealed = (&Channel{send: v.ClientSends, sent: 41}).Seal(v.Message)
	v.Answer = `{"jsonrpc":"2.0","id":7,"result":{}}`
	v.AnswerSealed = (&Channel{send: v.MachineSends, sent: 2}).Seal(v.Answer)
	v.Request.Method, v.Request.Params = "agents/start", `{"folder":"/Users/sam/x","prompt":"hi"}`
	v.Request.Lock, _ = SignRequest(client, "dev-1", v.Request.Method, []byte(v.Request.Params), time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC))
	return v
}

func TestTheChannelVectors(t *testing.T) {
	if *writeChannelVectors {
		b, _ := json.MarshalIndent(makeChannelVector(t), "", "  ")
		if err := os.WriteFile(channelVectors, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := os.ReadFile(channelVectors)
	if err != nil {
		t.Fatal(err)
	}
	var v channelVector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if !VerifyData(v.ClientKey, clientHelloData(v.Hello.Ephemeral), v.Hello.Sig) {
		t.Fatal("the client's hello does not check")
	}
	if !VerifyData(v.MachineKey, machineHelloData(v.Hello.Ephemeral, v.Reply.Ephemeral, v.ClientKey), v.Reply.Sig) {
		t.Fatal("the machine's hello does not check")
	}
	clientEph, err := ecdh.P256().NewPrivateKey(v.ClientEphemeralSeed)
	if err != nil {
		t.Fatal(err)
	}
	machinePublic, _ := ecdh.P256().NewPublicKey(v.Reply.Ephemeral)
	shared, _ := clientEph.ECDH(machinePublic)
	c, m, _ := keys(shared, v.Hello.Ephemeral, v.Reply.Ephemeral)
	if !bytes.Equal(c, v.ClientSends) || !bytes.Equal(m, v.MachineSends) {
		t.Fatal("the keys differ")
	}
	if got := (&Channel{send: c, sent: 41}).Seal(v.Message); got != v.Sealed {
		t.Fatalf("sealed = %s", got)
	}
	if body, err := (&Channel{hear: c, heard: 41}).Open(v.Sealed); err != nil || body != v.Message {
		t.Fatalf("open = %q, %v", body, err)
	}
	if body, err := (&Channel{hear: m}).Open(v.AnswerSealed); err != nil || body != v.Answer {
		t.Fatalf("the answer = %q, %v", body, err)
	}
	if !VerifyData(v.ClientKey, RequestData("dev-1", v.Request.Lock.At, v.Request.Method, []byte(v.Request.Params)), v.Request.Lock.Sig) {
		t.Fatal("the signed request does not check")
	}
}
