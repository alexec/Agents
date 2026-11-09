package mcpevents

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var testSchema = Schema{
	{Name: "repo", Kind: "string", Pattern: regexp.MustCompile(`^[a-z]+/[a-z]+$`), LooksLike: "owner/name"},
	{Name: "pr", Kind: "integer"},
	{Name: "issue", Kind: "integers"},
	{Name: "fixes", Kind: "refs", Pattern: regexp.MustCompile(`^#[0-9]+$`), LooksLike: `issues, as "#12"`},
	{Name: "item", Kind: "ids", Pattern: regexp.MustCompile(`^[1-9][0-9]*$`), LooksLike: "an id, as 12"},
	{Name: "anyone", Kind: "boolean"},
}

func TestCheckReadsEachKind(t *testing.T) {
	v, bad := testSchema.Check(json.RawMessage(`{"repo":"a/b","pr":3,"issue":[4,5],"fixes":[" #6 "],"anyone":true}`))
	if bad != nil {
		t.Fatal(bad)
	}
	if v.String("repo") != "a/b" || v.Int("pr") != 3 || len(v.Ints("issue")) != 2 || v.Strings("fixes")[0] != "#6" || !v.Bool("anyone") {
		t.Fatalf("values %v", v)
	}
	if v, _ := testSchema.Check(json.RawMessage(`{"issue":7}`)); len(v.Ints("issue")) != 1 || v.Ints("issue")[0] != 7 {
		t.Fatalf("one integer is a list of one: %v", v)
	}
	if v, _ := testSchema.Check(json.RawMessage(`{"item":"7"}`)); len(v.Strings("item")) != 1 {
		t.Fatalf("one id is a list of one: %v", v)
	}
	if v, _ := testSchema.Check(json.RawMessage(`{"item":["7","8"]}`)); len(v.Strings("item")) != 2 {
		t.Fatalf("ids: %v", v)
	}
	if v, bad := testSchema.Check(nil); bad != nil || len(v) != 0 {
		t.Fatalf("no arguments: %v %v", v, bad)
	}
}

func TestCheckRefusesInOrder(t *testing.T) {
	for raw, want := range map[string]string{
		`[]`:                  "arguments must be an object",
		`{"zz":1,"repo":"x"}`: "repo must look like owner/name",
		`{"zz":1}`:            "unknown argument zz; takes repo, pr, issue, fixes, item, anyone",
		`{"pr":"3"}`:          "pr must be a positive integer",
		`{"pr":0}`:            "pr must be a positive integer",
		`{"issue":[]}`:        "issue must be a positive integer or a list of them",
		`{"fixes":["12"]}`:    `fixes must be a list of issues, as "#12", not "12"`,
		`{"fixes":"#12"}`:     `fixes must be a list of issues, as "#12"`,
		`{"anyone":null}`:     "anyone must be true or false",
		`{"repo":7}`:          "repo must be a string",
		`{"item":"x"}`:        "item must be an id, as 12, or a list of them",
		`{"item":[]}`:         "item must be an id, as 12, or a list of them",
	} {
		_, bad := testSchema.Check(json.RawMessage(raw))
		if bad == nil || bad.Code != -32602 || bad.Message != want {
			t.Errorf("%s: %v, want %q", raw, bad, want)
		}
	}
}

func TestListDeclaresEachEvent(t *testing.T) {
	type own struct {
		Event
		extra int
	}
	events := []own{{Event: Event{Name: "a.b", Input: testSchema}, extra: 1}, {Event: Event{Name: "c.d"}}}
	if e, ok := Named(events, "c.d"); !ok || e.Name != "c.d" {
		t.Fatal("Named")
	}
	if _, ok := Named(events, "x"); ok {
		t.Fatal("Named found none")
	}
	if strings.Join(Names(events), ",") != "a.b,c.d" {
		t.Fatal(Names(events))
	}
	first := List(events)["events"].([]any)[0].(map[string]any)
	if first["name"] != "a.b" || first["delivery"].([]string)[0] != "poll" ||
		first["inputSchema"].(map[string]any)["properties"].(map[string]any)["fixes"].(map[string]any)["items"].(map[string]any)["pattern"] != `^#[0-9]+$` {
		t.Fatalf("list %v", first)
	}
	if NoEvent("x", Names(events)).Message != "no event x; this server offers a.b, c.d" {
		t.Fatal("NoEvent")
	}
}

// MARK: Polling

func cursorOf(t *testing.T, result map[string]any) json.RawMessage {
	t.Helper()
	raw, _ := json.Marshal(result["cursor"])
	return raw
}

func ids(result map[string]any) []string {
	var out []string
	for _, e := range result["events"].([]any) {
		out = append(out, e.(map[string]any)["eventId"].(string))
	}
	return out
}

