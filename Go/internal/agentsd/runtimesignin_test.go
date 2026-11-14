package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// A server's Claude and Codex signed in from a client (#3349), with fakes of their own
// command lines on the PATH: the link and code each gives, the code typed back, a key, and
// what the status says before and after.

const fakeClaudeTool = `#!/bin/sh
[ "$1" = setup-token ] || exit 2
stty raw -echo 2>/dev/null
printf 'Browser did not open? Use the url below to sign in:\n\n\033]8;;https://claude.ai/oauth/authorize?code=true&state=x\007https://claude.ai/oauth/authorize?code=true&state=x\033]8;;\007\n\nPaste code here if prompted > '
# As Claude's Ink prompt (#5202): a chunk with text in it is a paste, and an Enter in a
# paste is dropped; only an Enter by itself submits. Each chunk shows as a star.
cr=$(printf '\r'); code=
while :; do
  chunk=$(dd bs=512 count=1 2>/dev/null)
  [ "$chunk" = "$cr" ] && break
  code="$code$(printf '%s' "$chunk" | tr -d '\r')"
  printf '*'
done
good=good; [ -f "$HOME/claude-good-code" ] && good=$(cat "$HOME/claude-good-code")
if [ "$code" = "$good" ]; then
  printf '\n\033[32mLong-lived authentication token created\033[0m\n\nsk-ant-oat01-abc_DEF-123\n'
  sleep 30
else
  printf '\n\033[38;5;211mOAuth\033[7Gerror:\033[14GThat code was not accepted.\033[0m\n\033[1C\033[1BPress Enter to retry.\n'
  sleep 30
fi
`

const fakeCodexTool = `#!/bin/sh
case "$1 $2" in
"login --device-auth")
  printf '\033[1mFollow these steps\033[0m\n1. Open this link\n   \033[94mhttps://auth.openai.com/codex/device\033[0m\n2. Enter this one-time code \033[90m(expires in 15 minutes)\033[0m\n   \033[94mABCD-EFGH1\033[0m\n'
  while [ ! -f "$HOME/entered" ]; do sleep 0.1; done
  mkdir -p "$HOME/.codex" && echo '{}' > "$HOME/.codex/auth.json"
  echo 'Successfully logged in' ;;
"login --with-api-key")
  read k
  [ "$k" = sk-good ] || { echo 'That key was refused' >&2; exit 1; }
  mkdir -p "$HOME/.codex" && echo '{}' > "$HOME/.codex/auth.json" ;;
*) exit 2 ;;
esac
`

// fakeSignInTools puts fake claude and codex in a fresh home's ~/.local/bin, which
// searchPaths looks in, and gives back the home.
func fakeSignInTools(t *testing.T) string {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", "")
	for _, v := range []string{"CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"} {
		t.Setenv(v, "")
	}
	bin := filepath.Join(home, ".local", "bin")
	os.MkdirAll(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "claude"), []byte(fakeClaudeTool), 0o755)
	os.WriteFile(filepath.Join(bin, "codex"), []byte(fakeCodexTool), 0o755)
	return home
}

// asAServer makes a daemon started on a Mac (CI's go-darwin) act as a server: a Mac signs
// its runtimes in on the Mac.
func asAServer(t *testing.T) {
	old := macToolsHome
	macToolsHome = ""
	t.Cleanup(func() { macToolsHome = old })
}

func statusFor(t *testing.T, c *conn, id int, runtimeID string) wire.RuntimeStatus {
	t.Helper()
	var list []wire.RuntimeStatus
	json.Unmarshal(c.call(t, id, "runtimes/list", map[string]any{}), &list)
	for _, s := range list {
		if s.Runtime.ID == runtimeID {
			return s
		}
	}
	t.Fatalf("no %s in %+v", runtimeID, list)
	return wire.RuntimeStatus{}
}

