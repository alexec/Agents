// Package yamlnode reads the front matter of a workflow or a persona as the Swift host's
// YAMLNode does: block mappings and sequences by indentation, inline lists, quoted
// scalars, comments; every value a string. It is not YAML: it is the app's own small part
// of it, so a file reads the same on either host (#1134).
package yamlnode

import (
	"fmt"
	"strings"
)

// Node is one of a scalar, a sequence or a mapping.
type Node struct {
	Scalar   *string
	Sequence []Node
	Mapping  map[string]Node
	isSeq    bool
}

func scalar(s string) Node { return Node{Scalar: &s} }

// Text is the scalar, and false for anything else.
func (n Node) Text() (string, bool) {
	if n.Scalar == nil {
		return "", false
	}
	return *n.Scalar, true
}

// IsMapping is whether the node is a mapping.
func (n Node) IsMapping() bool { return n.Mapping != nil }

// Values is YAMLNode.sequenceValues: a sequence's scalars, a scalar as a list of one (or
// none when empty), and false for a mapping.
func (n Node) Values() ([]string, bool) {
	switch {
	case n.isSeq:
		var out []string
		for _, e := range n.Sequence {
			if s, ok := e.Text(); ok {
				out = append(out, s)
			}
		}
		return out, true
	case n.Scalar != nil:
		if *n.Scalar == "" {
			return []string{}, true
		}
		return []string{*n.Scalar}, true
	}
	return nil, false
}

// Failure is a sentence for the person.
type Failure struct{ Message string }

func (f *Failure) Error() string { return f.Message }

func fail(format string, args ...any) error { return &Failure{fmt.Sprintf(format, args...)} }

// MappingFrom is YAMLNode.mapping(from:): the lines between the --- of a block.
func MappingFrom(lines []string) (map[string]Node, error) {
	var ls []line
	for i, raw := range lines {
		if l, ok := newLine(i, raw); ok {
			ls = append(ls, l)
		}
	}
	r := &reader{lines: ls}
	node, err := r.block(0)
	if err != nil {
		return nil, err
	}
	if node.Mapping == nil {
		if s, ok := node.Text(); !ok || s != "" {
			return nil, fail("The metadata is not a list of keys")
		}
		return map[string]Node{}, nil
	}
	return node.Mapping, nil
}

type line struct {
	indent int
	text   string
	number int
}

func newLine(i int, raw string) (line, bool) {
	without := stripComment(raw)
	trimmed := strings.Trim(without, " \t")
	if trimmed == "" {
		return line{}, false
	}
	return line{indent: len(without) - len(strings.TrimLeft(without, " ")), text: trimmed, number: i + 2}, true
}

func stripComment(s string) string {
	rs := []rune(s)
	var quote rune
	var out []rune
	for i, c := range rs {
		if quote != 0 {
			if c == quote {
				quote = 0
			}
		} else if c == '"' || c == '\'' {
			quote = c
		} else if c == '#' {
			if i == 0 || rs[i-1] == ' ' {
				break
			}
		}
		out = append(out, c)
	}
	return string(out)
}

type reader struct {
	lines []line
	index int
}

func (r *reader) current() (line, bool) {
	if r.index < len(r.lines) {
		return r.lines[r.index], true
	}
	return line{}, false
}

func isDash(t string) bool { return strings.HasPrefix(t, "- ") || t == "-" }

func (r *reader) block(indent int) (Node, error) {
	first, ok := r.current()
	if !ok || first.indent < indent {
		return scalar(""), nil
	}
	if isDash(first.text) {
		items, err := r.sequence(first.indent)
		return Node{Sequence: items, isSeq: true}, err
	}
	pairs, err := r.mapping(first.indent)
	return Node{Mapping: pairs}, err
}

func (r *reader) sequence(indent int) ([]Node, error) {
	items := []Node{}
	for {
		l, ok := r.current()
		if !ok || l.indent != indent || !isDash(l.text) {
			return items, nil
		}
		r.index++
		entry := ""
		if l.text != "-" {
			entry = strings.Trim(l.text[2:], " \t")
		}
		switch key, value, isKey := split(entry); {
		case entry == "":
			n, err := r.block(indent + 1)
			if err != nil {
				return nil, err
			}
			items = append(items, n)
		case isKey:
			pairs := map[string]Node{}
			if value == "" {
				n, err := r.block(indent + 1)
				if err != nil {
					return nil, err
				}
				pairs[key] = n
			} else {
				n, err := inline(value, l.number)
				if err != nil {
					return nil, err
				}
				pairs[key] = n
			}
			items = append(items, Node{Mapping: pairs})
		default:
			n, err := inline(entry, l.number)
			if err != nil {
				return nil, err
			}
			items = append(items, n)
		}
	}
}

func (r *reader) mapping(indent int) (map[string]Node, error) {
	pairs := map[string]Node{}
	for {
		l, ok := r.current()
		if !ok || l.indent != indent || strings.HasPrefix(l.text, "- ") {
			return pairs, nil
		}
		key, value, isKey := split(l.text)
		if !isKey {
			return nil, fail("Line %d: \"%s\" is not a key", l.number, l.text)
		}
		r.index++
		var n Node
		var err error
		if value == "" {
			n, err = r.block(indent + 1)
		} else {
			n, err = inline(value, l.number)
		}
		if err != nil {
			return nil, err
		}
		pairs[key] = n
	}
}

// split is a key and its value at the first colon outside quotes that is followed by a
// space or the end of the line.
func split(text string) (string, string, bool) {
	rs := []rune(text)
	var quote rune
	for i, c := range rs {
		if quote != 0 {
			if c == quote {
				quote = 0
			}
			continue
		}
		if c == '"' || c == '\'' {
			quote = c
			continue
		}
		if c != ':' || (i+1 < len(rs) && rs[i+1] != ' ') {
			continue
		}
		key := strings.Trim(string(rs[:i]), " \t")
		value := strings.Trim(string(rs[i+1:]), " \t")
		if key == "" {
			return "", "", false
		}
		return key, value, true
	}
	return "", "", false
}

func inline(text string, number int) (Node, error) {
	if !strings.HasPrefix(text, "[") {
		return scalar(unquote(text)), nil
	}
	if !strings.HasSuffix(text, "]") {
		return Node{}, fail("Line %d: \"%s\" opens a list and never closes it", number, text)
	}
	inner := text[1 : len(text)-1]
	if strings.TrimSpace(inner) == "" {
		return Node{Sequence: []Node{}, isSeq: true}, nil
	}
	var items []Node
	for _, p := range splitInline(inner) {
		items = append(items, scalar(unquote(p)))
	}
	return Node{Sequence: items, isSeq: true}, nil
}

func splitInline(text string) []string {
	var parts []string
	var cur strings.Builder
	var quote rune
	for _, c := range text {
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
			}
			cur.WriteRune(c)
		case c == '"' || c == '\'':
			quote = c
			cur.WriteRune(c)
		case c == ',':
			parts = append(parts, strings.Trim(cur.String(), " \t"))
			cur.Reset()
		default:
			cur.WriteRune(c)
		}
	}
	if last := strings.Trim(cur.String(), " \t"); last != "" {
		parts = append(parts, last)
	}
	return parts
}

func unquote(text string) string {
	rs := []rune(text)
	if len(rs) >= 2 && rs[0] == rs[len(rs)-1] && (rs[0] == '"' || rs[0] == '\'') {
		return string(rs[1 : len(rs)-1])
	}
	return text
}
