package agentsd

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Several accounts per runtime (#840): an added account is a folder of its own, with the
// person's settings linked, that the agent's runtime is started with; its allowance is its
// own; and it goes with its folder.

func TestAnAddedAccount(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	os.MkdirAll(filepath.Join(home, ".claude", "skills"), 0o700)
	os.WriteFile(filepath.Join(home, ".claude", "CLAUDE.md"), []byte("mine"), 0o600)
	d, c := start(t, root)
	defer d.Shutdown()

	if e := c.callError(t, 1, "runtimes/addAccount", map[string]any{"runtimeID": "grok", "name": "Work"}); e == nil ||
		!strings.Contains(e.Message, "one account") {
		t.Fatalf("Grok took a second account: %+v", e)
	}
	var p wire.AccountProfile
	json.Unmarshal(c.call(t, 2, "runtimes/addAccount", map[string]any{"runtimeID": "claude", "name": " Work "}), &p)
	folder := accountFolder(p)
	if p.Name != "Work" || p.SignedIn || !strings.HasPrefix(folder, filepath.Join(root, "runtimes", "accounts", "claude")) ||
		p.SignInCommand == nil || !strings.HasPrefix(*p.SignInCommand, "CLAUDE_CONFIG_DIR=") {
		t.Fatalf("%+v", p)
	}
	if e := c.callError(t, 3, "runtimes/addAccount", map[string]any{"runtimeID": "claude", "name": "work"}); e == nil {
		t.Fatal("two accounts called Work")
	}
	if b, err := os.ReadFile(filepath.Join(folder, "CLAUDE.md")); err != nil || string(b) != "mine" {
		t.Fatalf("CLAUDE.md not linked: %v", err)
	}
	if fi, err := os.Lstat(filepath.Join(folder, "skills")); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("skills not linked: %v", err)
	}

	// Signed in once its folder says so, and as whom.
	os.WriteFile(filepath.Join(folder, ".claude.json"), []byte(`{"oauthAccount":{"emailAddress":"a@example.com"}}`), 0o600)
	var list []wire.AccountProfile
	json.Unmarshal(c.call(t, 4, "runtimes/accountProfiles", map[string]any{}), &list)
	if len(list) != 1 || !list[0].SignedIn || list[0].SignedInAs == nil || *list[0].SignedInAs != "a@example.com" {
		t.Fatalf("%+v", list)
	}

	// Its runtime is started with its folder, and without a key that would answer first.
	env := withAccount([]string{"CLAUDE_CONFIG_DIR=/elsewhere", "ANTHROPIC_API_KEY=sk", "PATH=/bin"}, &list[0])
	if !slices.Contains(env, "CLAUDE_CONFIG_DIR="+folder) || slices.Contains(env, "ANTHROPIC_API_KEY=sk") ||
		slices.Contains(env, "CLAUDE_CONFIG_DIR=/elsewhere") || !slices.Contains(env, "PATH=/bin") {
		t.Fatalf("%v", env)
	}
	l, err := d.launchAs(runtimeByID("claude"), root, &list[0])
	if err != nil || !slices.Contains(l.Env, "CLAUDE_CONFIG_DIR="+folder) {
		t.Fatalf("%v %v", err, l.Env)
	}

	// Its own row on the allowance list, after the runtime's own.
	var al wire.RuntimeAllowances
	json.Unmarshal(c.call(t, 5, "runtimes/allowances", nil), &al)
	key := "claude:account:" + p.ID
	i := slices.IndexFunc(al.Rows, func(r wire.RuntimeAllowancesRow) bool { return r.CredentialKey == key })
	own := slices.IndexFunc(al.Rows, func(r wire.RuntimeAllowancesRow) bool { return r.CredentialKey == "claude:sign-in" })
	if i < 0 || own < 0 || i != own+1 || al.Rows[i].AccountName == nil || *al.Rows[i].AccountName != "Work" || al.Rows[i].Unusable != nil {
		t.Fatalf("%+v", al.Rows)
	}

	// A session on it keeps it, and spends its allowance, not the runtime's own.
	work := t.TempDir()
	var id wire.UUID
	json.Unmarshal(c.call(t, 6, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + work, "accountID": p.ID,
		"prompt": "hi", "startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []string{}}}), &id)
	a := d.Store.Agent(id)
	if a == nil || a.AccountID == nil || *a.AccountID != p.ID || agentKey(a) != key {
		t.Fatalf("%+v", a)
	}
	d.markOut(agentKey(a), wire.AllowanceStateOutReasonAllowanceSpent, nil, wire.AllowanceStateSourceTypedFailure, nil)
	if s := d.allowancesLocked()[key]; s.Status.Out == nil {
		t.Fatalf("%+v", s)
	}
	if s, ok := d.allowancesLocked()["claude:sign-in"]; ok && s.Status.Out != nil {
		t.Fatal("the runtime's own allowance was spent")
	}
	if got := d.credentialName(key); got != "Claude (Work)" {
		t.Fatal(got)
	}
	if e := c.callError(t, 7, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + work, "accountID": "nope",
		"prompt": "hi", "startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []string{}}}); e == nil {
		t.Fatal("started on an account that is not there")
	}

	// Removed: the folder and its allowance go, and a session on it says so.
	c.call(t, 8, "runtimes/removeAccount", map[string]any{"runtimeID": "claude", "accountID": p.ID})
	if _, err := os.Stat(folder); !os.IsNotExist(err) {
		t.Fatalf("folder kept: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".claude", "CLAUDE.md")); err != nil {
		t.Fatal("the person's own file went with the link")
	}
	if _, ok := d.allowancesLocked()[key]; ok {
		t.Fatal("allowance kept")
	}
	if _, err := d.accountFor(d.Store.Agent(id)); err == nil {
		t.Fatal("a removed account's session would run on another")
	}
	b, _ := os.ReadFile(filepath.Join(root, "runtime-accounts.json"))
	if strings.Contains(string(b), p.ID) {
		t.Fatalf("%s", b)
	}
}

func TestCodexAccountSignedInAs(t *testing.T) {
	folder := t.TempDir()
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"email":"b@example.com"}`))
	os.WriteFile(filepath.Join(folder, "auth.json"), []byte(`{"tokens":{"id_token":"x.`+payload+`.y"}}`), 0o600)
	p := wire.AccountProfile{RuntimeID: "codex", Reach: wire.AccountReach{SignIn: &wire.AccountReachSignIn{Folder: folder}}}
	(&Daemon{}).readSignIn(&p)
	if !p.SignedIn || p.SignedInAs == nil || *p.SignedInAs != "b@example.com" || p.SignInCommand != nil {
		t.Fatalf("%+v", p)
	}
	if !slices.Contains(withAccount(nil, &p), "CODEX_HOME="+folder) {
		t.Fatal("no CODEX_HOME")
	}
}

func TestAccountKeys(t *testing.T) {
	id := "abc"
	if accountKey("claude", nil) != "claude:sign-in" ||
		accountKey("claude", &id) != "claude:account:abc" || keyAccount("claude:account:abc") != "abc" || keyAccount("claude:sign-in") != "" {
		t.Fatal("keys")
	}
	if isSharedKey(accountKey("claude", &id)) {
		t.Fatal("an added account's allowance would go to servers")
	}
}
