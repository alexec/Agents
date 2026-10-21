package controllink

import (
	"bytes"
	"testing"
)

// The Swift clients make the same nonce (ControlSignInTests): one vector for both.
func TestSignInNonceVector(t *testing.T) {
	key := append([]byte{4}, make([]byte, 64)...)
	for i := 1; i <= 64; i++ {
		key[i] = byte(i)
	}
	got := SignInNonce(key, bytes.Repeat([]byte{7}, 32))
	if got != "f399352dbd13beb7c27b5061d7085781ee74d846b27756855bb0fc428a15e0dc" {
		t.Fatal(got)
	}
}
