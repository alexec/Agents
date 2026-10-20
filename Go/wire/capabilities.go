package wire

import "sort"

// Served is the capability list of a server of one document (#1748): each capability whose
// methods it serves, every one, and the ones it declares. A capability that names only
// notifications is the document's to send, so it is in. Sorted, each once.
func Served(table map[string]string, notifications map[string]bool, serves func(method string) bool, declared ...string) []string {
	has := map[string]bool{}
	for method, c := range table {
		if _, seen := has[c]; !seen {
			has[c] = true
		}
		if !notifications[method] && !serves(method) {
			has[c] = false
		}
	}
	var out []string
	for c, ok := range has {
		if ok {
			out = append(out, c)
		}
	}
	for _, c := range declared {
		if !has[c] {
			has[c] = true
			out = append(out, c)
		}
	}
	sort.Strings(out)
	return out
}

// Has says a list has a capability.
func Has(list []string, capability string) bool {
	for _, c := range list {
		if c == capability {
			return true
		}
	}
	return false
}

// Missing is each of required that list does not have, in required's order; nil for none.
func Missing(list, required []string) []string {
	var out []string
	for _, c := range required {
		if !Has(list, c) {
			out = append(out, c)
		}
	}
	return out
}
