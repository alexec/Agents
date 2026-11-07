package agentsd

import (
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
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
