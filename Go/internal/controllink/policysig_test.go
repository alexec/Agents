package controllink

import "testing"

// A policy's signature is over its canonical JSON: the same document with its keys in
// another order and spaces checks; a field changed, or one this build does not know
// added, does not (#998).
func TestAPolicySignatureIsOverItsCanonicalJSON(t *testing.T) {
	private := NewPrivateKey()
	public, err := PublicKey(private)
	if err != nil {
		t.Fatal(err)
	}
	raw := []byte(`{"version":3,"modeCeiling":"acceptEdits","budgets":{"daily":40.50,"raises":[]},"note":"<&>"}`)
	sig, err := SignPolicy(private, raw)
	if err != nil {
		t.Fatal(err)
	}
	canonical, err := CanonicalJSON(raw)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"budgets":{"daily":40.50,"raises":[]},"modeCeiling":"acceptEdits","note":"<&>","version":3}`; string(canonical) != want {
		t.Fatalf("%s", canonical)
	}
	if !VerifyPolicy(public, []byte(` { "note" : "<&>", "version": 3, "budgets": {"raises": [], "daily": 40.50}, "modeCeiling": "acceptEdits" }`), sig) {
		t.Fatal("the same document in another order does not check")
	}
	for _, other := range []string{
		`{"version":4,"modeCeiling":"acceptEdits","budgets":{"daily":40.50,"raises":[]},"note":"<&>"}`,
		`{"version":3,"modeCeiling":"acceptEdits","budgets":{"daily":40.50,"raises":[]},"note":"<&>","extra":true}`,
		`{"version":3,"modeCeiling":"acceptEdits","budgets":{"daily":40.5,"raises":[]},"note":"<&>"}`,
		`not json`,
	} {
		if VerifyPolicy(public, []byte(other), sig) {
			t.Errorf("%s checks", other)
		}
	}
	if VerifyPolicy(public, raw, sig[:63]) {
		t.Fatal("a short signature checks")
	}
	otherPublic, _ := PublicKey(NewPrivateKey())
	if VerifyPolicy(otherPublic, raw, sig) {
		t.Fatal("another key checks")
	}
	if KeyID(public) == KeyID(otherPublic) || len(KeyID(public)) != 11 {
		t.Fatal(KeyID(public))
	}
}
