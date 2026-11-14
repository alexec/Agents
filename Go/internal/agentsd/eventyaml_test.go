package agentsd

import (
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The wake message says an MCP event's payload as YAML, not one line of JSON (#3569).
func TestWakeWordsSayAPayloadAsYAML(t *testing.T) {
	e := wire.Event{Name: "checks.failed", Position: 7, Sentence: "github reported checks.failed",
		Details: map[string]string{
			"event":   "checks.failed",
			"payload": `{"pr":{"number":3573,"title":"YAML"},"failedJobs":[{"name":"go","url":"https://x/1"}],"run":{"id":42132631957,"attempt":1},"ok":false,"note":"a\nb","flag":"true","none":null}`,
		}}
	got := wakeWords(e, 0)
	want := strings.Join([]string{
		"event: checks.failed",
		"payload:",
		"  failedJobs:",
		"    - name: go",
		"      url: https://x/1",
		"  flag: \"true\"",
		"  none: null",
		"  note: |-",
		"    a",
		"    b",
		"  ok: false",
		"  pr:",
		"    number: 3573",
		"    title: YAML",
		"  run:",
		"    attempt: 1",
		"    id: 42132631957",
	}, "\n")
	if !strings.Contains(got, want) {
		t.Fatalf("wake words:\n%s\n\nwant within:\n%s", got, want)
	}
}

// A detail that is not a JSON object or list is said as it came.
func TestDetailWordsLeaveTextAlone(t *testing.T) {
	for _, v := range []string{"cd", "", "{not json", "[1,2] and more", "42"} {
		if got := detailWords("k", v); got != "k: "+v {
			t.Errorf("detailWords(%q) = %q", v, got)
		}
	}
}

// wait_for_event's own answer says the plain details on its line and the payload below it as
// YAML (#3569); an event with no payload reads as before.
func TestMatchedWordsSayAPayloadAsYAML(t *testing.T) {
	e := wire.Event{Name: "checks.passed", Position: 3, Sentence: "github reported checks.passed",
		Details: map[string]string{"event": "checks.passed", "payload": `{"pr":{"number":3811}}`}}
	got := matchedWords(e, nil)
	if !strings.HasSuffix(got, ": github reported checks.passed. event=checks.passed.\npayload:\n  pr:\n    number: 3811\nYou can carry on.") {
		t.Fatalf("matched words: %q", got)
	}
	plain := wire.Event{Name: "server.offline", Sentence: "ci went offline.", Details: map[string]string{"server": "ci"}}
	if got := matchedWords(plain, nil); !strings.HasSuffix(got, ": ci went offline.. server=ci. You can carry on.") {
		t.Fatalf("plain matched words: %q", got)
	}
}

// The wake message puts its details in a yaml code block, so the chat draws them as YAML;
// the event's line and sentence stay above it as text.
func TestWakeWordsFenceTheDetailsAsYAML(t *testing.T) {
	msg := "see ```x```"
	e := wire.Event{Name: "pr.merged", Position: 2, Sentence: "PR 5 merged.",
		Details: map[string]string{"pr": "5"}, Message: &msg}
	got := wakeWords(e, 0)
	want := "\nPR 5 merged.\n\n````yaml\npr: 5\nmessage: see ```x```\n````"
	if !strings.HasPrefix(got, "The event you were waiting for happened.\n\npr.merged at ") || !strings.HasSuffix(got, want) {
		t.Fatalf("wake words:\n%s", got)
	}
	if got := wakeWords(wire.Event{Name: "mac.wake", Sentence: "The Mac woke."}, 0); strings.Contains(got, "```") {
		t.Fatalf("no details, but a block: %q", got)
	}
}
