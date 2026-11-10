package emailmcp

import (
	"bufio"
	"bytes"
	"strings"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-message/textproto"
)

// Whether a message's sender is who its From says. The receiving mail server checks DMARC,
// DKIM and SPF and writes what it found in an Authentication-Results header (RFC 8601) at
// the top of the message. Only that topmost one is the receiving server's: the sender can
// write any number of its own below it. A message is authenticated when that header says
// dmarc=pass for the From domain, or dkim=pass with a signing domain aligned with it.

// authSection is the one header a summary fetches beside the envelope.
var authSection = &imap.FetchItemBodySection{Specifier: imap.PartSpecifierHeader,
	HeaderFields: []string{"Authentication-Results"}, Peek: true}

// authenticated is true when header (the fetched Authentication-Results and Received lines) says the
// sender of from (the message's From, exactly one address) is who it says.
func authenticated(header []byte, from []string) bool {
	dmarc, dkim := authResults(header, from)
	return dmarc || dkim != ""
}

// alignedDKIM is the signing domain of a dkim=pass aligned with From's one address, or ""
// (#1762): what a channel link checks for an email, which DMARC alone does not give.
func alignedDKIM(header []byte, from []string) string {
	_, dkim := authResults(header, from)
	return dkim
}

// authResults reads the receiving server's Authentication-Results for From's one address:
// whether DMARC passed for its domain, and the domain of a DKIM pass aligned with it.
func authResults(header []byte, from []string) (dmarc bool, dkim string) {
	if len(from) != 1 {
		return false, ""
	}
	_, domain, ok := strings.Cut(strings.ToLower(bare(from[0])), "@")
	if !ok || domain == "" {
		return false, ""
	}
	for _, result := range receivingResults(header) {
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
				dmarc = true
			}
		case "dkim=pass":
			d := props["header.d"]
			if d == "" {
				_, d, _ = strings.Cut(props["header.i"], "@")
			}
			if d != "" && dkim == "" && (d == domain || strings.HasSuffix(domain, "."+d)) {
				dkim = d
			}
		}
	}
	return dmarc, dkim
}

// receivingResults are the results (resinfo, between the semicolons, comments dropped) of
// the receiving server's Authentication-Results: the topmost header, and each one straight
// after it with the same authserv-id, up to the first Received line. The first of them that
// names a method (dkim, dmarc…) has the say for it, so a header the sender wrote below with
// the same authserv-id cannot turn the server's dmarc=fail into a pass.
func receivingResults(header []byte) []string {
	h, err := textproto.ReadHeader(bufio.NewReader(bytes.NewReader(append(header, '\r', '\n'))))
	if err != nil && h.Len() == 0 {
		return nil
	}
	var out []string
	id, said := "", map[string]bool{}
	for fields := h.Fields(); fields.Next(); {
		if strings.EqualFold(fields.Key(), "Received") {
			if id != "" {
				break
			}
			continue // a Received above the results: the receiving server's own hops
		}
		if !strings.EqualFold(fields.Key(), "Authentication-Results") {
			continue
		}
		parts := strings.Split(uncomment(fields.Value()), ";")
		authserv := strings.ToLower(strings.TrimSpace(parts[0]))
		if id == "" {
			id = authserv
		} else if authserv != id {
			break
		}
		here := map[string]bool{}
		for _, result := range parts[1:] {
			method, _, _ := strings.Cut(strings.ToLower(strings.TrimSpace(result)), "=")
			if method == "" || said[method] {
				continue
			}
			here[method] = true
			out = append(out, result)
		}
		for method := range here {
			said[method] = true
		}
	}
	return out
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
