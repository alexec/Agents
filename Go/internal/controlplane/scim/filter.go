package scim

import (
	"net/http"
	"strings"
)

// Clause is one attr eq value of a filter.
type Clause struct {
	// Attr is the attribute's path, in lower case, with no schema URN: username,
	// emails.value.
	Attr  string
	Value string
}

// ParseFilter reads a filter of eq clauses joined by and (RFC 7644 §3.4.2.2): all that
// Okta and Entra send. Anything else is 400 invalidFilter.
func ParseFilter(filter string) ([]Clause, *Error) {
	filter = strings.TrimSpace(filter)
	if filter == "" {
		return nil, nil
	}
	if len(filter) > 1024 {
		return nil, invalidFilter("The filter is too long.")
	}
	var out []Clause
	rest := filter
	for {
		attr, after, ok := cutSpace(rest)
		if !ok {
			return nil, invalidFilter("A filter is attr eq \"value\".")
		}
		op, after, ok := cutSpace(after)
		if !ok || !strings.EqualFold(op, "eq") {
			return nil, invalidFilter("Only eq is supported, joined by and.")
		}
		value, after, err := readValue(after)
		if err != nil {
			return nil, err
		}
		out = append(out, Clause{Attr: strings.ToLower(topPath(attr)), Value: value})
		after = strings.TrimSpace(after)
		if after == "" {
			return out, nil
		}
		joiner, next, ok := cutSpace(after)
		if !ok || !strings.EqualFold(joiner, "and") {
			return nil, invalidFilter("Only eq is supported, joined by and.")
		}
		rest = next
	}
}

func invalidFilter(detail string) *Error {
	return Errorf(http.StatusBadRequest, "invalidFilter", "%s", detail)
}

// topPath is an attribute path with no core schema URN in front.
func topPath(a string) string {
	for _, urn := range []string{SchemaUser + ":", SchemaGroup + ":"} {
		if len(a) > len(urn) && strings.EqualFold(a[:len(urn)], urn) {
			return a[len(urn):]
		}
	}
	return a
}

func cutSpace(s string) (string, string, bool) {
	s = strings.TrimLeft(s, " ")
	i := strings.IndexByte(s, ' ')
	if i <= 0 {
		return "", "", false
	}
	return s[:i], s[i+1:], true
}

// readValue reads a JSON string, true, false or a number, and what follows it.
func readValue(s string) (string, string, *Error) {
	s = strings.TrimLeft(s, " ")
	if strings.HasPrefix(s, `"`) {
		var b strings.Builder
		for i := 1; i < len(s); i++ {
			switch s[i] {
			case '\\':
				if i+1 >= len(s) {
					return "", "", invalidFilter("A value ends in the middle.")
				}
				i++
				b.WriteByte(s[i])
			case '"':
				return b.String(), s[i+1:], nil
			default:
				b.WriteByte(s[i])
			}
		}
		return "", "", invalidFilter("A value has no closing quote.")
	}
	end := strings.IndexByte(s, ' ')
	if end < 0 {
		end = len(s)
	}
	word := s[:end]
	if word == "" || strings.EqualFold(word, "null") {
		return "", "", invalidFilter("A value is a string, true, false or a number.")
	}
	return strings.ToLower(word), s[end:], nil
}

// userMatches says a user matches every clause. userName and emails are not case
// sensitive (RFC 7643 §4.1); externalId and id are.
func userMatches(u User, clauses []Clause) bool {
	for _, c := range clauses {
		switch c.Attr {
		case "username":
			if !strings.EqualFold(u.UserName, c.Value) {
				return false
			}
		case "externalid":
			if u.ExternalID != c.Value {
				return false
			}
		case "id":
			if u.ID != c.Value {
				return false
			}
		case "active":
			if (c.Value == "true") != u.Active {
				return false
			}
		case "emails.value", "emails":
			found := false
			for _, e := range u.Emails {
				found = found || strings.EqualFold(e.Value, c.Value)
			}
			if !found {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func groupMatches(g Group, clauses []Clause) bool {
	for _, c := range clauses {
		switch c.Attr {
		case "displayname":
			if !strings.EqualFold(g.DisplayName, c.Value) {
				return false
			}
		case "externalid":
			if g.ExternalID != c.Value {
				return false
			}
		case "id":
			if g.ID != c.Value {
				return false
			}
		case "members", "members.value":
			found := false
			for _, m := range g.Members {
				found = found || m.Value == c.Value
			}
			if !found {
				return false
			}
		default:
			return false
		}
	}
	return true
}

var (
	userFilters  = map[string]bool{"username": true, "externalid": true, "id": true, "active": true, "emails.value": true, "emails": true}
	groupFilters = map[string]bool{"displayname": true, "externalid": true, "id": true, "members": true, "members.value": true}
)

// onlyAttrs refuses a clause on an attribute that is not filtered on here.
func onlyAttrs(clauses []Clause, allowed map[string]bool) *Error {
	for _, c := range clauses {
		if !allowed[c.Attr] {
			return invalidFilter("Filtering on " + c.Attr + " is not supported here.")
		}
	}
	return nil
}
