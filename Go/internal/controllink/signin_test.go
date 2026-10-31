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

// A sign-in's approval code is bound to the new client's key and the control key it trusts:
// a control plane that passes a sign-in on with its own key, or is another control plane,
// shows another code. The vector is the Swift and web clients' too.
func TestApprovalCodeIsBoundToBothKeys(t *testing.T) {
	client := bytes.Repeat([]byte{1}, 65)
	control := bytes.Repeat([]byte{2}, 65)
	if got := ApprovalCode(client, control); got != "8UMUNH" {
		t.Fatalf("ApprovalCode = %q", got)
	}
	if ApprovalCode(control, control) == ApprovalCode(client, control) || ApprovalCode(client, client) == ApprovalCode(client, control) {
		t.Fatal("the code does not change with the keys")
	}
	if got := JoinCode(client); got == ApprovalCode(client, nil) || len(got) != 6 {
		t.Fatalf("JoinCode = %q", got)
	}
}