func TestSigningClaudeInOnAServer(t *testing.T) {
	fakeRuntimes(t)
	fakeSignInTools(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	asAServer(t)

	if s := statusFor(t, c, 1, "claude"); s.SignIn == nil || s.SignIn.SignedIn {
		t.Fatalf("before: %+v", s.SignIn)
	}
	if s := statusFor(t, c, 2, "grok"); s.SignIn != nil {
		t.Fatalf("grok signs in from a terminal: %+v", s.SignIn)
	}

	var step wire.RuntimeSignInStep
	json.Unmarshal(c.call(t, 3, "runtimes/signInStart", map[string]any{"runtimeID": "claude"}), &step)
	if string(step.URL) != "https://claude.ai/oauth/authorize?code=true&state=x" || !step.WantsCode || step.UserCode != nil {
		t.Fatalf("%+v", step)
	}
	if e := c.callError(t, 4, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID}); e.Code != CodeInvalidParams {
		t.Fatalf("no code: %+v", e)
	}
	e := c.callError(t, 5, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID, "code": "bad"})
	if e.Code != wire.FailureNeedsSignIn || e.Message != "Claude did not take that code: OAuth error: That code was not accepted." {
		t.Fatalf("bad code: %+v", e)
	}

	json.Unmarshal(c.call(t, 6, "runtimes/signInStart", map[string]any{"runtimeID": "claude"}), &step)
	var s wire.RuntimeStatus
	json.Unmarshal(c.call(t, 7, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID, "code": " good\n"}), &s)
	if s.SignIn == nil || !s.SignIn.SignedIn {
		t.Fatalf("after: %+v", s.SignIn)
	}
	if got := d.storedClaudeSignIn(); got != "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abc_DEF-123" {
		t.Fatalf("kept %q", got)
	}
	if fi, _ := os.Stat(d.claudeSignInFile()); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}
	// Claude starts with it.
	l, err := d.launchFor(runtimeByID("claude"), t.TempDir())
	if err != nil || !hasVariable(l.Env, "CLAUDE_CODE_OAUTH_TOKEN") {
		t.Fatalf("%v %v", err, l.Env)
	}
	if e := c.callError(t, 8, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID, "code": "good"}); e.Code != CodeInvalidParams {
		t.Fatalf("finished twice: %+v", e)
	}

	// A key replaces it; one with spaces in it is refused.
	if e := c.callError(t, 9, "runtimes/signInKey", map[string]any{"runtimeID": "claude", "key": "sk ant"}); e.Code != CodeInvalidParams {
		t.Fatalf("%+v", e)
	}
	c.call(t, 10, "runtimes/signInKey", map[string]any{"runtimeID": "claude", "key": " sk-ant-api03-xyz "})
	if got := d.storedClaudeSignIn(); got != "ANTHROPIC_API_KEY=sk-ant-api03-xyz" {
		t.Fatalf("kept %q", got)
	}
}

// A code as long as a real one (#5331). The code platform.claude.com gives is 92
// characters, letters, digits, "-", "_" and a "#" before the state; #5202 was such a code
// waiting at Claude's prompt, because its Enter came in the same write and Claude took it
// as a paste. The fake takes only the whole code, so a code cut short or run together with
// its Enter fails here as it failed on a server. No Claude account or person is needed;
// Alex's real code is checked once a release (the release skill).
func TestSigningClaudeInWithACodeAsLongAsARealOne(t *testing.T) {
	fakeRuntimes(t)
	home := fakeSignInTools(t)
	code := strings.Repeat("aB3-_x9Z", 6) + "Qw7#" + strings.Repeat("st4T-_e9", 5)
	if len(code) != 92 {
		t.Fatalf("the code is %d characters, not 92", len(code))
	}
	os.WriteFile(filepath.Join(home, "claude-good-code"), []byte(code), 0o600)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	asAServer(t)

	var step wire.RuntimeSignInStep
	json.Unmarshal(c.call(t, 1, "runtimes/signInStart", map[string]any{"runtimeID": "claude"}), &step)
	if !step.WantsCode {
		t.Fatalf("%+v", step)
	}
	// Cut short, it is refused: the fake compares the whole code.
	e := c.callError(t, 2, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID, "code": code[:91]})
	if e.Code != wire.FailureNeedsSignIn || !strings.Contains(e.Message, "not accepted") {
		t.Fatalf("a code cut short: %+v", e)
	}

	json.Unmarshal(c.call(t, 3, "runtimes/signInStart", map[string]any{"runtimeID": "claude"}), &step)
	var s wire.RuntimeStatus
	json.Unmarshal(c.call(t, 4, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID, "code": code + "\n"}), &s)
	if s.SignIn == nil || !s.SignIn.SignedIn {
		t.Fatalf("after the long code: %+v", s.SignIn)
	}
	if got := d.storedClaudeSignIn(); got != "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abc_DEF-123" {
		t.Fatalf("kept %q", got)
	}
	if fi, _ := os.Stat(d.claudeSignInFile()); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}
}

