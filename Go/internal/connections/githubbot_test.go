package connections

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// allowedBotPermissions is the spike's list (spec 3856 §1), written out here on purpose: a
// change to BotPermissions that adds a key, or makes one stronger, fails this test.
var allowedBotPermissions = map[string]string{
	"contents": "write", "pull_requests": "write", "issues": "write",
	"checks": "read", "statuses": "read", "actions": "write",
}

// The manifest asks for the fixed permissions only (#3858 acceptance 1).
func TestBotManifestHasOnlyTheFixedPermissions(t *testing.T) {
	start, err := NewBotStart("alexec", false, "")
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(start.Manifest), &m); err != nil {
		t.Fatal(err)
	}
	perms, _ := m["default_permissions"].(map[string]any)
	if len(perms) == 0 {
		t.Fatalf("no permissions: %s", start.Manifest)
	}
	rank := map[string]int{"read": 1, "write": 2}
	for k, v := range perms {
		want, ok := allowedBotPermissions[k]
		if !ok {
			t.Errorf("the manifest asks for %q, which is not in the fixed list", k)
			continue
		}
		if rank[v.(string)] == 0 || rank[v.(string)] > rank[want] {
			t.Errorf("the manifest asks for %s: %v, more than %s", k, v, want)
		}
	}
	for _, forbidden := range []string{"workflows", "administration", "secrets", "environments", "members",
		"organization_administration", "deployments", "actions_variables"} {
		if _, ok := perms[forbidden]; ok {
			t.Errorf("the manifest asks for %s", forbidden)
		}
	}
	if ev, _ := m["default_events"].([]any); len(ev) != 0 {
		t.Errorf("the manifest asks for events: %v", ev)
	}
	if _, ok := m["hook_attributes"]; ok {
		t.Error("the manifest has a webhook")
	}
	if m["name"] != "alexec-agents" || m["redirect_url"] != HandBackURL || m["public"] != false {
		t.Errorf("manifest: %s", start.Manifest)
	}
	u, _ := url.Parse(start.Action)
	if u.Host != "github.com" || u.Path != "/settings/apps/new" || u.Query().Get("state") != start.State || start.State == "" {
		t.Errorf("action %q, state %q", start.Action, start.State)
	}
}

func TestBotNameAndStart(t *testing.T) {
	long := strings.Repeat("a", 39)
	if n := BotName(long); len(n) != AppNameMost || !strings.HasSuffix(n, "-agents") {
		t.Errorf("BotName(39 a) = %q", n)
	}
	if _, err := NewBotStart("not a login", false, ""); err == nil {
		t.Error("a login with a space started")
	}
	web, err := NewBotStart("alexec", true, "https://agentloops.dev")
	if err != nil || !strings.Contains(web.State, ".") || !strings.Contains(web.Manifest, `"public":true`) {
		t.Errorf("web start: %+v %v", web, err)
	}
}

func testKey(t *testing.T) (*rsa.PrivateKey, string) {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return k, string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(k)}))
}

// fakeBotGitHub answers the manifest's conversion once, the installations and their tokens, and
// checks each JWT with the App's public key.
func fakeBotGitHub(t *testing.T, key *rsa.PrivateKey, pemText string) *httptest.Server {
	used := false
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/app-manifests/good/conversions":
			if used {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			used = true
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 42, "slug": "alexec-agents", "pem": pemText,
				"owner": map[string]any{"login": "alexec"}, "client_secret": "cs"})
		case strings.HasPrefix(r.URL.Path, "/app-manifests/"):
			w.WriteHeader(http.StatusNotFound)
		case r.URL.Path == "/app/installations" || strings.HasPrefix(r.URL.Path, "/app/installations/"):
			if !validJWT(t, r.Header.Get("Authorization"), &key.PublicKey) {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if r.Method == http.MethodGet {
				fmt.Fprint(w, `[{"id":7,"account":{"login":"alexec","type":"User"},"repository_selection":"selected"},
					{"id":8,"account":{"login":"scratch-org","type":"Organization"},"repository_selection":"all"}]`)
				return
			}
			w.WriteHeader(http.StatusCreated)
			fmt.Fprintf(w, `{"token":"ghs_%s","expires_at":%q}`, strings.Split(r.URL.Path, "/")[3],
				time.Now().Add(time.Hour).UTC().Format(time.RFC3339))
		default:
			http.NotFound(w, r)
		}
	}))
}

