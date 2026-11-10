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
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The person's agents' bot (#3858, spike #3856, specs/3856-agent-identity-github-app): a
// GitHub App that the person makes with GitHub's manifest flow, named <login>-agents, so
// its posts are <login>-agents[bot]'s. The machine that the person's client asked turns the
// manifest's code into the App's id and private key, and keeps them in this store, as it keeps
// a sign-in: in the Keychain on a Mac, in ~/.agents-secrets on Linux. The key never goes to a
// client, the control plane or another person's machine.

// GitHubBot is the bot's provider in the store. It is not in Providers: the bot is a part of
// the GitHub connection, not a connection of its own.
const GitHubBot = "github-bot"

// BotPermissions is the bot's fixed permissions (spec 3856 §1). Workflows, so a lane can push
// a change to .github/workflows (#4291). Never administration, secrets, variables,
// environments, deployments or members: the tools that need them keep the person's user token.
var BotPermissions = map[string]string{
	"contents":      "write",
	"pull_requests": "write",
	"issues":        "write",
	"checks":        "read",
	"statuses":      "read",
	"actions":       "write",
	"workflows":     "write",
}

// AppNameMost is GitHub's longest App name.
const AppNameMost = 34

// BotName is the App's name for login: <login>-agents, cut to GitHub's 34 characters. When
// the name is taken, the person changes it on GitHub's page before they make the App.
func BotName(login string) string {
	const suffix = "-agents"
	if len(login) > AppNameMost-len(suffix) {
		login = login[:AppNameMost-len(suffix)]
	}
	return login + suffix
}

// BotManifest is the App manifest GitHub's "new App" page is given (spec 3856 §4). With no
// webhook: the github server polls. public is false for an App on the person's own account,
// true when an organisation must install it (only the owning account installs a private App).
type BotManifest struct {
	Name                  string            `json:"name"`
	URL                   string            `json:"url"`
	Description           string            `json:"description"`
	RedirectURL           string            `json:"redirect_url"`
	Public                bool              `json:"public"`
	DefaultPermissions    map[string]string `json:"default_permissions"`
	DefaultEvents         []string          `json:"default_events"`
	RequestOAuthOnInstall bool              `json:"request_oauth_on_install"`
}

// NewBotManifest is the manifest of login's bot.
func NewBotManifest(login string, public bool) BotManifest {
	perms := make(map[string]string, len(BotPermissions))
	for k, v := range BotPermissions {
		perms[k] = v
	}
	return BotManifest{Name: BotName(login), URL: "https://agentloops.dev",
		Description: "The coding agents of @" + login + ", made in Agents. It acts only where " + login + " installs it.",
		RedirectURL: HandBackURL, Public: public, DefaultPermissions: perms, DefaultEvents: []string{}}
}

// BotStart is what a client is given to start the setup: the page it posts Manifest to (as the
// form field "manifest"), with State in the address. State comes back with the code.
type BotStart struct {
	Action, Manifest, State string
}

// NewBotStart is the setup for login's bot, on the person's own account. public is true when an
// organisation must install it. origin is the web page's, as NewPKCE takes it.
func NewBotStart(login string, public bool, origin string) (BotStart, error) {
	if !plainWord(login) {
		return BotStart{}, errors.New("that is not a GitHub account name")
	}
	p, err := NewPKCE(origin)
	if err != nil {
		return BotStart{}, err
	}
	m, err := json.Marshal(NewBotManifest(login, public))
	if err != nil {
		return BotStart{}, err
	}
	return BotStart{Action: "https://github.com/settings/apps/new?state=" + url.QueryEscape(p.State), Manifest: string(m), State: p.State}, nil
}

// Bot is the person's bot as the store keeps it. PrivateKey is a secret: it leaves the store
// only to sign this machine's own JWTs.
type Bot struct {
	AppID int64  `json:"appId"`
	Slug  string `json:"slug"`
	// Owner is the account the App is on: the person's, or an organisation's.
	Owner string `json:"owner"`
	// Person is who the bot acts for: the trailer and the footer name them.
	Person     string    `json:"person"`
	PrivateKey string    `json:"privateKey"`
	MadeAt     time.Time `json:"madeAt"`
}

// Connection is the bot as a store item. The key is the item's Access, so the store keeps it
// as it keeps a token; the rest is the item's other fields.
func (b Bot) Connection() Connection {
	return Connection{Provider: GitHubBot, Login: b.Slug, Workspace: b.Owner, User: b.Person,
		Resource: strconv.FormatInt(b.AppID, 10), Access: b.PrivateKey, ConnectedAt: b.MadeAt}
}

// BotOf is the bot that a store item keeps; ok is false when c is not one.
func BotOf(c Connection) (Bot, bool) {
	id, err := strconv.ParseInt(c.Resource, 10, 64)
	if c.Provider != GitHubBot || err != nil || c.Access == "" || c.Login == "" {
		return Bot{}, false
	}
	return Bot{AppID: id, Slug: c.Login, Owner: c.Workspace, Person: c.User, PrivateKey: c.Access, MadeAt: c.ConnectedAt}, true
}

// Name is the bot's GitHub name: <slug>[bot].
func (b Bot) Name() string { return b.Slug + "[bot]" }

// InstallURL is where the person installs the App on their repositories.
func (b Bot) InstallURL() string {
	return "https://github.com/apps/" + url.PathEscape(b.Slug) + "/installations/new"
}

// Trailer is the line a bot commit ends with, naming the person (spec 3856 §3: a commit has
// no App badge).
func (b Bot) Trailer() string {
	return "Co-authored-by: " + b.Person + " <" + b.Person + "@users.noreply.github.com>"
}

// Footer is what a bot comment, issue or pull request ends with, naming the person.
func (b Bot) Footer() string {
	return "<sub>Posted by the agents of @" + b.Person + ".</sub>"
}

// ErrCodeUsed is a manifest code that GitHub says is used or gone: someone else may have
// turned it into the App's key. The person deletes the App and makes it again.
var ErrCodeUsed = errors.New("GitHub has already given this App's key to someone, or the code ended: the key may be stolen. Delete the App on GitHub, then make it again")

// BotClient is the GitHub API for the bot: the manifest's conversion and installation tokens.
type BotClient struct {
	// API is GitHub's REST root; a test gives a fake's.
	API  string
	HTTP *http.Client
	Now  func() time.Time
}

// BotAPIEnv names another GitHub API for the bot, a fake GitHub's on a walk's scratch host.
const BotAPIEnv = "AGENTS_GITHUB_BOT_API"

// NewBotClient is the client for api.github.com, or for BotAPIEnv's.
func NewBotClient() *BotClient {
	api := "https://api.github.com"
	if v := strings.TrimRight(os.Getenv(BotAPIEnv), "/"); v != "" {
		api = v
	}
	return &BotClient{API: api, HTTP: &http.Client{Timeout: 30 * time.Second}}
}

func (c *BotClient) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// Convert turns the manifest's code into the App (POST /app-manifests/{code}/conversions,
// no authentication, once, within an hour). person is who the bot acts for.
func (c *BotClient) Convert(ctx context.Context, code, person string) (Bot, error) {
	if code == "" || strings.ContainsAny(code, "/?#") {
		return Bot{}, errors.New("GitHub gave back no code")
	}
	var a struct {
		ID    int64  `json:"id"`
		Slug  string `json:"slug"`
		PEM   string `json:"pem"`
		Owner struct {
			Login string `json:"login"`
		} `json:"owner"`
	}
	status, err := c.call(ctx, http.MethodPost, "/app-manifests/"+url.PathEscape(code)+"/conversions", "", &a)
	if err != nil {
		return Bot{}, err
	}
	switch {
	case status == http.StatusNotFound || status == http.StatusUnprocessableEntity:
		return Bot{}, ErrCodeUsed
	case status != http.StatusCreated && status != http.StatusOK:
		return Bot{}, fmt.Errorf("GitHub answered %d when asked for the App", status)
	case a.ID == 0 || a.Slug == "" || a.PEM == "":
		return Bot{}, errors.New("GitHub's answer had no App")
	}
	if _, err := parseKey(a.PEM); err != nil {
		return Bot{}, err
	}
	return Bot{AppID: a.ID, Slug: a.Slug, Owner: a.Owner.Login, Person: person, PrivateKey: a.PEM, MadeAt: c.now()}, nil
}

// Installation is one account the bot is installed on.
type Installation struct {
	ID int64 `json:"id"`
	// Account is the user or organisation it is installed on.
	Account string `json:"account"`
	// All is true when it reaches every repository of the account, false for selected ones.
	All bool `json:"all"`
	// Org is true for an organisation's account.
	Org bool `json:"org"`
}

// SettingsURL is where the person chooses the installation's repositories on GitHub.
func (i Installation) SettingsURL() string {
	id := strconv.FormatInt(i.ID, 10)
	if i.Org {
		return "https://github.com/organizations/" + url.PathEscape(i.Account) + "/settings/installations/" + id
	}
	return "https://github.com/settings/installations/" + id
}

// Installations is every account the bot is installed on (GET /app/installations).
func (c *BotClient) Installations(ctx context.Context, b Bot) ([]Installation, error) {
	jwt, err := b.jwt(c.now())
	if err != nil {
		return nil, err
	}
	var list []struct {
		ID      int64 `json:"id"`
		Account struct {
			Login string `json:"login"`
			Type  string `json:"type"`
		} `json:"account"`
		RepositorySelection string `json:"repository_selection"`
	}
	status, err := c.call(ctx, http.MethodGet, "/app/installations?per_page=100", jwt, &list)
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("GitHub answered %d for the App's installations", status)
	}
	out := make([]Installation, 0, len(list))
	for _, i := range list {
		out = append(out, Installation{ID: i.ID, Account: i.Account.Login, All: i.RepositorySelection == "all", Org: i.Account.Type == "Organization"})
	}
	return out, nil
}

