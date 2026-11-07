package bitbucketmcp

import (
	"fmt"
	"strings"
	"testing"
)

// failed_log (#3787) over the fake Bitbucket: the failed steps of a Pipelines run, each log's
// end in plain text, read with a Range from the file store the log redirects to.

func logText(t *testing.T, c *client, args map[string]any) (string, bool) {
	t.Helper()
	reply := c.call("tools/call", map[string]any{"name": "failed_log", "arguments": args})
	result := reply["result"].(map[string]any)
	return result["content"].([]any)[0].(map[string]any)["text"].(string), result["isError"] != true
}

func TestAFailedLogIsItsFailedStepsEndInPlainText(t *testing.T) {
	f := newFake(t)
	f.steps[12] = []obj{step("{s1}", "Lint", "SUCCESSFUL"), step("{s2}", "Test", "FAILED"), step("{s3}", "", "ERROR"),
		step("{s4}", "Deploy", "")}
	f.logs["{s1}"] = "all good\n"
	f.logs["{s2}"] = "\x1b[32m+ go test ./...\x1b[0m\r\nline one\nFAIL: mean\n\n\n"
	f.logs["{s3}"] = ""
	c := serve(t, f, false)

	text, ok := logText(t, c, map[string]any{"pipelineId": 12})
	if !ok || !strings.Contains(text, "== Test (https://bitbucket.org/acme/app/pipelines/results/12/steps/{s2}), last 300 lines ==\n"+
		"+ go test ./...\nline one\nFAIL: mean\n\n== step 3 (") || strings.Contains(text, "\x1b") ||
		strings.Contains(text, "Lint") || strings.Contains(text, "Deploy") {
		t.Fatalf("log %q", text)
	}
	f.mu.Lock()
	same(t, f.ranges, []string{fmt.Sprintf("bytes=-%d", logBytes), fmt.Sprintf("bytes=-%d", logBytes)})
	f.mu.Unlock()

	one, _ := logText(t, c, map[string]any{"pipelineId": 12, "step": "Test"})
	if !strings.Contains(one, "== Test") || strings.Contains(one, "step 3") {
		t.Fatalf("one step %q", one)
	}
	none, ok := logText(t, c, map[string]any{"pipelineId": 12, "step": "Lint"})
	if !ok || none != "No failed steps in pipeline 12." {
		t.Fatalf("a step that passed %q", none)
	}
	if text, ok := logText(t, c, map[string]any{"pipelineId": 13}); !ok || text != "No failed steps in pipeline 13." {
		t.Fatalf("a run with no steps %q", text)
	}
	if _, ok := logText(t, c, map[string]any{}); ok {
		t.Fatal("no pipelineId worked")
	}
	if _, ok := logText(t, c, map[string]any{"pipelineId": 12, "repo": "not a repo"}); ok {
		t.Fatal("a repo that is none worked")
	}
}

// A log longer than the Range: the first line is the end of one the Range cut, so it is
// dropped, and only the last logLines are given.
func TestAFailedLogKeepsOnlyTheEndOfALongLog(t *testing.T) {
	f := newFake(t)
	f.steps[7] = []obj{step("{s1}", "Build", "FAILED")}
	var b strings.Builder
	for i := 0; b.Len() < logBytes+(1<<20); i++ {
		fmt.Fprintf(&b, "\x1b[32mline %d of the build, with some words to make it long\x1b[0m\n", i)
	}
	b.WriteString("FAIL: mean\n")
	f.logs["{s1}"] = b.String()
	c := serve(t, f, false)
	text, _ := logText(t, c, map[string]any{"pipelineId": 7})
	lines := strings.Split(text[strings.Index(text, "==\n")+3:], "\n")
	if len(lines) != logLines || lines[len(lines)-1] != "FAIL: mean" || !strings.HasPrefix(lines[0], "line ") {
		t.Fatalf("%d lines, the last %q, the first %q", len(lines), lines[len(lines)-1], lines[0])
	}

	end, err := logTail(strings.NewReader("of a line\nwhole\nlast"), logLines, true)
	if err != nil || end != "whole\nlast" {
		t.Fatalf("a cut log %q (%v)", end, err)
	}
}

func TestAFailedLogSaysWhatBitbucketRefused(t *testing.T) {
	f := newFake(t)
	f.steps[7] = []obj{step("{gone}", "Build", "FAILED")}
	c := serve(t, f, false)
	if text, ok := logText(t, c, map[string]any{"pipelineId": 7}); !ok || !strings.HasSuffix(text, "==\n(no log)") {
		t.Fatalf("a step with no log %q", text)
	}
	f.set(func() { f.status = 403 })
	if text, ok := logText(t, c, map[string]any{"pipelineId": 7}); ok || !strings.Contains(text, "HTTP 403") {
		t.Fatalf("a refused read %q", text)
	}
}