func TestSigningCodexInOnAServer(t *testing.T) {
	fakeRuntimes(t)
	home := fakeSignInTools(t)
	old := codexFinishWait
	codexFinishWait = 200 * time.Millisecond
	t.Cleanup(func() { codexFinishWait = old })
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	asAServer(t)

	var step wire.RuntimeSignInStep
	json.Unmarshal(c.call(t, 1, "runtimes/signInStart", map[string]any{"runtimeID": "codex"}), &step)
	if string(step.URL) != "https://auth.openai.com/codex/device" || step.UserCode == nil || *step.UserCode != "ABCD-EFGH1" || step.WantsCode {
		t.Fatalf("%+v", step)
	}
	e := c.callError(t, 2, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID})
	if e.Code != wire.FailureNeedsSignIn || !strings.Contains(e.Message, "still waiting") {
		t.Fatalf("too soon: %+v", e)
	}
	os.WriteFile(filepath.Join(home, "entered"), nil, 0o600)
	// Done again until Codex has seen the code: a loaded runner can take longer than one
	// short wait (#3634).
	var s wire.RuntimeStatus
	for id, deadline := 100, time.Now().Add(15*time.Second); ; id++ {
		c.send(requestLine(id, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID}))
		var m message
		json.Unmarshal([]byte(c.answer(t, id)), &m)
		if m.Error == nil {
			json.Unmarshal(m.Result, &s)
			break
		}
		if !strings.Contains(m.Error.Message, "still waiting") || time.Now().After(deadline) {
			t.Fatalf("after entering the code: %+v", m.Error)
		}
	}
	if s.SignIn == nil || !s.SignIn.SignedIn {
		t.Fatalf("after: %+v", s.SignIn)
	}

	os.RemoveAll(filepath.Join(home, ".codex"))
	if e := c.callError(t, 4, "runtimes/signInKey", map[string]any{"runtimeID": "codex", "key": "sk-bad"}); e.Code != wire.FailureNeedsSignIn ||
		!strings.Contains(e.Message, "That key was refused") {
		t.Fatalf("%+v", e)
	}
	json.Unmarshal(c.call(t, 5, "runtimes/signInKey", map[string]any{"runtimeID": "codex", "key": "sk-good"}), &s)
	if !s.SignIn.SignedIn {
		t.Fatalf("key: %+v", s.SignIn)
	}

	// Cancel stops one that is waiting.
	json.Unmarshal(c.call(t, 6, "runtimes/signInStart", map[string]any{"runtimeID": "codex"}), &step)
	c.call(t, 7, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID, "cancel": true})
	if e := c.callError(t, 8, "runtimes/signInFinish", map[string]any{"signInID": step.SignInID}); e.Code != CodeInvalidParams {
		t.Fatalf("%+v", e)
	}
}

func TestOnlyClaudeAndCodexSignInThisWay(t *testing.T) {
	fakeRuntimes(t)
	fakeSignInTools(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	asAServer(t)
	if e := c.callError(t, 1, "runtimes/signInStart", map[string]any{"runtimeID": "grok"}); e.Code != CodeNotSupported {
		t.Fatalf("%+v", e)
	}
}
