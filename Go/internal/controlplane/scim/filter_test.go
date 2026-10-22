package scim

import "testing"

// Filters of eq joined by and, as Okta and Entra send them; anything else is 400
// invalidFilter (FR-022).
func TestParseFilter(t *testing.T) {
	got, err := ParseFilter(`id eq "g1" and members eq "u \"2\""`)
	if err != nil || len(got) != 2 || got[0] != (Clause{"id", "g1"}) || got[1] != (Clause{"members", `u "2"`}) {
		t.Fatal(got, err)
	}
	got, err = ParseFilter(`urn:ietf:params:scim:schemas:core:2.0:User:userName eq "Lee@Acme.test"`)
	if err != nil || got[0] != (Clause{"username", "Lee@Acme.test"}) {
		t.Fatal(got, err)
	}
	for _, bad := range []string{`userName co "x"`, `userName eq "x" or id eq "y"`, `userName eq "x`, `userName eq`, `userName eq null`} {
		if _, err := ParseFilter(bad); err == nil || err.SCIMType != "invalidFilter" {
			t.Fatal(bad, err)
		}
	}
}