func TestPollGoesOnFromItsCursor(t *testing.T) {
	pl := Poller{NextPollMs: 30000}
	found := []Candidate{}
	listed := Listed{}
	find := func(string) ([]Candidate, Listed, error) { return found, listed, nil }
	start := func() string { return "2026-01-01T00:00:00Z" }
	first, bad := pl.Poll("e", Params{}, start, find)
	if bad != nil || len(ids(first)) != 0 || first["nextPollMs"] != 30000 {
		t.Fatalf("first poll %v %v", first, bad)
	}
	found = []Candidate{
		{EventID: "b", Time: "2026-01-01T00:00:02Z", Data: Data(map[string]any{"n": 2})},
		{EventID: "a", Time: "2026-01-01T00:00:02Z", Data: Data(map[string]any{"n": 1})},
		{EventID: "old", Time: "2025-12-31T00:00:00Z", Data: Data(map[string]any{})},
		{EventID: "c", Time: "2026-01-01T00:00:03Z", Data: Data(map[string]any{"n": 3})},
	}
	one := 1
	second, _ := pl.Poll("e", Params{Cursor: cursorOf(t, first), MaxEvents: &one}, start, find)
	if strings.Join(ids(second), ",") != "a" || second["hasMore"] != true {
		t.Fatalf("second poll %v", second)
	}
	third, _ := pl.Poll("e", Params{Cursor: cursorOf(t, second)}, start, find)
	if strings.Join(ids(third), ",") != "b,c" || third["hasMore"] != false {
		t.Fatalf("third poll %v", third)
	}
	if again, _ := pl.Poll("e", Params{Cursor: cursorOf(t, third)}, start, find); len(ids(again)) != 0 {
		t.Fatalf("raised twice %v", again)
	}
}

func TestPollGoesOnToTheNewestTheListingSaw(t *testing.T) {
	var c Cursor
	pl := Poller{}
	first, _ := pl.Poll("e", Params{}, func() string { return "2026-01-01T00:00:00Z" }, nil)
	poll, _ := pl.Poll("e", Params{Cursor: cursorOf(t, first)}, nil, func(string) ([]Candidate, Listed, error) {
		return []Candidate{{EventID: "x", Time: "2026-01-02T00:00:00Z", Data: Data(nil)}}, Listed{Newest: "2026-01-03T00:00:00Z"}, nil
	})
	if len(ids(poll)) != 0 {
		t.Fatalf("nil data is skipped: %v", poll)
	}
	DecodeCursor(cursorOf(t, poll), &c)
	if c.Since != "2026-01-03T00:00:00Z" {
		t.Fatalf("since %s", c.Since)
	}
	truncated, _ := pl.Poll("e", Params{Cursor: cursorOf(t, first)}, nil, func(string) ([]Candidate, Listed, error) {
		return nil, Listed{Truncated: true, Newest: "2026-01-03T00:00:00Z"}, nil
	})
	DecodeCursor(cursorOf(t, truncated), &c)
	if c.Since != "2026-01-01T00:00:00Z" || truncated["truncated"] != true {
		t.Fatalf("a truncated listing keeps its place: %v", truncated)
	}
}

func TestPollRefusesAndFails(t *testing.T) {
	pl := Poller{Normalize: func(s string) string {
		if _, err := time.Parse(time.RFC3339, s); err != nil {
			return ""
		}
		return s
	}, Fail: func(err error) *Error { return &Error{Code: -32013, Message: err.Error()} }}
	if _, bad := pl.Poll("e", Params{Cursor: json.RawMessage(`"bad"`)}, nil, nil); bad == nil || bad.Message != "cursor is not one this server gave" {
		t.Fatal(bad)
	}
	notATime := json.RawMessage(`"` + Cursor{Since: "soon"}.Encoded() + `"`)
	if _, bad := pl.Poll("e", Params{Cursor: notATime}, nil, nil); bad == nil || bad.Code != -32602 {
		t.Fatal(bad)
	}
	good := json.RawMessage(`"` + Cursor{Since: "2026-01-01T00:00:00Z"}.Encoded() + `"`)
	_, bad := pl.Poll("e", Params{Cursor: good}, nil, func(string) ([]Candidate, Listed, error) { return nil, Listed{}, errors.New("slow") })
	if bad == nil || bad.Code != -32013 {
		t.Fatal(bad)
	}
}

func TestParamsLimit(t *testing.T) {
	for given, want := range map[int]int{0: 1, 7: 7, 500: MaxEvents} {
		if got := (Params{MaxEvents: &given}).Limit(); got != want {
			t.Errorf("%d: %d", given, got)
		}
	}
	if (Params{}).Limit() != 50 {
		t.Error("default")
	}
	if _, bad := ParseParams(json.RawMessage(`[]`)); bad == nil {
		t.Error("params must be an object")
	}
}

