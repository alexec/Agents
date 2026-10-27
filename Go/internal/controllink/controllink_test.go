package controllink

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

type vectors struct {
	Origin, ServerNonce, PeerNonce string
	Control                        struct{ Private, Public string }
	Client                         struct {
		ID, Identity, Private, Public, SharedX, Key string
		MAC                                         struct{ Peer, Server string }
	}
	Code struct {
		Secret, SecretBase64url, Identity, Key string
		MAC                                    struct{ Peer, Server string }
	}
}

func readVectors(t *testing.T) vectors {
	raw, err := os.ReadFile("testdata/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func unhex(s string) []byte { b, _ := hex.DecodeString(s); return b }

// testdata/vectors.json is Web/test/vectors.json, which ControlAgreementVectorTests.swift
// writes. Where the repository is there (CI), the copy must be the same file.
func TestTheVectorsAreSwifts(t *testing.T) {
	theirs, err := os.ReadFile("../../../Web/test/vectors.json")
	if err != nil {
		t.Skip("Web/ is not here (the Go module alone, in a container)")
	}
	ours, _ := os.ReadFile("testdata/vectors.json")
	if !bytes.Equal(theirs, ours) {
		t.Fatal("testdata/vectors.json differs from Web/test/vectors.json: copy it again")
	}
}

// The Go derivations give the same bytes as Swift's.
func TestTheSwiftVectors(t *testing.T) {
	v := readVectors(t)
	sum := func(s string) []byte { b := sha256.Sum256([]byte(s)); return b[:] }
	controlPrivate := sum("agents-web-vector-control")
	clientPrivate := sum("agents-web-vector-client")
	check := func(what string, got []byte, want string) {
		t.Helper()
		if hex.EncodeToString(got) != want {
			t.Errorf("%s: got %x want %s", what, got, want)
		}
	}
	check("control private", controlPrivate, v.Control.Private)
	check("client private", clientPrivate, v.Client.Private)
	pub, _ := PublicKey(controlPrivate)
	check("control public", pub, v.Control.Public)
	clientPub, _ := PublicKey(clientPrivate)
	check("client public", clientPub, v.Client.Public)
	shared, _ := SharedSecret(clientPrivate, pub)
	check("shared", shared, v.Client.SharedX)
	key, _ := ClientKey(controlPrivate, clientPub, v.Client.ID)
	check("client key, the server's side", key, v.Client.Key)
	key2, _ := ClientKey(clientPrivate, pub, v.Client.ID)
	check("client key, the client's side", key2, v.Client.Key)
	sn, pn := unhex(v.ServerNonce), unhex(v.PeerNonce)
	check("client peer MAC", PeerMAC(key, sn, pn, v.Client.Identity, v.Origin), v.Client.MAC.Peer)
	check("client server MAC", ServerMAC(key, sn, pn, v.Client.Identity, v.Origin), v.Client.MAC.Server)
	secret := CodeSecret(controlPrivate, "000102030405060708090a0b0c0d0e0f")
	check("code secret", secret, v.Code.Secret)
	if B64URL(secret) != v.Code.SecretBase64url {
		t.Errorf("code secret base64url %s", B64URL(secret))
	}
	check("code key", CodeKey(secret), v.Code.Key)
	check("code peer MAC", PeerMAC(CodeKey(secret), sn, pn, v.Code.Identity, v.Origin), v.Code.MAC.Peer)
	check("code server MAC", ServerMAC(CodeKey(secret), sn, pn, v.Code.Identity, v.Origin), v.Code.MAC.Server)

	// The server's Verify takes the vector's auth at any of its origins.
	a := &Auth{ID: v.Client.Identity, Nonce: B64URL(pn), Mac: B64URL(unhex(v.Client.MAC.Peer)), Kind: "browser"}
	id, mac, err := Verify(a, sn, []string{"https://elsewhere:443", v.Origin}, func(Identity) ([]byte, error) { return key, nil })
	if err != nil || id.Kind != 'c' || hex.EncodeToString(mac) != v.Client.MAC.Server {
		t.Fatalf("verify: %v %c %x", err, id.Kind, mac)
	}
	// And refuses it at another.
	if _, _, err := Verify(a, sn, []string{"https://elsewhere:443"}, func(Identity) ([]byte, error) { return key, nil }); !isRefusal(err, BadProof) {
		t.Fatal(err)
	}
}

func isRefusal(err error, reason string) bool {
	var r *Refusal
	return errors.As(err, &r) && r.Reason == reason
}

// A host and a server go through the whole exchange, each with only its own key.
func TestTheExchangeBothWays(t *testing.T) {
	control, host := NewPrivateKey(), NewPrivateKey()
	controlPub, _ := PublicKey(control)
	hostPub, _ := PublicKey(host)
	origin, _ := Origin("wss://Control.Example")
	if origin != "https://control.example:443" {
		t.Fatal(origin)
	}
	serverNonce := Nonce()
	hello := Message{Hello: &Hello{V: Version, Name: "Test", Control: B64URL(controlPub), Nonce: B64URL(serverNonce), Copy: "c1"}}
	got, ok := ParseMessage(hello.Line())
	if !ok || got.Hello == nil {
		t.Fatal(hello.Line())
	}
	hostKey, _ := HostKey(host, controlPub, "box-1")
	auth, expect, err := Answer(got.Hello, Identity{'h', "box-1"}, hostKey, origin, "host", controlPub, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	line := Message{Auth: auth}.Line()
	back, _ := ParseMessage(line)
	id, mac, err := Verify(back.Auth, serverNonce, []string{origin}, func(i Identity) ([]byte, error) {
		if i.Kind != 'h' {
			return nil, Refuse(Unknown)
		}
		return HostKey(control, hostPub, i.ID)
	})
	if err != nil || id != (Identity{'h', "box-1"}) {
		t.Fatal(id, err)
	}
	okLine := Message{OK: &OK{Mac: B64URL(mac), Host: new(wire.MachineRef("box-1"))}}.Line()
	if okLine != `{"ok":{"mac":"`+B64URL(mac)+`","host":"box-1"}}` {
		t.Fatal(okLine)
	}
	okBack, _ := ParseMessage(okLine)
	if err := Check(okBack.OK, expect); err != nil {
		t.Fatal(err)
	}
	// Another control plane's hello is refused before anything is sent.
	other, _ := PublicKey(NewPrivateKey())
	h2 := *got.Hello
	h2.Control = B64URL(other)
	if _, _, err := Answer(&h2, Identity{'h', "box-1"}, hostKey, origin, "host", controlPub, "", nil); !isRefusal(err, WrongControlPlane) {
		t.Fatal(err)
	}
	// A forged ok is refused.
	if err := Check(&OK{Mac: B64URL(Nonce())}, expect); !isRefusal(err, WrongControlPlane) {
		t.Fatal(err)
	}
}

func TestRefusedLines(t *testing.T) {
	line := Message{Refused: Forgotten}.Line()
	if line != `{"refused":{"reason":"forgotten"}}` {
		t.Fatal(line)
	}
	if m, ok := ParseMessage(line); !ok || m.Refused != Forgotten {
		t.Fatal(m)
	}
	for _, bad := range []string{`{"refused":{"reason":"nope"}}`, `{}`, `{"hello":{},"auth":{}}`, `[]`, `{"what":1}`} {
		if _, ok := ParseMessage(bad); ok {
			t.Fatal(bad)
		}
	}
}

func TestIdentities(t *testing.T) {
	for text, want := range map[string]bool{
		"c:6f1c2a3b-4d5e-4f60-8172-93a4b5c6d7e8": true,
		"c:not-a-uuid":                           false,
		"h:mac":                                  true,
		"h:Mac":                                  false,
		"h:" + strings.Repeat("a", 65):           false,
		"p:000102030405060708090a0b0c0d0e0f":     true,
		"e:0001":                                 false,
		"x:copy-1":                               true,
		"x:":                                     false,
		"z:what":                                 false,
		"c":                                      false,
	} {
		if _, ok := ParseIdentity(text); ok != want {
			t.Errorf("%s: %v", text, ok)
		}
	}
	// A client's id is upper case, as Swift's uuidString writes it into the key.
	if id, _ := ParseIdentity("c:6f1c2a3b-4d5e-4f60-8172-93a4b5c6d7e8"); id.ID != "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8" {
		t.Fatal(id)
	}
}

func TestACodeRoundTrips(t *testing.T) {
	priv := NewPrivateKey()
	pub, _ := PublicKey(priv)
	id, secret := MakeCodeSecret(priv)
	c := &Code{ControlKey: pub, Secret: secret, URL: "https://192.168.1.2:8791", Pin: B64URL(make([]byte, 32)), Name: "Alex's Mac"}
	text := c.Text()
	if !strings.HasPrefix(text, "agents-control:2:c:operator:") || !strings.HasSuffix(text, ":Alex%27s%20Mac") {
		t.Fatal(text)
	}
	back, err := ParseCode("  " + text + "\n")
	if err != nil || back.ID() != id || back.Name != c.Name || back.URL != c.URL || back.Pin != c.Pin || back.Host {
		t.Fatalf("%v %+v", err, back)
	}
	if !bytes.Equal(CodeSecret(priv, id), secret) {
		t.Fatal("the secret is not the id's")
	}
	c.Host, c.Pin = true, ""
	back, err = ParseCode(c.Text())
	if err != nil || !back.Host || back.Pin != "" || !strings.Contains(c.Text(), ":h:-:") {
		t.Fatal(err, c.Text())
	}
}

func TestCodesSwiftRefuses(t *testing.T) {
	pub, _ := PublicKey(NewPrivateKey())
	_, secret := MakeCodeSecret(NewPrivateKey())
	for _, c := range []*Code{
		{ControlKey: pub, Secret: secret, URL: "http://192.168.1.2:8791", Name: "plain http off this machine"},
		{ControlKey: pub, Secret: secret, URL: "https://h:1", Pin: "short", Name: "a pin not 32 bytes"},
		{ControlKey: pub[:64], Secret: secret, URL: "https://h:1", Name: "a short key"},
	} {
		if _, err := ParseCode(c.Text()); err == nil {
			t.Error(c.Name)
		}
	}
	ok := &Code{ControlKey: pub, Secret: secret, URL: "http://127.0.0.1:8791", Name: "loopback"}
	if _, err := ParseCode(ok.Text()); err != nil {
		t.Fatal(err)
	}
	if _, err := ParseCode(strings.Replace(ok.Text(), ":c:operator:", ":h:operator:", 1)); err == nil {
		t.Fatal("a host code with a grant")
	}
}

func TestTheKeyFileIsMadeOnceAndKept(t *testing.T) {
	file := filepath.Join(t.TempDir(), "control", "control-key")
	var wg sync.WaitGroup
	keys := make([][]byte, 8)
	for n := range keys {
		wg.Add(1)
		go func() {
			defer wg.Done()
			k, err := LoadOrMakeKey(file)
			if err != nil {
				t.Error(err)
			}
			keys[n] = k
		}()
	}
	wg.Wait()
	for _, k := range keys[1:] {
		if !bytes.Equal(k, keys[0]) {
			t.Fatal("two keys were made")
		}
	}
	if info, _ := os.Stat(file); info.Mode().Perm() != 0o600 {
		t.Fatal(info.Mode())
	}
	// A torn file, older than a moment, is made again.
	os.WriteFile(file, []byte("x"), 0o600)
	old := time.Now().Add(-time.Minute)
	os.Chtimes(file, old, old)
	k, err := LoadOrMakeKey(file)
	if err != nil || len(k) != 32 || bytes.Equal(k, keys[0]) {
		t.Fatal(err)
	}
	if again, _ := LoadOrMakeKey(file); !bytes.Equal(again, k) {
		t.Fatal("the key was not kept")
	}
}

// A member takes a newer list from ok, and keeps its own for an older or a bad one (T125).
func TestMembershipAdoptsOnlyANewerAcceptableList(t *testing.T) {
	m := &Membership{URL: "https://mac.local:8791", Pin: B64URL(make([]byte, 32))}
	if got := m.EndpointsToDial(); len(got) != 1 || got[0].URL != m.URL || got[0].Pin == nil {
		t.Fatal(got)
	}
	two := int64(2)
	cloud := wire.ControlEndpoint{URL: "https://agents.example.com"}
	if !m.Adopt(&OK{Endpoints: []wire.ControlEndpoint{cloud}, Epoch: &two}) || m.URL != cloud.URL || m.Pin != "" || *m.Epoch != 2 {
		t.Fatal(m)
	}
	one := int64(1)
	if m.Adopt(&OK{Endpoints: []wire.ControlEndpoint{{URL: "https://old.example.com"}}, Epoch: &one}) {
		t.Fatal("took an older list")
	}
	three := int64(3)
	if m.Adopt(&OK{Endpoints: []wire.ControlEndpoint{{URL: "http://agents.example.com"}}, Epoch: &three}) {
		t.Fatal("took plain http away from loopback")
	}
	if m.Adopt(&OK{Epoch: &three}) || m.URL != cloud.URL {
		t.Fatal("an ok with no list changed the membership")
	}
}

// #1996: a refused proof says what it means, where a person looks; anything else as it was.
func TestABadProofIsSaidInWords(t *testing.T) {
	u := &Uplink{Member: &Membership{Host: "mac"}}
	if said := u.problem(Refuse(BadProof)); !strings.Contains(said, "key as mac") || !strings.Contains(said, "new host code") {
		t.Fatal(said)
	}
	if said := u.problem(errors.New("dial: refused")); said != "dial: refused" {
		t.Fatal(said)
	}
}
