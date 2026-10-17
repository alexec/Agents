// Package skillcatalog is skills added from a catalogue, and the files the `skills` CLI shares
// with the app (059, AgentsKit/Catalog): its two lock files, the hashes a skill is known by,
// a SKILL.md's front matter, and adding and taking out a skill without touching the
// person's own.
package skillcatalog

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
)

// Value is JSON that keeps its objects' key order and its numbers' text (OrderedJSON), so
// a file the CLI wrote comes back out as the CLI would write it.
type Value struct {
	Kind   byte // 'o' object, 'a' array, 's' string, 'n' number, 'b' bool, 'z' null
	Pairs  []Pair
	Items  []Value
	String string // a string's value, or a number's text
	Bool   bool
}

// Pair is one key of an object.
type Pair struct {
	Key   string
	Value Value
}

func Object(pairs ...Pair) Value { return Value{Kind: 'o', Pairs: pairs} }
func String(s string) Value      { return Value{Kind: 's', String: s} }
func Number(text string) Value   { return Value{Kind: 'n', String: text} }

// Parse reads one JSON value.
func Parse(b []byte) (Value, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	v, err := parseValue(dec)
	if err != nil {
		return Value{}, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return Value{}, errors.New("more after the value")
	}
	return v, nil
}

func parseValue(dec *json.Decoder) (Value, error) {
	t, err := dec.Token()
	if err != nil {
		return Value{}, err
	}
	switch t := t.(type) {
	case json.Delim:
		switch t {
		case '{':
			v := Value{Kind: 'o', Pairs: []Pair{}}
			for dec.More() {
				k, err := dec.Token()
				if err != nil {
					return Value{}, err
				}
				key, _ := k.(string)
				item, err := parseValue(dec)
				if err != nil {
					return Value{}, err
				}
				v.Set(key, item)
			}
			_, err := dec.Token()
			return v, err
		case '[':
			v := Value{Kind: 'a', Items: []Value{}}
			for dec.More() {
				item, err := parseValue(dec)
				if err != nil {
					return Value{}, err
				}
				v.Items = append(v.Items, item)
			}
			_, err := dec.Token()
			return v, err
		}
		return Value{}, fmt.Errorf("unexpected %v", t)
	case string:
		return String(t), nil
	case json.Number:
		return Number(t.String()), nil
	case bool:
		return Value{Kind: 'b', Bool: t}, nil
	case nil:
		return Value{Kind: 'z'}, nil
	}
	return Value{}, fmt.Errorf("unexpected %v", t)
}

// Get is an object's value for key.
func (v Value) Get(key string) (Value, bool) {
	for _, p := range v.Pairs {
		if p.Key == key {
			return p.Value, true
		}
	}
	return Value{}, false
}

// Str is the string at key, or "".
func (v Value) Str(key string) (string, bool) {
	x, ok := v.Get(key)
	if !ok || x.Kind != 's' {
		return "", false
	}
	return x.String, true
}

// Set puts key at the end, or in its place when it is there (a later duplicate wins, as
// JSON.parse has it).
func (v *Value) Set(key string, x Value) {
	for i := range v.Pairs {
		if v.Pairs[i].Key == key {
			v.Pairs[i].Value = x
			return
		}
	}
	v.Pairs = append(v.Pairs, Pair{key, x})
}

func (v *Value) Remove(key string) {
	for i := range v.Pairs {
		if v.Pairs[i].Key == key {
			v.Pairs = append(v.Pairs[:i], v.Pairs[i+1:]...)
			return
		}
	}
}

// Stringified is `JSON.stringify(value, null, 2)`.
func (v Value) Stringified() string {
	var b strings.Builder
	v.write(&b, "")
	return b.String()
}

func (v Value) write(b *strings.Builder, indent string) {
	switch v.Kind {
	case 'o':
		if len(v.Pairs) == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteString("{\n")
		for i, p := range v.Pairs {
			b.WriteString(indent + "  ")
			writeString(b, p.Key)
			b.WriteString(": ")
			p.Value.write(b, indent+"  ")
			if i < len(v.Pairs)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString(indent + "}")
	case 'a':
		if len(v.Items) == 0 {
			b.WriteString("[]")
			return
		}
		b.WriteString("[\n")
		for i, x := range v.Items {
			b.WriteString(indent + "  ")
			x.write(b, indent+"  ")
			if i < len(v.Items)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString(indent + "]")
	case 's':
		writeString(b, v.String)
	case 'n':
		b.WriteString(jsNumber(v.String))
	case 'b':
		if v.Bool {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	default:
		b.WriteString("null")
	}
}

// writeString is a string as JSON.stringify writes it: only the quote, the backslash and
// control characters escaped, the short forms where there is one.
func writeString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				fmt.Fprintf(b, `\u%04x`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
}

// jsNumber is a number as JavaScript prints it once parsed: 1.50 is 1.5, 1e3 is 1000.
func jsNumber(text string) string {
	f, err := strconv.ParseFloat(text, 64)
	if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
		return text
	}
	if f == 0 {
		return "0"
	}
	if a := math.Abs(f); a >= 1e-6 && a < 1e21 {
		return strconv.FormatFloat(f, 'f', -1, 64)
	}
	s := strconv.FormatFloat(f, 'e', -1, 64)
	mantissa, exp, _ := strings.Cut(s, "e")
	sign := exp[:1]
	exp = strings.TrimLeft(exp[1:], "0")
	return mantissa + "e" + sign + exp
}
