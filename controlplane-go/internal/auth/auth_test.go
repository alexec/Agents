package auth

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

// Web/test/vectors.json, which ControlAgreementVectorTests.swift writes: the Go
// derivations must give the same bytes as Swift's.
func TestTheSwiftVectors(t *testing.T) {
	raw, err := os.ReadFile("testdata/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Origin, ServerNonce, PeerNonce string
		Control                        struct{ Private, Public string }
		Client                         struct {
			ID, Identity, Private, Public, SharedX, Key string
			MAC                                         struct{ Peer, Server string }
		}
		Code struct {
			Secret, Identity, Key string
			MAC                   struct{ Peer, Server string }
		}
	}
	json.Unmarshal(raw, &v)
	h := func(s string) []byte { b, _ := hex.DecodeString(s); return b }
	sum := func(s string) []byte { b := sha256.Sum256([]byte(s)); return b[:] }
	controlPrivate := sum("agents-web-vector-control")
	clientPrivate := sum("agents-web-vector-client")
	pub, _ := PublicKey(controlPrivate)
	check := func(what string, got []byte, want string) {
		if hex.EncodeToString(got) != want {
			t.Errorf("%s: got %x want %s", what, got, want)
		}
	}
	check("control public", pub, v.Control.Public)
	shared, _ := SharedSecret(clientPrivate, pub)
	check("shared", shared, v.Client.SharedX)
	key, _ := ClientKey(controlPrivate, h(v.Client.Public), v.Client.ID)
	check("client key (server side)", key, v.Client.Key)
	sn, pn := h(v.ServerNonce), h(v.PeerNonce)
	check("client peer MAC", PeerMAC(key, sn, pn, v.Client.Identity, v.Origin), v.Client.MAC.Peer)
	check("client server MAC", ServerMAC(key, sn, pn, v.Client.Identity, v.Origin), v.Client.MAC.Server)
	secret := CodeSecret(controlPrivate, "000102030405060708090a0b0c0d0e0f")
	check("code secret", secret, v.Code.Secret)
	check("code key", CodeKey(secret), v.Code.Key)
	check("code peer MAC", PeerMAC(CodeKey(secret), sn, pn, v.Code.Identity, v.Origin), v.Code.MAC.Peer)

	// And the server's Verify takes the vector's auth.
	a := &Auth{ID: v.Client.Identity, Nonce: ToB64URL(pn), MAC: ToB64URL(h(v.Client.MAC.Peer)), Kind: "browser"}
	id, mac, err := Verify(a, sn, []string{"https://elsewhere:443", v.Origin}, func(Identity) ([]byte, error) { return key, nil })
	if err != nil || id.Kind != 'c' || hex.EncodeToString(mac) != v.Client.MAC.Server {
		t.Fatalf("verify: %v %c %x", err, id.Kind, mac)
	}
}

func TestACodeRoundTrips(t *testing.T) {
	priv := NewPrivateKey()
	pub, _ := PublicKey(priv)
	id, secret := MakeCodeSecret(priv)
	c := &Code{ControlKey: pub, Secret: secret, URL: "https://127.0.0.1:8791", Pin: "", Name: "Alex's Mac"}
	back, err := ParseCode(c.Text())
	if err != nil || back.ID() != id || back.Name != c.Name || back.URL != c.URL || back.Host {
		t.Fatalf("%v %+v", err, back)
	}
	if hex.EncodeToString(CodeSecret(priv, id)) != hex.EncodeToString(secret) {
		t.Fatal("the secret is not the id's")
	}
}
