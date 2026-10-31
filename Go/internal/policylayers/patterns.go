package policylayers

import "strings"

// matches reports whether name fits pattern: an exact match, or, when pattern ends in "*",
// a prefix match (research R6: "a trailing * in a model or variable name matches a
// prefix, as today").
func matches(pattern, name string) bool {
	if strings.HasSuffix(pattern, "*") {
		return strings.HasPrefix(name, pattern[:len(pattern)-1])
	}
	return pattern == name
}

// allowedBy reports whether name fits at least one pattern of list.
func allowedBy(list []string, name string) bool {
	for _, p := range list {
		if matches(p, name) {
			return true
		}
	}
	return false
}

// intersectPatterns is the effective allowlist of two layers that both set one (FR-004:
// "fewer: a name that a layer leaves out is not allowed"). A pattern only matters if some
// name could fit it, so the result is the patterns mentioned by either list that both lists
// would allow.
func intersectPatterns(a, b []string) []string {
	var out []string
	add := func(list, other []string) {
		for _, p := range list {
			name := strings.TrimSuffix(p, "*")
			if allowedBy(other, name) || allowedBy(other, p) {
				out = append(out, p)
			}
		}
	}
	add(a, b)
	add(b, a)
	return dedupe(out)
}

func dedupe(list []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range list {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// sameSet reports whether a and b name the same patterns, in any order.
func sameSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	seen := map[string]int{}
	for _, s := range a {
		seen[s]++
	}
	for _, s := range b {
		seen[s]--
	}
	for _, n := range seen {
		if n != 0 {
			return false
		}
	}
	return true
}
