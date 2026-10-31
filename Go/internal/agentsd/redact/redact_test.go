package redact

import (
	"encoding/json"
	"strings"
	"testing"
)

// Made-up tokens of each shape: none is a real secret.
var (
	github    = "ghp_" + strings.Repeat("a1B2", 9)
	githubPAT = "github_pat_" + strings.Repeat("Ab1_", 15)
	gitlab    = "glpat-" + strings.Repeat("x9Y_", 5)
	anthropic = "sk-ant-api03-" + strings.Repeat("Zz09-_", 8)
	openai    = "sk-proj-" + strings.Repeat("q1W2e3R4", 5)
	stripe    = "sk_live_" + strings.Repeat("4eC3", 6)
	aws       = "AKIA" + "IOSFODNN7EXAMPLE"
	google    = "AIza" + strings.Repeat("Sy0_-", 7)
	slack     = "xoxb-123456789012-" + strings.Repeat("aB3", 6)
	npm       = "npm_" + strings.Repeat("n0P1", 9)
	jwt       = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
	code      = "agents-control:1:AbCdEf0123456789"
	pem       = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"
)

func TestEachShapeIsRedacted(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"GITHUB_TOKEN=" + github, "GITHUB_TOKEN=[redacted:github]"},
		{"token " + githubPAT + " ok", "token [redacted:github] ok"},
		{gitlab, "[redacted:gitlab]"},
		{"key: " + anthropic, "key: [redacted:anthropic]"},
		{"OPENAI_API_KEY=" + openai, "OPENAI_API_KEY=[redacted:openai]"},
		{stripe, "[redacted:stripe]"},
		{"aws_access_key_id = " + aws, "aws_access_key_id = [redacted:aws]"},
		{google, "[redacted:google]"},
		{slack, "[redacted:slack]"},
		{npm, "[redacted:npm]"},
		{"jwt=" + jwt, "jwt=[redacted:jwt]"},
		{"join with " + code, "join with [redacted:agents-code]"},
		{"before\n" + pem + "\nafter", "before\n[redacted:private-key]\nafter"},
		{"Authorization: Bearer abcdefghijklmnop0123", "Authorization: Bearer [redacted:bearer]"},
		{"authorization: bearer " + github, "authorization: bearer [redacted:github]"},
		{github + "," + npm, "[redacted:github],[redacted:npm]"},
	} {
		if got := Text(c.in); got != c.want {
			t.Errorf("Text(%q)\n got %q\nwant %q", c.in, got, c.want)
		}
	}
}

func TestPlainTextIsNotChanged(t *testing.T) {
	for _, s := range []string{
		"",
		"Hello, world.",
		"commit 43d43a2026f0c1e8b6d1f6c4a0f6f8b2e9c1d3a4",
		"agent 6F9619FF-8B86-D011-B42D-00C04FC964FF",
		"sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"the task-0123456789abcdef0123456789abcdef file",
		"risk-" + strings.Repeat("a", 40),
		"a bearer of good news",
		"password: correct horse battery staple",
		"AKIA is too short",
	} {
		b := []byte(s)
		if got, changed := Bytes(b); changed || string(got) != s {
			t.Errorf("Bytes(%q) = %q, %v", s, got, changed)
		}
	}
}

func TestAJSONLineStaysValid(t *testing.T) {
	text := "cat .env\nGITHUB_TOKEN=" + github + "\n\tAWS=" + aws + "\n" + pem + "\n\"quoted\" " + anthropic
	line, _ := json.Marshal(map[string]any{"kind": map[string]any{"toolCall": map[string]any{"output": text, "title": "Bearer " + strings.Repeat("Q", 20)}}})
	got, changed := Bytes(line)
	if !changed {
		t.Fatal("nothing redacted")
	}
	if !json.Valid(got) {
		t.Fatalf("not valid JSON: %s", got)
	}
	for _, secret := range []string{github, aws, anthropic, "b3BlbnNzaC1rZXktdjEAAAAA", strings.Repeat("Q", 20)} {
		if strings.Contains(string(got), secret) {
			t.Errorf("%q is still in %s", secret, got)
		}
	}
	var v map[string]map[string]map[string]string
	if err := json.Unmarshal(got, &v); err != nil {
		t.Fatal(err)
	}
	want := "cat .env\nGITHUB_TOKEN=[redacted:github]\n\tAWS=[redacted:aws]\n[redacted:private-key]\n\"quoted\" [redacted:anthropic]"
	if out := v["kind"]["toolCall"]["output"]; out != want {
		t.Fatalf("output %q, want %q", out, want)
	}
}

func BenchmarkALineWithNoToken(b *testing.B) {
	line := []byte(strings.Repeat(`{"kind":{"agentMessage":{"text":"Some words of a reply, sk- and eyJ."}}} `, 64))
	for b.Loop() {
		Bytes(line)
	}
}

func BenchmarkALineWithAToken(b *testing.B) {
	line := []byte(strings.Repeat("words ", 680) + github)
	for b.Loop() {
		Bytes(line)
	}
}

func TestTokensFarIntoALongLine(t *testing.T) {
	pad := strings.Repeat("x ", 3000)
	in := pad + github + " " + pad + "Bearer " + github + " sk-" + pad + github
	want := pad + "[redacted:github] " + pad + "Bearer [redacted:github] sk-" + pad + "[redacted:github]"
	if got := Text(in); got != want {
		t.Fatalf("got %d bytes, %d redactions", len(got), strings.Count(got, "[redacted:"))
	}
	if got := Text("xghp_" + strings.Repeat("a1B2", 9)); strings.Contains(got, "redacted") {
		t.Fatalf("inside a word: %q", got)
	}
}