// InstallationToken is a token for one installation, at most an hour long
// (POST /app/installations/{id}/access_tokens).
func (c *BotClient) InstallationToken(ctx context.Context, b Bot, id int64) (string, time.Time, error) {
	jwt, err := b.jwt(c.now())
	if err != nil {
		return "", time.Time{}, err
	}
	var t struct {
		Token     string    `json:"token"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	status, err := c.call(ctx, http.MethodPost, "/app/installations/"+strconv.FormatInt(id, 10)+"/access_tokens", jwt, &t)
	if err != nil {
		return "", time.Time{}, err
	}
	if status != http.StatusCreated || t.Token == "" {
		return "", time.Time{}, fmt.Errorf("GitHub answered %d for an installation token", status)
	}
	return t.Token, t.ExpiresAt, nil
}

func (c *BotClient) call(ctx context.Context, method, path, bearer string, into any) (int, error) {
	req, err := http.NewRequestWithContext(ctx, method, c.API+path, nil)
	if err != nil {
		return 0, errors.New("the request to GitHub could not be made")
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	res, err := c.HTTP.Do(req)
	if err != nil {
		return 0, errors.New("GitHub could not be reached")
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode/100 == 2 && json.Unmarshal(data, into) != nil {
		return res.StatusCode, errors.New("GitHub's answer did not read")
	}
	return res.StatusCode, nil
}

func parseKey(p string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(p))
	if block == nil {
		return nil, errors.New("the App's key did not read")
	}
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if r, ok := k.(*rsa.PrivateKey); err == nil && ok {
		return r, nil
	}
	return nil, errors.New("the App's key did not read")
}

// jwt is the App's own token (RS256, 9 minutes, issued a minute back for clock drift), which
// GitHub takes only to list installations and make their tokens.
func (b Bot) jwt(now time.Time) (string, error) {
	key, err := parseKey(b.PrivateKey)
	if err != nil {
		return "", err
	}
	enc := base64.RawURLEncoding
	header := enc.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{"iat": now.Add(-time.Minute).Unix(), "exp": now.Add(9 * time.Minute).Unix(),
		"iss": strconv.FormatInt(b.AppID, 10)})
	signing := header + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		return "", errors.New("the App's token could not be signed")
	}
	return signing + "." + enc.EncodeToString(sig), nil
}

// BotTokens makes and keeps the bot's installation tokens, one an account, on the machine
// that keeps the key. It reads the store again at most once a minute, so a bot made or
// removed is seen without a restart.
type BotTokens struct {
	Client *BotClient
	read   func() (Connection, bool)

	mu     sync.Mutex
	tokens map[string]heldToken
	ids    map[string]int64
	idsAt  time.Time
}

type heldToken struct {
	token string
	until time.Time
}

// NewBotTokens is the bot's tokens from the store at l.
func NewBotTokens(l Locator) *BotTokens {
	read := Reader(l, GitHubBot)
	return &BotTokens{Client: NewBotClient(), read: read}
}

// Bot is the kept bot; ok is false when the person has none.
func (t *BotTokens) Bot() (Bot, bool) {
	c, ok := t.read()
	if !ok {
		return Bot{}, false
	}
	return BotOf(c)
}

// For is an installation token for account (a repository's owner), and the bot; "" when the
// person has no bot or it is not installed on account, so the caller uses the user token.
func (t *BotTokens) For(ctx context.Context, account string) (string, Bot) {
	b, ok := t.Bot()
	if !ok || account == "" {
		return "", Bot{}
	}
	account = strings.ToLower(account)
	now := t.Client.now()
	t.mu.Lock()
	defer t.mu.Unlock()
	if h, ok := t.tokens[account]; ok && now.Before(h.until.Add(-5*time.Minute)) {
		return h.token, b
	}
	if t.ids == nil || now.Sub(t.idsAt) > 5*time.Minute {
		list, err := t.Client.Installations(ctx, b)
		if err != nil {
			return "", Bot{}
		}
		t.ids, t.idsAt = map[string]int64{}, now
		for _, i := range list {
			t.ids[strings.ToLower(i.Account)] = i.ID
		}
	}
	id, ok := t.ids[account]
	if !ok {
		return "", Bot{}
	}
	token, until, err := t.Client.InstallationToken(ctx, b, id)
	if err != nil {
		return "", Bot{}
	}
	if t.tokens == nil {
		t.tokens = map[string]heldToken{}
	}
	t.tokens[account] = heldToken{token: token, until: until}
	return token, b
}
