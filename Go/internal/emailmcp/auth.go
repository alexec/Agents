package emailmcp

import (
	"bufio"
	"bytes"
	"net/textproto"
	"strings"

	"github.com/emersion/go-imap/v2"
)

// Whether a message's sender is who its From says. The receiving mail server checks DMARC,
// DKIM and SPF and writes what it found in an Authentication-Results header (RFC 8601) at
// the top of the message. Only that topmost one is the receiving server's: the sender can
// write any number of its own below it. A message is authenticated when that header says
// dmarc=pass for the From domain, or dkim=pass with a signing domain aligned with it.

// authSection is the one header a summary fetches beside the envelope.
var authSection = &imap.FetchItemBodySection{Specifier: imap.PartSpecifierHeader,
	HeaderFields: []string{"Authentication-Results"}, Peek: true}

// authenticated is true when header (the fetched Authentication-Results lines) says the
// sender of from (the message's From, exactly one address) is who it says.
func authenticated(header []byte, from []string) bool {
	if len(from) != 1 {
		return false
	}
	_, domain, ok := strings.Cut(strings.ToLower(bare(from[0])), "@")
	if !ok || domain == "" {
		return false
	}
	fields, err := textproto.NewReader(bufio.NewReader(bytes.NewReader(append(header, '\r', '\n')))).ReadMIMEHeader()
	if err != nil && len(fields) == 0 {
		return false
	}
	results := fields.Values("Authentication-Results")
	if len(results) == 0 {
		return false
	}
	for _, result := range strings.Split(uncomment(results[0]), ";")[1:] {
		words := strings.Fields(strings.ToLower(result))
		if len(words) == 0 {
			continue
		}
		props := map[string]string{}
		for _, w := range words[1:] {
			if k, v, ok := strings.Cut(w, "="); ok {
				props[k] = strings.Trim(v, `"`)
			}
		}
		switch words[0] {
		case "dmarc=pass":
			if d, ok := props["header.from"]; !ok || d == domain {
				return true
			}
		case "dkim=pass":
			d := props["header.d"]
			if d == "" {
				_, d, _ = strings.Cut(props["header.i"], "@")
			}
			if d != "" && (d == domain || strings.HasSuffix(domain, "."+d)) {
				return true
			}
		}
	}
	return false
}

// uncomment drops the (comments) from a header value, which can hold any text.
func uncomment(s string) string {
	var b strings.Builder
	depth := 0
	for _, r := range s {
		switch {
		case r == '(':
			depth++
		case r == ')' && depth > 0:
			depth--
		case depth == 0:
			b.WriteRune(r)
		}
	}
	return b.String()
}
