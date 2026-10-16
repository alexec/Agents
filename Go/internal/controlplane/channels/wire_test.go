package channels

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// Shapes as Swift's JSONEncoder writes them, and secrets.env as SecretsEnv reads and
// writes it (SecretsEnvTests).

func TestStateIsWrittenAsSwiftWritesIt(t *testing.T) {
	got, _ := json.Marshal(Unavailable())
	want := `{"slack":{"enabled":false,"memberID":"","appTokenSet":false,"botTokenSet":false,"status":"off","detail":"Channels need a control plane with one copy, for now.","available":false}}`
	if string(got) != want {
		t.Fatalf("%s", got)
	}
	got, _ = json.Marshal(ChannelsState{Slack: SlackState{Status: StatusConnected, Available: true}})
	if strings.Contains(string(got), "detail") {
		t.Fatalf("nil detail written: %s", got)
	}
	var set ChannelsSet
	if err := json.Unmarshal([]byte(`{"slack":{"enabled":true,"botToken":""}}`), &set); err != nil {
		t.Fatal(err)
	}
	if !*set.Slack.Enabled || *set.Slack.BotToken != "" || set.Slack.AppToken != nil || set.Slack.MemberID != nil {
		t.Fatalf("%+v", set.Slack)
	}
}

func TestAPendingQuestionFromSwiftDecodes(t *testing.T) {
	// elicitations/pending as a Swift host answers it.
	raw := `[{"id":"6F1A2B3C-0000-4000-8000-000000000001","agentID":"6F1A2B3C-0000-4000-8000-000000000002",
	"message":"Tea or coffee?","scope":"request","askedAt":782000000.5,
	"mode":{"form":{"_0":{"properties":[
		{"name":"drink","title":"Tea or coffee?","isRequired":true,
		 "kind":{"string":{"choices":[{"value":"tea","title":"Tea"},{"value":"coffee","title":"Coffee","description":"Black"}]}}},
		{"name":"drink_custom","isRequired":false,"kind":{"string":{}}}]}}}}]`
	var requests []ElicitationRequest
	if err := json.Unmarshal([]byte(raw), &requests); err != nil {
		t.Fatal(err)
	}
	r := requests[0]
	if r.Mode.Form == nil || len(r.Mode.Form.Pages()) != 1 || r.Mode.Form.Properties[1].Kind.Type != KindString {
		t.Fatalf("%+v", r.Mode.Form)
	}
	if s := r.AskedAt.Seconds(); s != 782000000.5 {
		t.Fatalf("askedAt %v", s)
	}
	again, _ := json.Marshal(r)
	var back ElicitationRequest
	if err := json.Unmarshal(again, &back); err != nil || !reflect.DeepEqual(back.Mode, r.Mode) {
		t.Fatalf("round trip %s %v", again, err)
	}
	if !strings.Contains(string(again), `"kind":{"string":{"choices":[`) || !strings.Contains(string(again), `"kind":{"string":{}}`) {
		t.Fatalf("kind %s", again)
	}
	url := `{"id":"A","agentID":"B","mode":{"url":{"_0":"https://x"}},"scope":"session","askedAt":0}`
	var page ElicitationRequest
	if err := json.Unmarshal([]byte(url), &page); err != nil || *page.Mode.URL != "https://x" ||
		page.Title() != "The agent wants you to open a page" {
		t.Fatalf("%+v %v", page, err)
	}
}

