package buildinfo

import "testing"

func TestString(t *testing.T) {
	if got, want := String(), "dev (go)"; got != want {
		t.Fatalf("String() = %q, want %q", got, want)
	}
}
