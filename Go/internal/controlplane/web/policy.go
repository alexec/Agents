package web

import (
	"encoding/base64"
	"encoding/json"
	"net/url"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// viewPolicy is the part of AppViewPolicy (#187) that the sandbox proxy needs: what a view
// may reach, from its resource's _meta.ui.csp and nothing else. An entry is kept only when
// it is a plain origin, so a declared value cannot make the policy wider than an origin.
type viewPolicy struct {
	connect, resource, frame, baseURI []string
}

// policyFor is AppViewPolicy(csp:). csp is the decoded JSON, or nil for the strict default.
func policyFor(csp any) viewPolicy {
	fields, _ := csp.(map[string]any)
	origins := func(key string) []string {
		var kept []string
		values, _ := fields[key].([]any)
		for _, value := range values {
			text, ok := value.(string)
			if !ok {
				continue
			}
			origin, ok := originOf(text)
			if !ok {
				continue
			}
			found := false
			for _, k := range kept {
				found = found || k == origin
			}
			if !found {
				kept = append(kept, origin)
			}
		}
		return kept
	}
	return viewPolicy{
		connect:  origins("connectDomains"),
		resource: origins("resourceDomains"),
		frame:    origins("frameDomains"),
		baseURI:  origins("baseUriDomains"),
	}
}

// originOf is AppViewPolicy.origin(_:): text as a plain origin, lower-cased, or false. A
// plain origin has a scheme of https, wss, http or ws, a host with at most one "*." in
// front of it, and a port.
func originOf(text string) (string, bool) {
	value := strings.ToLower(strings.TrimFunc(text, func(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) }))
	scheme := ""
	for _, s := range []string{"https://", "wss://", "http://", "ws://"} {
		if strings.HasPrefix(value, s) {
			scheme = s
			break
		}
	}
	if scheme == "" {
		return "", false
	}
	rest := strings.TrimSuffix(value[len(scheme):], "/")
	host := rest
	if colon := strings.LastIndexByte(rest, ':'); colon >= 0 {
		port := rest[colon+1:]
		for _, c := range port {
			if c < '0' || c > '9' {
				return "", false
			}
		}
		number, err := strconv.Atoi(port)
		if err != nil || number < 1 || number > 65535 {
			return "", false
		}
		host = rest[:colon]
	}
	host = strings.TrimPrefix(host, "*.")
	if host == "" || utf8.RuneCountInString(host) > 253 {
		return "", false
	}
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return "", false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
				return "", false
			}
		}
	}
	return scheme + rest, true
}

// header is AppViewPolicy.header: the Content-Security-Policy value.
func (p viewPolicy) header() string {
	list := func(base, extra []string, none bool) string {
		all := append(append([]string{}, base...), extra...)
		if len(all) == 0 {
			if none {
				return "'none'"
			}
			return ""
		}
		return strings.Join(all, " ")
	}
	return strings.Join([]string{
		"default-src 'none'",
		"script-src " + list([]string{"'self'", "'unsafe-inline'"}, p.resource, false),
		"style-src " + list([]string{"'self'", "'unsafe-inline'"}, p.resource, false),
		"img-src " + list([]string{"'self'", "data:", "blob:"}, p.resource, false),
		"font-src " + list([]string{"'self'", "data:"}, p.resource, false),
		"media-src " + list([]string{"'self'", "data:", "blob:"}, p.resource, false),
		"connect-src " + list(nil, p.connect, true),
		"frame-src " + list(nil, p.frame, true),
		"object-src 'none'",
		"base-uri " + list([]string{"'self'"}, p.baseURI, false),
		"form-action 'none'",
	}, "; ")
}

// domains is LoopbackGate.domains(in:): the csp query's JSON (base64url), or nil for the
// strict default. The query is read as URLComponents reads it: a "+" stays a "+", and a bad
// percent escape anywhere spoils the whole query.
func domains(uri string) any {
	_, query, found := strings.Cut(uri, "?")
	if !found {
		return nil
	}
	query, _, _ = strings.Cut(query, "#")
	value, have := "", false
	for _, item := range strings.Split(query, "&") {
		rawName, rawValue, _ := strings.Cut(item, "=")
		name, err := url.PathUnescape(rawName)
		if err != nil {
			return nil
		}
		v, err := url.PathUnescape(rawValue)
		if err != nil {
			return nil
		}
		if name == "csp" && !have {
			value, have = v, true
		}
	}
	if !have || utf8.RuneCountInString(value) > 8192 {
		return nil
	}
	text := strings.NewReplacer("-", "+", "_", "/").Replace(value)
	for len(text)%4 != 0 {
		text += "="
	}
	data, err := base64.StdEncoding.DecodeString(text)
	if err != nil {
		return nil
	}
	var parsed any
	if json.Unmarshal(data, &parsed) != nil {
		return nil
	}
	return parsed
}
