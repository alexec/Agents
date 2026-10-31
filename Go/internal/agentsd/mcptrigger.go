package agentsd

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// A workflow trigger naming an MCP server's event (#383), such as `checks.failed`: Swift's
// MCPEventTrigger. Named as the server names it; without `server:` it hears every server
// this folder can use that offers the name, with it only those. Every other key under it
// is an argument of the subscription, sent to the server as it is: only the server knows
// how to filter its own events. On the wire and in the workflow's record it goes as an
// unrecognised trigger does, and is read back as one by its name.

const (
	mcpServerKey = "server"
	// mcpArgumentLimit is the most a trigger's arguments may take as JSON.
	mcpArgumentLimit = 2048
)

var serverNameRule = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

type mcpTrigger struct {
	event string
	// servers is nil for every server here that offers the event.
	servers   []string
	arguments map[string]json.RawMessage
}

// mcpTriggerOf reads a trigger's name and keys as a server's event, `server:` taken out.
// False when the name is not a server's event, or `server:` is not a name or a list of them.
func mcpTriggerOf(name string, keys map[string]json.RawMessage) (mcpTrigger, bool) {
	if !isServerEventName(name) {
		return mcpTrigger{}, false
	}
	t := mcpTrigger{event: name, arguments: map[string]json.RawMessage{}}
	for k, v := range keys {
		if k != mcpServerKey {
			t.arguments[k] = v
			continue
		}
		var one string
		var list []json.RawMessage
		switch {
		case json.Unmarshal(v, &one) == nil:
			t.servers = []string{one}
		case json.Unmarshal(v, &list) == nil && len(list) > 0:
			for _, e := range list {
				var s string
				if json.Unmarshal(e, &s) != nil {
					return mcpTrigger{}, false
				}
				t.servers = append(t.servers, s)
			}
		default:
			return mcpTrigger{}, false
		}
		for _, s := range t.servers {
			if !serverNameRule.MatchString(s) {
				return mcpTrigger{}, false
			}
		}
	}
	return t, true
}

// serverTrigger is the trigger as a server's event, when it is one.
func serverTrigger(t wire.WorkflowTrigger) (mcpTrigger, bool) {
	if t.Unrecognised == nil {
		return mcpTrigger{}, false
	}
	return mcpTriggerOf(t.Unrecognised.Name, t.Unrecognised.Keys)
}

func (t mcpTrigger) hears(server string) bool { return t.servers == nil || contains(t.servers, server) }

// subscriptionKey is the subscription it makes on a server: the first 16 hex characters of
// a digest of the server, the event and the arguments. Two triggers with the same three
// share it.
func (t mcpTrigger) subscriptionKey(server string) string {
	sum := sha256.Sum256([]byte(server + "\n" + t.event + "\n" + canonicalJSON(mustRaw(t.arguments))))
	return hex.EncodeToString(sum[:])[:16]
}

func (t mcpTrigger) isWholeNoun() bool { return strings.HasSuffix(t.event, ".*") }

// covers is whether name is its event, or one of its noun's.
func (t mcpTrigger) covers(name string) bool {
	if !t.isWholeNoun() {
		return name == t.event
	}
	return strings.HasPrefix(name, strings.TrimSuffix(t.event, "*")) && isServerEventName(name)
}

func (t mcpTrigger) narrowed(name string) mcpTrigger {
	return mcpTrigger{event: name, servers: t.servers, arguments: t.arguments}
}

// matches is whether a raised event is one of its subscriptions': the same name, from a
// server it hears, carrying that server's key, so an event never runs a workflow that did
// not ask for it.
func (t mcpTrigger) matches(e wire.Event) bool {
	server := e.Details["server"]
	if !t.covers(e.Name) || server == "" || !t.hears(server) {
		return false
	}
	return e.Details["subscription"] == t.narrowed(e.Name).subscriptionKey(server)
}

// summary is "When ci reports checks.failed (repo alexec/Agents)".
func (t mcpTrigger) summary() string {
	who := "a server here"
	if t.servers != nil {
		who = strings.Join(t.servers, " or ")
	}
	keys := make([]string, 0, len(t.arguments))
	for k := range t.arguments {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		parts = append(parts, k+" "+jsonWords(t.arguments[k]))
	}
	s := "When " + who + " reports " + t.event
	if len(parts) > 0 {
		s += " (" + strings.Join(parts, ", ") + ")"
	}
	return s
}

func jsonWords(v json.RawMessage) string {
	var s string
	if json.Unmarshal(v, &s) == nil {
		return s
	}
	return canonicalJSON(v)
}

func mustRaw(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// canonicalJSON is JSON with its keys sorted and no spaces, so equal arguments are equal
// text, as Swift's JSONEncoder writes it with sortedKeys and withoutEscapingSlashes.
func canonicalJSON(v json.RawMessage) string {
	dec := json.NewDecoder(bytes.NewReader(v))
	dec.UseNumber()
	var tree any
	if dec.Decode(&tree) != nil {
		return ""
	}
	var b bytes.Buffer
	writeCanonical(&b, tree)
	return b.String()
}

func writeCanonical(b *bytes.Buffer, v any) {
	switch x := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		b.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			writeCanonical(b, k)
			b.WriteByte(':')
			writeCanonical(b, x[k])
		}
		b.WriteByte('}')
	case []any:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			writeCanonical(b, e)
		}
		b.WriteByte(']')
	case string:
		var s bytes.Buffer
		enc := json.NewEncoder(&s)
		enc.SetEscapeHTML(false)
		enc.Encode(x)
		b.Write(bytes.TrimRight(s.Bytes(), "\n"))
	case json.Number:
		if n, err := x.Int64(); err == nil {
			b.WriteString(strconv.FormatInt(n, 10))
		} else if f, err := x.Float64(); err == nil {
			b.WriteString(strconv.FormatFloat(f, 'g', -1, 64))
		} else {
			b.WriteString(x.String())
		}
	case bool:
		b.WriteString(strconv.FormatBool(x))
	default:
		b.WriteString("null")
	}
}

