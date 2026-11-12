package agentsd

import (
	"bytes"
	"encoding/json"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// detailWords is one of an event's details as the wake message says it (#3569): `key: value`,
// and a value that is a JSON object or list (an MCP event's payload) as YAML under its key,
// keys sorted, as a tool card draws it. The chat shows the wake message as the turn's prompt,
// and a payload as one line of JSON was a blob nobody could read.
func detailWords(key, value string) string {
	if block, ok := yamlBlock(value); ok {
		return key + ":\n" + block
	}
	return key + ": " + value
}

// yamlBlock is a JSON object or list as YAML indented two spaces, with no last line break;
// false for anything else, which is said as it came.
func yamlBlock(value string) (string, bool) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || (trimmed[0] != '{' && trimmed[0] != '[') {
		return "", false
	}
	dec := json.NewDecoder(strings.NewReader(trimmed))
	dec.UseNumber() // a run's id stays 42132631957, not 4.2132631957e+10
	var v any
	if dec.Decode(&v) != nil || dec.More() {
		return "", false
	}
	var out bytes.Buffer
	enc := yaml.NewEncoder(&out)
	enc.SetIndent(2)
	if enc.Encode(yamlOf(v)) != nil || enc.Close() != nil {
		return "", false
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	for i, l := range lines {
		lines[i] = "  " + l
	}
	return strings.Join(lines, "\n"), true
}

// yamlOf is a decoded JSON value as a YAML node: keys sorted, numbers as they were written,
// and text tagged as text, so `"true"` or `"12"` is quoted and a text of several lines is a block.
func yamlOf(v any) *yaml.Node {
	switch t := v.(type) {
	case map[string]any:
		n := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			n.Content = append(n.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: k}, yamlOf(t[k]))
		}
		return n
	case []any:
		n := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
		for _, e := range t {
			n.Content = append(n.Content, yamlOf(e))
		}
		return n
	case json.Number:
		if strings.ContainsAny(t.String(), ".eE") {
			return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!float", Value: t.String()}
		}
		return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!int", Value: t.String()}
	case bool:
		if t {
			return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"}
		}
		return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "false"}
	case string:
		n := &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: t}
		if strings.Contains(t, "\n") {
			n.Style = yaml.LiteralStyle
		}
		return n
	default:
		return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!null", Value: "null"}
	}
}

// yamlFence is lines in a Markdown code block marked yaml. Its fence is longer than any run
// of backticks in lines, so a detail or message with ``` in it cannot end the block early.
func yamlFence(lines []string) string {
	body := strings.Join(lines, "\n")
	fence := "```"
	for strings.Contains(body, fence) {
		fence += "`"
	}
	return fence + "yaml\n" + body + "\n" + fence
}
