package wire

import "crypto/rand"

// Project ids (#2317): written by hand, as the machine makes them and the control plane
// checks them.

// NewProjectID is "p-" and 12 random lower-case letters and digits.
func NewProjectID() string {
	const letters = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 12)
	rand.Read(b)
	for i := range b {
		b[i] = letters[int(b[i])%len(letters)]
	}
	return "p-" + string(b)
}

// ValidProjectID says an id is 1–64 letters, digits, '-' and '_', so a hand-written one
// works too (FR-012).
func ValidProjectID(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}