// jsonSchemaProblem is JSONSchemaSubset.check: what is wrong with value against schema, as
// a sentence, or "" when it fits. Only type, properties, required, enum,
// additionalProperties: false and items; the server checks its own arguments too.
func jsonSchemaProblem(value, schema json.RawMessage, name string) string {
	var v, s any
	if decodeNumbers(value, &v) != nil || decodeNumbers(schema, &s) != nil {
		return ""
	}
	words, isKey, bad := schemaSubsetProblem(v, s, "")
	if !bad {
		return ""
	}
	if m, ok := s.(map[string]any); ok && isKey {
		if props, ok := m["properties"].(map[string]any); ok {
			required := map[string]bool{}
			for _, r := range asList(m["required"]) {
				if t, ok := r.(string); ok {
					required[t] = true
				}
			}
			keys := make([]string, 0, len(props))
			for k := range props {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for i, k := range keys {
				if required[k] {
					keys[i] = k + " (required)"
				}
			}
			takes := "takes no arguments"
			if len(keys) > 0 {
				takes = "takes " + strings.Join(keys, ", ")
			}
			return name + " " + takes + "; " + words + "."
		}
	}
	return name + ": " + words + "."
}

func decodeNumbers(b json.RawMessage, v *any) error {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	return dec.Decode(v)
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

func schemaSubsetProblem(v, schema any, path string) (words string, isKey, bad bool) {
	s, ok := schema.(map[string]any)
	if !ok {
		return "", false, false
	}
	here := ""
	if path != "" {
		here = path + " "
	}
	var types []string
	switch t := s["type"].(type) {
	case string:
		types = []string{t}
	case []any:
		for _, e := range t {
			if x, ok := e.(string); ok {
				types = append(types, x)
			}
		}
	}
	if len(types) > 0 {
		fitsOne := false
		for _, t := range types {
			fitsOne = fitsOne || schemaFits(v, t)
		}
		if !fitsOne {
			var as []string
			for _, t := range types {
				as = append(as, schemaArticle(t))
			}
			return here + "should be " + strings.Join(as, " or "), false, true
		}
	}
	if allowed, ok := s["enum"].([]any); ok {
		found := false
		var each []string
		for _, a := range allowed {
			found = found || schemaEqual(a, v)
			each = append(each, schemaText(a))
		}
		if !found {
			return here + "is one of " + strings.Join(each, ", ") + ", not " + schemaText(v), false, true
		}
	}
	if obj, ok := v.(map[string]any); ok {
		props, _ := s["properties"].(map[string]any)
		for _, r := range asList(s["required"]) {
			if k, ok := r.(string); ok {
				if _, there := obj[k]; !there {
					return k + " is needed", path == "", true
				}
			}
		}
		keys := make([]string, 0, len(obj))
		for k := range obj {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if extra, ok := s["additionalProperties"].(bool); ok && !extra {
			for _, k := range keys {
				if _, known := props[k]; !known {
					return "\"" + k + "\" is not one of its arguments", path == "", true
				}
			}
		}
		for _, k := range keys {
			inner, ok := props[k]
			if !ok {
				continue
			}
			p := k
			if path != "" {
				p = path + "." + k
			}
			if w, key, b := schemaSubsetProblem(obj[k], inner, p); b {
				return w, key, true
			}
		}
	}
	if items, ok := v.([]any); ok {
		if inner, ok := s["items"].(map[string]any); ok {
			base := path
			if base == "" {
				base = "the list"
			}
			for i, item := range items {
				if w, key, b := schemaSubsetProblem(item, inner, base+"["+strconv.Itoa(i)+"]"); b {
					return w, key, true
				}
			}
		}
	}
	return "", false, false
}

func schemaFits(v any, t string) bool {
	switch x := v.(type) {
	case string:
		return t == "string"
	case bool:
		return t == "boolean"
	case map[string]any:
		return t == "object"
	case []any:
		return t == "array"
	case nil:
		return t == "null"
	case json.Number:
		if t == "number" {
			return true
		}
		if t == "integer" {
			if _, err := x.Int64(); err == nil {
				return true
			}
			f, err := x.Float64()
			return err == nil && f == float64(int64(f))
		}
	}
	return false
}

func schemaArticle(t string) string {
	switch t {
	case "integer", "object", "array":
		return "an " + t
	case "null":
		return "null"
	case "string":
		return "text"
	case "boolean":
		return "true or false"
	}
	return "a " + t
}

func schemaEqual(a, b any) bool {
	na, aNum := a.(json.Number)
	nb, bNum := b.(json.Number)
	if aNum && bNum {
		fa, _ := na.Float64()
		fb, _ := nb.Float64()
		return fa == fb
	}
	return canonicalJSON(mustRaw(a)) == canonicalJSON(mustRaw(b))
}

func schemaText(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return canonicalJSON(mustRaw(v))
}