func TestDiffRaisesWhatTurnedOn(t *testing.T) {
	pl := Poller{}
	on, off := true, false
	states := []State{{ID: "s:1", Number: 1, On: &on}, {ID: "s:2", Number: 2, On: &off}}
	now := func() string { return "T" }
	list := func() ([]State, error) { return states, nil }
	first, _ := pl.Diff("e", "onAt", Params{}, now, list)
	if len(ids(first)) != 0 {
		t.Fatalf("the first poll takes what is on as known: %v", first)
	}
	states = []State{{ID: "s:1", Number: 1}, {ID: "s:3", Number: 3, On: &on, Data: map[string]any{"pr": 3}}, {ID: "s:2", Number: 2, On: &on}}
	second, _ := pl.Diff("e", "onAt", Params{Cursor: cursorOf(t, first)}, now, list)
	if strings.Join(ids(second), ",") != "s:2:T,s:3:T" {
		t.Fatalf("second %v", second)
	}
	data := second["events"].([]any)[1].(map[string]any)["data"].(map[string]any)
	if data["pr"] != 3 || data["onAt"] != "T" {
		t.Fatalf("data %v", data)
	}
	if again, _ := pl.Diff("e", "onAt", Params{Cursor: cursorOf(t, second)}, now, list); len(ids(again)) != 0 {
		t.Fatalf("still on is not new: %v", again)
	}
}

// MARK: The front

type source struct{}

func (source) Poll(_ context.Context, raw json.RawMessage) (map[string]any, *Error) {
	if strings.Contains(string(raw), "bad") {
		return nil, InvalidParams("bad")
	}
	return map[string]any{"events": []any{}}, nil
}

func TestFrontAnswersEventsAndAddsThemToInitialize(t *testing.T) {
	front := &Front{Events: source{}, List: func() map[string]any { return map[string]any{"events": []any{}} },
		Upstream: mcp.NewServer(&mcp.Implementation{Name: "up", Version: "0"}, nil),
		Name:     "test-mcp", Title: "Test", Version: "1.2", Instructions: "Words."}
	in := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}`,
		`{"jsonrpc":"2.0","method":"events/poll","params":{}}`,
		`{"jsonrpc":"2.0","id":2,"method":"events/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"events/poll","params":{"name":"bad"}}`,
	}, "\n") + "\n"
	inR, inW := io.Pipe()
	pr, pw := io.Pipe()
	done := make(chan error, 1)
	go func() { done <- front.Serve(context.Background(), inR, pw); _ = pw.Close() }()
	go func() { _, _ = io.WriteString(inW, in) }()
	answers := map[string]map[string]any{}
	r := bufio.NewReader(pr)
	for len(answers) < 3 {
		line, err := ReadLine(r)
		if err != nil {
			t.Fatalf("after %v: %v", answers, err)
		}
		var m map[string]any
		_ = json.Unmarshal(line, &m)
		id, _ := json.Marshal(m["id"])
		answers[string(id)] = m
	}
	_ = inW.Close()
	go func() { _, _ = io.Copy(io.Discard, pr) }()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	result := answers["1"]["result"].(map[string]any)
	info := result["serverInfo"].(map[string]any)
	if result["instructions"] != "Words." || info["name"] != "test-mcp" || info["version"] != "1.2" ||
		result["capabilities"].(map[string]any)["events"] == nil {
		t.Fatalf("initialize %v", result)
	}
	if answers["2"]["result"] == nil || answers["3"]["error"].(map[string]any)["code"] != float64(-32602) {
		t.Fatalf("events %v", answers)
	}
}

// MARK: Logs

func TestLogTail(t *testing.T) {
	upper := func(s string) string { return strings.ToUpper(s) }
	tail, err := LogTail(strings.NewReader("cut\na\r\nb\nc\n \n\n"), 2, true, upper)
	if err != nil || tail != "B\nC" {
		t.Fatalf("%q %v", tail, err)
	}
	long := strings.Repeat("x", 3*maxLogLine) + "\nend"
	if tail, _ := LogTail(strings.NewReader(long), 5, false, upper); len(tail) != maxLogLine+len("\nEND") {
		t.Fatalf("a line is kept to its start: %d", len(tail))
	}
	if _, err := LogTail(iotest{}, 5, false, upper); err == nil {
		t.Fatal("a read error is said")
	}
}

type iotest struct{}

func (iotest) Read([]byte) (int, error) { return 0, errors.New("reset") }
