package machine

import "testing"

func TestAGivenIDWins(t *testing.T) {
	t.Setenv("AGENTS_MACHINE_ID", " given ")
	if got := ID(); got != "given" {
		t.Fatalf("got %q", got)
	}
	t.Setenv("AGENTS_MACHINE_ID", "")
	if ID() == "" {
		t.Fatal("no id")
	}
}
