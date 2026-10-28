package acp

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"

	sdk "github.com/coder/acp-go-sdk"
)

func TestAdvertisedSystemPromptIsAddedToSessionLifecycleRequests(t *testing.T) {
	c := &client{}
	response := `{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"sessionCapabilities":{"systemPrompt":{}}}}}` + "\n"
	_, err := io.ReadAll(&rawElicitations{r: bufio.NewReader(strings.NewReader(response)), c: c})
	if err != nil || !c.supportsSystemPrompt {
		t.Fatalf("capability was not retained: %v %v", c.supportsSystemPrompt, err)
	}
	c.systemPrompt = "brief"
	var output bytes.Buffer
	w := &sessionPromptWriter{w: &output, c: c}
	for _, method := range []string{"session/new", "session/load", "session/resume", "session/fork"} {
		output.Reset()
		request := `{"jsonrpc":"2.0","id":2,"method":"` + method + `","params":{"cwd":"/tmp","mcpServers":[]}}` + "\n"
		if _, err := w.Write([]byte(request)); err != nil {
			t.Fatal(err)
		}
		var got struct {
			Params struct {
				SystemPrompt struct {
					Mode    string `json:"mode"`
					Content []struct {
						Type string `json:"type"`
						Text string `json:"text"`
					} `json:"content"`
				} `json:"systemPrompt"`
			} `json:"params"`
		}
		if err := json.Unmarshal(output.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if got.Params.SystemPrompt.Mode != "append" || len(got.Params.SystemPrompt.Content) != 1 || got.Params.SystemPrompt.Content[0].Text != "brief" {
			t.Fatalf("%s: unexpected systemPrompt: %s", method, output.String())
		}
	}
}

func TestUnadvertisedSystemPromptIsNotSent(t *testing.T) {
	c := &client{systemPrompt: "brief"}
	var output bytes.Buffer
	w := &sessionPromptWriter{w: &output, c: c}
	request := `{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}` + "\n"
	if _, err := w.Write([]byte(request)); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(output.Bytes(), []byte(`"systemPrompt"`)) {
		t.Fatalf("unadvertised field sent: %s", output.String())
	}
}

// The runtime's own params reach the daemon, propertyOrder and all, though the SDK's typed
// request has no place for it; what the SDK reads is unchanged.
func TestTheRuntimesOwnElicitationParamsAreKept(t *testing.T) {
	c := &client{}
	in := `{"jsonrpc":"2.0","id":7,"method":"elicitation/create","params":{"mode":"form","message":"M","requestedSchema":{"propertyOrder":["b","a"],"properties":{}}}}` + "\n" +
		`{"jsonrpc":"2.0","method":"session/update","params":{}}` + "\n"
	out, err := io.ReadAll(&rawElicitations{r: bufio.NewReader(strings.NewReader(in)), c: c})
	if err != nil || string(out) != in {
		t.Fatalf("what the SDK read changed: %q %v", out, err)
	}
	if len(c.raw) != 1 || !strings.Contains(string(c.raw[0]), "propertyOrder") {
		t.Fatalf("%q", c.raw)
	}
	m := "M"
	got := c.takeRaw(sdk.UnstableCreateElicitationRequest{Form: &sdk.UnstableCreateElicitationForm{Message: m}})
	if !strings.Contains(string(got), `"propertyOrder":["b","a"]`) || len(c.raw) != 0 {
		t.Fatalf("%s", got)
	}
	// None kept: the typed request itself.
	if got := c.takeRaw(sdk.UnstableCreateElicitationRequest{Form: &sdk.UnstableCreateElicitationForm{Message: "other"}}); !strings.Contains(string(got), `"other"`) {
		t.Fatalf("%s", got)
	}
}

// Chunks, tool results and replayed lines carry no marker, so neither direction decodes
// them: a decode allocates, and these must not (#2733).
func TestLinesWithoutAMarkerAreNotDecoded(t *testing.T) {
	c := &client{systemPrompt: "brief"}
	e := &rawElicitations{c: c}
	initialize := []byte(`{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"sessionCapabilities":{"systemPrompt":{}}}}}` + "\n")
	e.keep(initialize)
	if !e.handshook || !c.supportsSystemPrompt {
		t.Fatalf("handshake not read: %v %v", e.handshook, c.supportsSystemPrompt)
	}
	chunk := []byte(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}` + "\n")
	if allocs := testing.AllocsPerRun(100, func() { e.keep(chunk) }); allocs != 0 {
		t.Fatalf("an incoming line without a marker was decoded: %v allocations", allocs)
	}
	// After the handshake, a later line that names agentCapabilities is not decoded either.
	late := []byte(`{"jsonrpc":"2.0","method":"session/update","params":{"text":"\"agentCapabilities\""}}` + "\n")
	if allocs := testing.AllocsPerRun(100, func() { e.keep(late) }); allocs != 0 {
		t.Fatalf("a line after the handshake was decoded: %v allocations", allocs)
	}
	w := &sessionPromptWriter{w: io.Discard, c: c}
	prompt := []byte(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"s","prompt":[{"type":"text","text":"hi"}]}}` + "\n")
	w.buf = make([]byte, 0, 4*len(prompt))
	if allocs := testing.AllocsPerRun(100, func() {
		if _, err := w.Write(prompt); err != nil {
			t.Fatal(err)
		}
	}); allocs != 0 {
		t.Fatalf("an outgoing line without a lifecycle method was decoded: %v allocations", allocs)
	}
}

// The systemPrompt capability is still read among other lines, and still added to a
// lifecycle request that arrives in pieces.
func TestCapabilityIsReadAmongOtherLines(t *testing.T) {
	c := &client{}
	in := `{"jsonrpc":"2.0","method":"session/update","params":{}}` + "\n" +
		`{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"sessionCapabilities":{"systemPrompt":{}}}}}` + "\n"
	if _, err := io.ReadAll(&rawElicitations{r: bufio.NewReader(strings.NewReader(in)), c: c}); err != nil || !c.supportsSystemPrompt {
		t.Fatalf("capability was not retained: %v %v", c.supportsSystemPrompt, err)
	}
	c.systemPrompt = "brief"
	var output bytes.Buffer
	w := &sessionPromptWriter{w: &output, c: c}
	request := `{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}` + "\n"
	for _, part := range []string{request[:10], request[10:], request} {
		if _, err := w.Write([]byte(part)); err != nil {
			t.Fatal(err)
		}
	}
	if got := bytes.Count(output.Bytes(), []byte(`"systemPrompt"`)); got != 2 {
		t.Fatalf("systemPrompt in %d of 2 lines: %s", got, output.String())
	}
}

// BenchmarkReadTranscript replays a 20 MB transcript of chunks through the reader the SDK
// reads, after the handshake.
func BenchmarkReadTranscript(b *testing.B) {
	chunk := `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"` + strings.Repeat("x", 400) + `"}}}}` + "\n"
	initialize := `{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"sessionCapabilities":{"systemPrompt":{}}}}}` + "\n"
	transcript := initialize + strings.Repeat(chunk, 20<<20/len(chunk))
	buf := make([]byte, 32<<10)
	b.SetBytes(int64(len(transcript)))
	b.ReportAllocs()
	for b.Loop() {
		e := &rawElicitations{r: bufio.NewReader(strings.NewReader(transcript)), c: &client{}}
		for {
			if _, err := e.Read(buf); err != nil {
				break
			}
		}
	}
}
