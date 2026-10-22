// Package redact cuts known token shapes out of what agentsd writes (#1001, T8 slice a1):
// each transcript line and each daemon.log line. A shape is a pattern that only a secret
// of one kind matches, such as ghp_ and 36 letters or digits; a match becomes
// [redacted:<kind>]. Text with no known shape is not changed: a hash, an ID or a password
// in plain words stays as it is.
//
// The same patterns work on plain text and on a line of JSON. Before a shape, a JSON
// escape (\n, \t, \r) counts as a boundary as a space does, and no shape matches a quote
// or a backslash, so a redacted JSON line stays valid JSON.
package redact

import (
	"bytes"
	"regexp"
	"slices"
)

// shape is one kind of token. Its pattern runs only where a literal that every match holds
// is, anchored at a start from back bytes before the literal up to the literal, and only
// at a start that is a boundary. A line holds few literals, and a pattern that does not
// match there fails at once, so this costs a byte search, not a scan of the line.
type shape struct {
	kind     string
	literals []string
	back     int
	most     int
	re       *regexp.Regexp
	// keep is whether group 1, such as "Bearer ", stays.
	keep bool
}

func newShape(kind string, back, most int, pattern string, literals ...string) shape {
	return shape{kind: kind, literals: literals, back: back, most: most, re: regexp.MustCompile(`^(?:` + pattern + `)`)}
}

// atBoundary is whether a token can start at j: at the start, after a character that is
// not part of a word, or after a JSON escape for a new line or a tab.
func atBoundary(b []byte, j int) bool {
	if j == 0 {
		return true
	}
	c := b[j-1]
	if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') && c != '_' {
		return true
	}
	return j >= 2 && b[j-2] == '\\' && (c == 'n' || c == 'r' || c == 't')
}

// shapes go from the most particular to the least: an Anthropic key is tried before an
// OpenAI one, and any token before a Bearer header that may hold it.
var shapes = []shape{
	newShape("private-key", 48, 16384, `-----BEGIN [A-Z0-9 ]{0,32}PRIVATE KEY-----[^"]*?-----END [A-Z0-9 ]{0,32}PRIVATE KEY-----`, "PRIVATE KEY-----"),
	newShape("github", 0, 300, `gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{22,255}`, "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"),
	newShape("gitlab", 0, 300, `gl(?:pat|dt|rt|ptt|cbt|oas|soat)-[A-Za-z0-9_-]{20,255}`, "glpat-", "gldt-", "glrt-", "glptt-", "glcbt-", "gloas-", "glsoat-"),
	newShape("anthropic", 0, 300, `sk-ant-[A-Za-z0-9_-]{20,255}`, "sk-ant-"),
	newShape("openai", 0, 300, `sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{32,255}`, "sk-"),
	newShape("stripe", 2, 300, `(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,255}`, "_live_", "_test_"),
	newShape("aws", 0, 20, `(?:AKIA|ASIA)[A-Z0-9]{16}`, "AKIA", "ASIA"),
	newShape("google", 0, 39, `AIza[0-9A-Za-z_-]{35}`, "AIza"),
	newShape("slack", 0, 300, `xox[abposr]-[A-Za-z0-9-]{10,255}`, "xox"),
	newShape("npm", 0, 40, `npm_[A-Za-z0-9]{36}`, "npm_"),
	newShape("jwt", 0, 8192, `eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`, "eyJ"),
	newShape("agents-code", 0, 1024, `agents-control:[0-9]+:[^\s'"\\]+`, "agents-control:"),
	bearer,
}

// bearer keeps its "Bearer " (group 1) and cuts the token after it.
var bearer = func() shape {
	s := newShape("bearer", 1, 1024, `((?i:bearer)\s+)[A-Za-z0-9._~+/=-]{16,}`, "earer", "EARER")
	s.keep = true
	return s
}()

// Text is s with every known token shape replaced by [redacted:<kind>].
func Text(s string) string {
	b, changed := Bytes([]byte(s))
	if !changed {
		return s
	}
	return string(b)
}

// Bytes is b with every known token shape replaced, and whether anything was. When
// nothing was, it is b itself.
func Bytes(b []byte) ([]byte, bool) {
	changed := false
	for _, s := range shapes {
		if out, ok := s.redact(b); ok {
			b, changed = out, true
		}
	}
	return b, changed
}

// cut is one match: the bytes from..to go, and keep bytes of them at the front stay. Two
// literals can find the same match: the second is skipped.
type cut struct{ from, keep, to int }

// redact replaces s's matches in b, looking only where its literals are.
func (s shape) redact(b []byte) ([]byte, bool) {
	var cuts []cut
	for _, l := range s.literals {
		lit := []byte(l)
		for at := 0; ; {
			i := bytes.Index(b[at:], lit)
			if i < 0 {
				break
			}
			i += at
			at = i + len(lit)
			for j := max(0, i-s.back); j <= i; j++ {
				if !atBoundary(b, j) {
					continue
				}
				m := s.re.FindSubmatchIndex(b[j:min(len(b), j+s.most)])
				if m == nil {
					continue
				}
				c := cut{from: j, to: j + m[1]}
				if s.keep {
					c.keep = m[3] - m[2]
				}
				cuts = append(cuts, c)
				at = max(at, c.to)
				break
			}
		}
	}
	if len(cuts) == 0 {
		return b, false
	}
	slices.SortFunc(cuts, func(x, y cut) int { return x.from - y.from })
	out := make([]byte, 0, len(b))
	last := 0
	for _, c := range cuts {
		if c.from < last {
			continue
		}
		out = append(out, b[last:c.from+c.keep]...)
		out = append(out, "[redacted:"+s.kind+"]"...)
		last = c.to
	}
	return append(out, b[last:]...), true
}
