package emailmcp

import (
	"bytes"
	"os"
	"testing"
)

// Only the receiving server's Authentication-Results, the topmost, says who sent a mail; a
// header the sender wrote below it, or a pass for another domain, says nothing.
func TestAuthenticatedReadsOnlyTheTopmostResult(t *testing.T) {
	github := []string{"GitHub <noreply@github.com>"}
	for _, c := range []struct {
		name   string
		header string
		from   []string
		want   bool
	}{
		{"dmarc pass", "Authentication-Results: mx.example.com; dkim=pass header.d=github.com; spf=pass smtp.mailfrom=github.com;\r\n dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=github.com\r\n", github, true},
		{"dkim aligned", "Authentication-Results: mx.example.com; dkim=pass (2048-bit key) header.d=github.com header.s=pf2023; dmarc=none\r\n", github, true},
		{"dkim of a parent domain", "Authentication-Results: mx.example.com; dkim=pass header.i=@gitlab.com\r\n", []string{"gitlab@mg.gitlab.com"}, true},
		{"dkim of another domain", "Authentication-Results: mx.example.com; dkim=pass header.d=evil.example; dmarc=fail header.from=github.com\r\n", github, false},
		{"dmarc for another domain", "Authentication-Results: mx.example.com; dmarc=pass header.from=evil.example\r\n", github, false},
		{"dmarc fail", "Authentication-Results: mx.example.com; spf=pass; dmarc=fail header.from=github.com\r\n", github, false},
		{"a pass in a comment", "Authentication-Results: mx.example.com; dmarc=fail (dmarc=pass header.from=github.com) header.from=github.com\r\n", github, false},
		{"a pass below the server's", "Authentication-Results: mx.example.com; dmarc=fail header.from=github.com\r\nAuthentication-Results: mx.example.com; dmarc=pass header.from=github.com\r\n", github, false},
		{"no header", "", github, false},
		{"two senders", "Authentication-Results: mx.example.com; dmarc=pass header.from=github.com\r\n", []string{"noreply@github.com", "a@evil.example"}, false},
		// Fastmail writes its results in several headers, the dkim and dmarc in the last (#4322).
		{"results in several headers", "Authentication-Results: mx.example.com; x-csa=none\r\nAuthentication-Results: mx.example.com; bimi=none\r\nAuthentication-Results: mx.example.com; dkim=pass header.d=github.com; dmarc=pass header.from=github.com\r\nReceived: from out.github.com by mx.example.com\r\n", github, true},
		{"a pass below the server's Received", "Authentication-Results: mx.example.com; x-csa=none\r\nReceived: from out.evil.example by mx.example.com\r\nAuthentication-Results: mx.example.com; dmarc=pass header.from=github.com\r\n", github, false},
		{"a pass from another authserv-id", "Authentication-Results: mx.example.com; x-csa=none\r\nAuthentication-Results: mx.evil.example; dmarc=pass header.from=github.com\r\n", github, false},
		{"the server's Received above its results", "Received: from mx-in by mx.example.com\r\nAuthentication-Results: mx.example.com; dmarc=pass header.from=github.com\r\n", github, true},
	} {
		if got := authenticated([]byte(c.header), c.from); got != c.want {
			t.Errorf("%s: %v", c.name, got)
		}
	}
}

// A channel link needs DKIM itself (#1762): a DMARC pass without an aligned DKIM pass (SPF
// alone) gives no signing domain.
func TestAlignedDKIMIsTheSigningDomain(t *testing.T) {
	github := []string{"GitHub <noreply@github.com>"}
	for _, c := range []struct {
		header string
		from   []string
		want   string
	}{
		{"Authentication-Results: mx.example.com; dkim=pass header.d=github.com; dmarc=pass header.from=github.com\r\n", github, "github.com"},
		{"Authentication-Results: mx.example.com; dkim=pass header.i=@gitlab.com\r\n", []string{"gitlab@mg.gitlab.com"}, "gitlab.com"},
		{"Authentication-Results: mx.example.com; spf=pass; dmarc=pass header.from=github.com\r\n", github, ""},
		{"Authentication-Results: mx.example.com; dkim=pass header.d=evil.example\r\n", github, ""},
		{"Authentication-Results: mx.example.com; dkim=fail header.d=github.com\r\n", github, ""},
	} {
		if got := alignedDKIM([]byte(c.header), c.from); got != c.want {
			t.Errorf("%q: %q", c.header, got)
		}
	}
}

// The saved Microsoft sign-up mail (#4322, scratch data): its dkim and dmarc pass are in
// the fourth of the receiving server's Authentication-Results headers.
func TestAuthenticatedReadsSplitResults(t *testing.T) {
	raw, err := os.ReadFile("testdata/split-results.eml")
	if err != nil {
		t.Fatal(err)
	}
	from := []string{"Microsoft account team <account-security-noreply@accountprotection.microsoft.com>"}
	header, _, _ := bytes.Cut(raw, []byte("\n\n"))
	if !authenticated(header, from) || alignedDKIM(header, from) != "accountprotection.microsoft.com" {
		t.Fatalf("authenticated %v, dkim %q", authenticated(header, from), alignedDKIM(header, from))
	}
}
