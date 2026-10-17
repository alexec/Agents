package agentsd

import (
	"encoding/json"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Which server's tool an agent called, and what it answered, read from the runtime's ACP
// tool call by its shape (ACPToolShape, #191). No runtime passes a tool's _meta on, so the
// app reads the call by how it looks, never by runtime name:
//
//	rawInput.server + rawInput.tool      exactly     rawOutput.result, whole
//	mcp__<s>__<t> (or mcp.<s>.<t>)       exactly     rawOutput, a JSON string of structuredContent
//	a title <s>-<t> or <s>_<t>           the longest server name that prefixes it
//	                                                 rawOutput.structuredContent + contents
//
// A name is only ever resolved against the servers the caller names, and the caller checks
// the tool against that server's own catalog.

// shapeCandidate is one reading of a call: which server and tool, with what.
type shapeCandidate struct {
	server, tool string
	arguments    json.RawMessage
	// exact: the runtime named the server and tool outright, so the call can be shown as it
	// starts. A joined title is only trusted once its result is in.
	exact bool
}

// shapeResult is what a call answered, as a CallToolResult; drawable when it came with
// structuredContent, or whole. A text-only result is not drawn inline (Q7).
type shapeResult struct {
	value    json.RawMessage
	drawable bool
}

func objectOf(raw json.RawMessage) map[string]json.RawMessage {
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return nil
	}
	return m
}

func stringOf(raw json.RawMessage) (string, bool) {
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return "", false
	}
	return s, true
}

func isNull(raw json.RawMessage) bool {
	t := strings.TrimSpace(string(raw))
	return t == "" || t == "null"
}

// shapeCandidates is every reading of call against servers, best first.
func shapeCandidates(call wire.ToolCall, servers []string) []shapeCandidate {
	known := map[string]bool{}
	for _, s := range servers {
		known[s] = true
	}
	input := objectOf(call.RawInput)
	server, okServer := stringOf(input["server"])
	tool, okTool := stringOf(input["tool"])
	if okServer && okTool {
		if !known[server] {
			return nil
		}
		return []shapeCandidate{{server: server, tool: tool, arguments: nonNull(input["arguments"]), exact: true}}
	}
	byLength := append([]string(nil), servers...)
	sort.Slice(byLength, func(i, j int) bool {
		if len(byLength[i]) != len(byLength[j]) {
			return len(byLength[i]) > len(byLength[j])
		}
		return byLength[i] < byLength[j]
	})
	args := nonNull(call.RawInput)
	var found []shapeCandidate
	names := []string{}
	if call.Name != nil {
		names = append(names, *call.Name)
	}
	names = append(names, call.Title)
	for _, name := range names {
		for _, p := range [][2]string{{"mcp__", "__"}, {"mcp.", "."}} {
			rest, ok := strings.CutPrefix(name, p[0])
			if !ok {
				continue
			}
			for _, s := range byLength {
				if t, ok := strings.CutPrefix(rest, s+p[1]); ok && t != "" {
					found = append(found, shapeCandidate{server: s, tool: t, arguments: args, exact: true})
				}
			}
		}
	}
	if len(found) > 0 {
		return uniqueCandidates(found)
	}
	for _, s := range byLength {
		for _, sep := range []string{"-", "_"} {
			if t, ok := strings.CutPrefix(call.Title, s+sep); ok && t != "" {
				found = append(found, shapeCandidate{server: s, tool: t, arguments: args})
			}
		}
	}
	return uniqueCandidates(found)
}

func nonNull(raw json.RawMessage) json.RawMessage {
	if isNull(raw) {
		return nil
	}
	return raw
}

func uniqueCandidates(list []shapeCandidate) []shapeCandidate {
	seen := map[string]bool{}
	var out []shapeCandidate
	for _, c := range list {
		k := c.server + "\x00" + c.tool
		if !seen[k] {
			seen[k] = true
			out = append(out, c)
		}
	}
	return out
}

func textResult(text string, isError bool) json.RawMessage {
	m := map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}}
	if isError {
		m["isError"] = true
	}
	b, _ := json.Marshal(m)
	return b
}

// shapeResultOf is the result of a finished call, from whichever shape the runtime gave it
// in; false while the call runs, or when it gave nothing usable.
func shapeResultOf(call wire.ToolCall) (shapeResult, bool) {
	status := ""
	if call.Status != nil {
		status = *call.Status
	}
	if status != "completed" && status != "failed" {
		return shapeResult{}, false
	}
	failed := status == "failed"
	if isNull(call.RawOutput) {
		if failed {
			return shapeResult{value: textResult(printedText(call), true)}, true
		}
		return shapeResult{}, false
	}
	out := objectOf(call.RawOutput)
	if whole := out["result"]; objectOf(whole) != nil {
		return shapeResult{value: whole, drawable: true}, true
	}
	if r, ok := out["result"]; ok && isNull(r) && !isNull(out["error"]) {
		msg, ok := stringOf(out["error"])
		if !ok {
			msg, _ = stringOf(objectOf(out["error"])["message"])
		}
		return shapeResult{value: textResult(msg, true)}, true
	}
	if text, ok := stringOf(call.RawOutput); ok {
		var parsed map[string]json.RawMessage
		if json.Unmarshal([]byte(text), &parsed) == nil && parsed != nil {
			b, _ := json.Marshal(map[string]any{"content": []any{}, "structuredContent": json.RawMessage(text)})
			return shapeResult{value: b, drawable: true}, true
		}
		return shapeResult{value: textResult(text, failed)}, true
	}
	if structured := out["structuredContent"]; objectOf(structured) != nil {
		blocks := json.RawMessage("[]")
		for _, k := range []string{"contents", "content"} {
			if b := out[k]; len(b) > 0 && b[0] == '[' {
				blocks = b
				break
			}
		}
		b, _ := json.Marshal(map[string]any{"content": blocks, "structuredContent": structured})
		return shapeResult{value: b, drawable: true}, true
	}
	if blocks := out["content"]; len(blocks) > 0 && blocks[0] == '[' {
		b, _ := json.Marshal(map[string]any{"content": blocks})
		return shapeResult{value: b}, true
	}
	if text, ok := stringOf(out["output"]); ok {
		return shapeResult{value: textResult(text, failed)}, true
	}
	if failed {
		return shapeResult{value: textResult(printedText(call), true)}, true
	}
	return shapeResult{}, false
}