func validJWT(t *testing.T, header string, pub *rsa.PublicKey) bool {
	parts := strings.Split(strings.TrimPrefix(header, "Bearer "), ".")
	if len(parts) != 3 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], sig) != nil {
		return false
	}
	raw, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var c struct {
		Iss string `json:"iss"`
		Exp int64  `json:"exp"`
	}
	_ = json.Unmarshal(raw, &c)
	return c.Iss == "42" && c.Exp > time.Now().Unix() && c.Exp <= time.Now().Add(10*time.Minute).Unix()
}

func TestBotConversionTokensAndAUsedCode(t *testing.T) {
	key, pemText := testKey(t)
	gh := fakeBotGitHub(t, key, pemText)
	defer gh.Close()
	c := &BotClient{API: gh.URL, HTTP: gh.Client()}
	ctx := context.Background()

	bot, err := c.Convert(ctx, "good", "alexec")
	if err != nil || bot.AppID != 42 || bot.Slug != "alexec-agents" || bot.Person != "alexec" || bot.PrivateKey != pemText {
		t.Fatalf("Convert: %+v %v", bot, err)
	}
	if _, err := c.Convert(ctx, "good", "alexec"); !errors.Is(err, ErrCodeUsed) {
		t.Errorf("a code used twice: %v", err)
	}
	list, err := c.Installations(ctx, bot)
	if err != nil || len(list) != 2 || list[1].Account != "scratch-org" || !list[1].All || !list[1].Org || list[0].All {
		t.Fatalf("Installations: %+v %v", list, err)
	}
	if u := list[1].SettingsURL(); u != "https://github.com/organizations/scratch-org/settings/installations/8" {
		t.Errorf("settings: %s", u)
	}

	// Kept in a store and read back, the bot makes a token for each account it is installed on.
	file := &File{Path: filepath.Join(t.TempDir(), FileName)}
	if err := file.Put(bot.Connection()); err != nil {
		t.Fatal(err)
	}
	tokens := NewBotTokens(Locator("file:" + file.Path))
	tokens.Client = c
	if tok, b := tokens.For(ctx, "Scratch-Org"); tok != "ghs_8" || b.Slug != "alexec-agents" {
		t.Errorf("For(scratch-org) = %q %+v", tok, b)
	}
	if tok, _ := tokens.For(ctx, "someone-else"); tok != "" {
		t.Errorf("an account the bot is not on got %q", tok)
	}
	if bot.Footer() == "" || !strings.Contains(bot.Trailer(), "alexec@users.noreply.github.com") || bot.Name() != "alexec-agents[bot]" {
		t.Errorf("names: %q %q", bot.Footer(), bot.Trailer())
	}
}

// The key is kept where a sign-in is kept: in this machine's own store, 0600 in a 0700 folder
// on Linux (#3858 acceptance 2), and only there: not in a log, an error or another file.
func TestBotKeyIsKeptOnlyInThisMachinesStore(t *testing.T) {
	_, pemText := testKey(t)
	dir := filepath.Join(t.TempDir(), ".agents-secrets")
	file := &File{Path: filepath.Join(dir, FileName)}
	bot := Bot{AppID: 42, Slug: "alexec-agents", Owner: "alexec", Person: "alexec", PrivateKey: pemText, MadeAt: time.Now()}
	if err := file.Put(bot.Connection()); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(file.Path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("the store's file: %v %v", info, err)
	}
	if d, _ := os.Stat(dir); d.Mode().Perm() != 0o700 {
		t.Errorf("the store's folder is %v", d.Mode().Perm())
	}
	c, ok, err := file.Get(GitHubBot)
	if got, made := BotOf(c); !ok || err != nil || !made || got.PrivateKey != pemText || got.AppID != 42 {
		t.Fatalf("read back: %+v %v %v", got, ok, err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Errorf("the store's folder has %d files", len(entries))
	}
	// The bot is not a connection of its own: List does not show it.
	all, _ := List(file)
	for _, c := range all {
		if c.Provider == GitHubBot {
			t.Error("List shows the bot")
		}
	}
}