func TestAttentionNeedsFromSwiftDecodeAndKeyAsSwiftDoes(t *testing.T) {
	raw := `{"need":{"id":{"elicitation":"6F1A2B3C-0000-4000-8000-00000000000A"},"agentID":"6F1A2B3C-0000-4000-8000-000000000002",
	"folder":"file:///work/","kind":"elicitation","raisedAt":782000000,"headline":{"h1":"work","h2":"Fix","h3":"Asks"}},
	"headline":{"h1":"work","h2":"Fix","h3":"Asks"},"buzz":true}`
	var need AttentionNeed
	if err := json.Unmarshal([]byte(raw), &need); err != nil {
		t.Fatal(err)
	}
	if k := Key("h1", need.Need.ID); k != "h1|elicitation:6F1A2B3C-0000-4000-8000-00000000000A" {
		t.Fatalf("key %s", k)
	}
	var withdraw AttentionNeed
	if err := json.Unmarshal([]byte(`{"withdraw":{"guardedChange":{"folder":"file:///work/","path":".agents/project.json"}}}`), &withdraw); err != nil {
		t.Fatal(err)
	}
	if tok := withdraw.Withdraw.Token(); tok != "guarded:/work:.agents/project.json" {
		t.Fatalf("token %s", tok)
	}
	report := NeedID{Report: &NeedReport{AgentID: "a", At: RefDate(time.Unix(referenceDate+5, 0))}}
	if tok := report.Token(); tok != "report:A:5.0" {
		t.Fatalf("token %s", tok)
	}
	out, _ := json.Marshal(Withdraw(NeedID{Elicitation: "X"}))
	if string(out) != `{"withdraw":{"elicitation":"X"}}` {
		t.Fatalf("%s", out)
	}
	answer, _ := json.Marshal(AnswerElicitationRequest{RequestID: "R", Action: "accept", Content: map[string]any{"drink": "tea"}})
	if string(answer) != `{"requestID":"R","action":"accept","content":{"drink":"tea"}}` {
		t.Fatalf("%s", answer)
	}
}

func TestNewUUIDIsUpperCase(t *testing.T) {
	id := NewUUID()
	if len(id) != 36 || id != strings.ToUpper(id) || id[14] != '4' {
		t.Fatalf("%s", id)
	}
}

func TestMemberIDs(t *testing.T) {
	for text, want := range map[string]bool{"U0ALEX": true, "W123": true, "U1": false, "alex": false, "u0alex": false, "U0 ALEX": false} {
		if IsMemberID(text) != want {
			t.Errorf("%q: want %v", text, want)
		}
	}
}

func TestSecretsRoundTripAndKeepOtherLines(t *testing.T) {
	home := t.TempDir()
	path := SecretsPath(home, "secrets.env")
	env := ParseSecrets("# keep me\nA=one\n")
	env.Set("B", "x=y=z")
	if err := env.Save(path); err != nil {
		t.Fatal(err)
	}
	if m := mode(t, path); m != 0o600 {
		t.Fatalf("mode %o", m)
	}
	loaded := LoadSecrets(path)
	if v, _ := loaded.Value("B"); v != "x=y=z" || !reflect.DeepEqual(loaded.Names(), []string{"A", "B"}) {
		t.Fatalf("%v", loaded.Names())
	}
	if loaded.Text() != "# keep me\nA=one\nB=x=y=z\n" {
		t.Fatalf("%q", loaded.Text())
	}

	env = ParseSecrets("FOO=1\n# comment\nBAR=2\n\n1BAD=3\nno equals\n")
	env.Set("FOO", "nine")
	env.Remove("BAR")
	if env.Text() != "FOO=nine\n# comment\n\n1BAD=3\nno equals\n" || !reflect.DeepEqual(env.Names(), []string{"FOO"}) {
		t.Fatalf("%q", env.Text())
	}
	if ParseSecrets("").Text() != "" {
		t.Fatal("empty is not empty")
	}
}

func TestSecretsLiveInAPrivateFolderPutBackOnSave(t *testing.T) {
	home := t.TempDir()
	path := SecretsPath(home, FileName)
	if path != filepath.Join(home, ".agents-secrets", "channels.env") {
		t.Fatalf("%s", path)
	}
	if err := ParseSecrets("A=one\n").Save(path); err != nil {
		t.Fatal(err)
	}
	folder := filepath.Dir(path)
	if m := mode(t, folder); m != 0o700 {
		t.Fatalf("folder %o", m)
	}
	if err := os.Chmod(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := ParseSecrets("A=two\n").Save(path); err != nil {
		t.Fatal(err)
	}
	if m := mode(t, folder); m != 0o700 {
		t.Fatalf("a save puts the folder back to owner only: %o", m)
	}
	entries, _ := os.ReadDir(folder)
	if len(entries) != 1 {
		t.Fatalf("a temporary file was left: %v", entries)
	}
	if _, err := LoadSecretsForChange(filepath.Join(home, "missing.env")); err != nil {
		t.Fatal(err)
	}
	bad := filepath.Join(home, "bad.env")
	_ = os.WriteFile(bad, []byte{0xff, 0xfe}, 0o600)
	if _, err := LoadSecretsForChange(bad); err == nil {
		t.Fatal("bytes that are not UTF-8 read")
	}
}
