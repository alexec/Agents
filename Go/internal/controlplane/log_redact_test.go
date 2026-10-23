package controlplane

import (
	"strings"
	"testing"
)

// The control plane's log cuts its own codes and the known token shapes a machine cuts
// out of transcripts (#1001, slice a3); plain words stay.
func TestTheLogCutsCodesAndTokenShapes(t *testing.T) {
	t.Parallel()
	github := "ghp_" + strings.Repeat("a1B2", 9)
	line := Redact("pair agents-control:3:abc then GITHUB_TOKEN " + github + " and token=xyz for host box")
	for _, gone := range []string{"agents-control:3:abc", github, "xyz"} {
		if strings.Contains(line, gone) {
			t.Fatalf("%q is in %q", gone, line)
		}
	}
	if !strings.Contains(line, "[redacted:github]") || !strings.Contains(line, "agents-control:<code>") || !strings.Contains(line, "for host box") {
		t.Fatalf("%q", line)
	}
	if plain := "hosts/list from MacBook Pro in 12ms"; Redact(plain) != plain {
		t.Fatalf("%q", Redact(plain))
	}
}
