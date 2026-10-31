package wire

import "testing"

// A receiver reads machine/* and machines/* as host/* and hosts/* (#2653).
func TestOldMethodName(t *testing.T) {
	for method, want := range map[string]string{
		"machines/list":     "hosts/list",
		"machines/announce": "hosts/announce",
		"machine/hello":     "host/hello",
		"machine/clients":   "host/clients",
		// The old names, and the machines/* methods that had the new name already, stay.
		"hosts/list":        "hosts/list",
		"host/hello":        "host/hello",
		"machines/forAgent": "machines/forAgent",
		"machines/nonesuch": "machines/nonesuch",
		"agents/list":       "agents/list",
		"":                  "",
	} {
		if got := OldMethodName(method); got != want {
			t.Errorf("OldMethodName(%q) = %q, want %q", method, got, want)
		}
	}
}

// A sender sends host/* and hosts/* as machine/* and machines/* (#2653).
func TestNewMethodName(t *testing.T) {
	for method, want := range map[string]string{
		"hosts/list":        "machines/list",
		"hosts/announce":    "machines/announce",
		"host/hello":        "machine/hello",
		"host/clients":      "machine/clients",
		// Names with no old prefix, including the new ones already, stay.
		"machines/list":     "machines/list",
		"machines/forAgent": "machines/forAgent",
		"agents/list":       "agents/list",
		"":                  "",
	} {
		if got := NewMethodName(method); got != want {
			t.Errorf("NewMethodName(%q) = %q, want %q", method, got, want)
		}
	}
}
