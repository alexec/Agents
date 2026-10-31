package agentsd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Several accounts per runtime (#840). The runtime's own sign-in is the Default account and
// is not kept here. An added account is a folder of its own, given to the runtime in its
// account variable (Claude's CLAUDE_CONFIG_DIR, Codex's CODEX_HOME), with links to the
// person's own settings so only the sign-in is separate. The person picks one when they
// start a session; nothing switches to another by itself (Alex). Kept in
// <root>/runtime-accounts.json; the folders are <root>/runtimes/accounts/<runtime>/<id>.
//
// An account's reach is a one-key object so an org key or a gateway (T6, #999) can be
// another case of it.

type accountBook struct {
	accountMu     sync.Mutex
	accountLoaded bool
	profiles      []wire.AccountProfile
	// signIns is this daemon's own: a package-wide cache let another daemon's new file
	// clear this one's readings (#2826).
	signIns signInCache
}

// accountKind is what a runtime that can have more than one account keeps in its folder.
type accountKind struct {
	// variable names the folder.
	variable string
	// cleared is the variables that would answer before the folder's own sign-in.
	cleared []string
	// defaultFolder is the runtime's own folder under the person's home.
	defaultFolder string
	// shared is what is linked from the runtime's own folder, so the account has the
	// person's settings, instructions and skills: never its sign-in.
	shared []string
}

var accountKinds = map[string]accountKind{
	"claude": {variable: "CLAUDE_CONFIG_DIR", defaultFolder: ".claude",
		cleared: []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"},
		shared:  []string{"settings.json", "CLAUDE.md", "skills", "agents", "commands", "plugins", "output-styles", "hooks"}},
	"codex": {variable: "CODEX_HOME", defaultFolder: ".codex",
		cleared: []string{"OPENAI_API_KEY"},
		shared:  []string{"config.toml", "AGENTS.md", "prompts", "skills", "rules"}},
}

func (d *Daemon) accountsPath() string {
	return filepath.Join(d.Store.Loc.Root, "runtime-accounts.json")
}

func (d *Daemon) profilesLocked() []wire.AccountProfile {
	if !d.accountLoaded {
		d.accountLoaded = true
		d.profiles = []wire.AccountProfile{}
		readStore(d.accountsPath(), &d.profiles, "starting with no added accounts")
	}
	return d.profiles
}

// accountProfile is an added account or an org account (#999), or nil.
func (d *Daemon) accountProfile(runtimeID, id string) *wire.AccountProfile {
	if strings.HasPrefix(id, orgAccountPrefix) {
		return d.orgAccount(runtimeID, id)
	}
	d.accountMu.Lock()
	defer d.accountMu.Unlock()
	for _, p := range d.profilesLocked() {
		if p.RuntimeID == runtimeID && p.ID == id {
			return &p
		}
	}
	return nil
}

// accountFor is the agent's added account: nil for the Default one, an error for one that
// was removed, so it never runs on another account without the person knowing.
func (d *Daemon) accountFor(a *wire.Agent) (*wire.AccountProfile, error) {
	if a == nil || a.AccountID == nil {
		return nil, nil
	}
	p := d.accountProfile(a.RuntimeID, *a.AccountID)
	if p == nil && orgRouteOf(a.AccountID) != "" {
		return nil, &Error{Code: wire.FailureOrgRouteRemoved,
			Message: "Your organisation removed this way to the model. Continue in New to move this session to another account."}
	}
	if p == nil {
		return nil, &Error{Code: CodeInvalidParams, Message: "The account this session used was removed. Start a new session on another account."}
	}
	return p, nil
}

// accountProfiles is runtimes/accountProfiles: each added account, with what its folder
// says about its sign-in now, then each org account (#999); each the policy refuses is
// marked, and each runtime's default.
func (d *Daemon) accountProfiles() []wire.AccountProfile {
	d.accountMu.Lock()
	list := append([]wire.AccountProfile{}, d.profilesLocked()...)
	d.accountMu.Unlock()
	for i := range list {
		d.readSignIn(&list[i])
	}
	return d.markAccounts(append(list, d.orgAccounts()...))
}

func (d *Daemon) tellAccountProfiles() {
	Broadcast(d, wire.NotifyRuntimesAccountProfilesChanged, d.accountProfiles())
}

func accountFolder(p wire.AccountProfile) string {
	if p.Reach.SignIn == nil {
		return ""
	}
	return p.Reach.SignIn.Folder
}

// readSignIn fills in whether the folder holds a sign-in, and who it is.
func (d *Daemon) readSignIn(p *wire.AccountProfile) {
	folder := accountFolder(*p)
	p.SignedIn, p.SignedInAs, p.SignInCommand = false, nil, nil
	var r signIn
	switch p.RuntimeID {
	case "claude":
		cmd := "CLAUDE_CONFIG_DIR=" + shellWord(folder) + " claude"
		p.SignInCommand = &cmd
		r = d.signIns.read(filepath.Join(folder, ".claude.json"), func(b []byte) signIn {
			var f struct {
				OAuthAccount *struct {
					EmailAddress string `json:"emailAddress"`
				} `json:"oauthAccount"`
			}
			if json.Unmarshal(b, &f) != nil || f.OAuthAccount == nil {
				return signIn{}
			}
			return signIn{signedIn: true, as: f.OAuthAccount.EmailAddress}
		})
	case "codex":
		r = d.signIns.read(filepath.Join(folder, "auth.json"), func(b []byte) signIn {
			var f struct {
				Tokens *struct {
					IDToken string `json:"id_token"`
				} `json:"tokens"`
			}
			r := signIn{signedIn: true}
			if json.Unmarshal(b, &f) == nil && f.Tokens != nil {
				r.as = jwtEmail(f.Tokens.IDToken)
			}
			return r
		})
	}
	p.SignedIn = r.signedIn
	if r.as != "" {
		p.SignedInAs = &r.as
	}
}

// signIn is what an account folder's sign-in file says.
type signIn struct {
	signedIn bool
	as       string
}

// signInCacheSize bounds a signInCache: one entry an added account's file, cleared when full.
const signInCacheSize = 64

// signInCache keeps each sign-in file's reading by its size and modification time, so a
// broadcast does not read and decode every account's file again (#2251).
type signInCache struct {
	sync.Mutex
	m map[string]signInReading
	// reads counts the files read; a test reads it.
	reads atomic.Int64
}

type signInReading struct {
	size  int64
	mtime time.Time
	r     signIn
}

// read is parse of the file at path, or nothing when there is no file; the file is read
// again only when its size or modification time changed.
func (c *signInCache) read(path string, parse func([]byte) signIn) signIn {
	fi, err := os.Stat(path)
	if err != nil || fi.IsDir() {
		return signIn{}
	}
	c.Lock()
	kept, ok := c.m[path]
	c.Unlock()
	if ok && kept.size == fi.Size() && kept.mtime.Equal(fi.ModTime()) {
		return kept.r
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return signIn{}
	}
	c.reads.Add(1)
	r := parse(b)
	c.Lock()
	if c.m == nil {
		c.m = map[string]signInReading{}
	}
	if _, ok := c.m[path]; !ok && len(c.m) >= signInCacheSize {
		clear(c.m)
	}
	c.m[path] = signInReading{size: fi.Size(), mtime: fi.ModTime(), r: r}
	c.Unlock()
	return r
}

// jwtEmail is the email claim of a token's payload, read and not checked: it only names
// the account.
func jwtEmail(token string) string {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return ""
	}
	b, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Email string `json:"email"`
	}
	if json.Unmarshal(b, &claims) != nil {
		return ""
	}
	return claims.Email
}

// addAccount is runtimes/addAccount: a folder of its own, with the person's settings linked.
func (d *Daemon) addAccount(r wire.AddAccountRequest) (wire.AccountProfile, error) {
	rt := runtimeByID(r.RuntimeID)
	if rt == nil {
		return wire.AccountProfile{}, &Error{Code: CodeRuntimeNotFound, Message: "There is no runtime called " + r.RuntimeID + "."}
	}
	if _, ok := accountKinds[r.RuntimeID]; !ok {
		return wire.AccountProfile{}, Invalid("%s keeps one account.", rt.Name)
	}
	name := strings.TrimSpace(r.Name)
	if name == "" {
		return wire.AccountProfile{}, Invalid("Give the account a name.")
	}
	if len([]rune(name)) > 40 {
		return wire.AccountProfile{}, Invalid("Make the name shorter: 40 letters at most.")
	}
	d.accountMu.Lock()
	for _, p := range d.profilesLocked() {
		if p.RuntimeID == r.RuntimeID && strings.EqualFold(p.Name, name) {
			d.accountMu.Unlock()
			return wire.AccountProfile{}, Invalid("%s already has an account called %s.", rt.Name, p.Name)
		}
	}
	if strings.EqualFold(name, "Default") {
		d.accountMu.Unlock()
		return wire.AccountProfile{}, Invalid("Default is the name of %s’s own sign-in. Choose another.", rt.Name)
	}
	id := strings.ToLower(string(store.NewUUID()))
	folder := filepath.Join(d.Store.Loc.Root, "runtimes", "accounts", r.RuntimeID, id)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		d.accountMu.Unlock()
		return wire.AccountProfile{}, err
	}
	p := wire.AccountProfile{ID: id, RuntimeID: r.RuntimeID, Name: name, AddedAt: now(),
		Reach: wire.AccountReach{SignIn: &wire.AccountReachSignIn{Folder: folder}}}
	d.profiles = append(d.profiles, p)
	sort.SliceStable(d.profiles, func(i, j int) bool { return d.profiles[i].RuntimeID < d.profiles[j].RuntimeID })
	err := writeStore(d.accountsPath(), d.profiles)
	d.accountMu.Unlock()
	if err != nil {
		return wire.AccountProfile{}, err
	}
	d.linkShared(p)
	d.readSignIn(&p)
	d.tellAccountProfiles()
	d.tellAllowances()
	return p, nil
}

// removeAccount is runtimes/removeAccount: the agents using it are stopped (as Sign out
// does), the runtime signs it out where it can, and its folder goes.
func (d *Daemon) removeAccount(ctx context.Context, r wire.AccountRequest) ([]wire.UUID, error) {
	p := d.accountProfile(r.RuntimeID, r.AccountID)
	if p == nil {
		return nil, Invalid("There is no such account.")
	}
	if isOrgAccount(p) {
		return nil, Invalid("%s is from your organisation. Only your organisation can remove it.", p.Name)
	}
	stopped := []wire.UUID{}
	for _, a := range d.Store.Agents() {
		if a.RuntimeID == r.RuntimeID && a.AccountID != nil && *a.AccountID == r.AccountID && holdsRuntime(a.State) {
			d.live(a.ID).cancel()
			d.dropLeases(a.ID, "holderStopped")
			d.endWait(a.ID, "stopped", false)
			stopped = append(stopped, a.ID)
		}
	}
	// Signing out takes Claude's Keychain item for the folder away too, where the runtime
	// can sign out at all (its handshake said so): one that cannot is not started for nothing.
	d.allowMu.Lock()
	canLogOut := d.accounts[r.RuntimeID].CanLogOut
	d.allowMu.Unlock()
	if rt := runtimeByID(r.RuntimeID); rt != nil && p.Reach.SignIn != nil && canLogOut {
		lctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		if s, _, err := d.handshakeAs(lctx, r.RuntimeID, p, &probe{commands: make(chan []wire.SlashCommand, 1)}); err == nil {
			if s.CanLogOut() {
				_ = s.LogOut(lctx)
			}
			s.Stop()
		}
		cancel()
	}
	d.accountMu.Lock()
	list := d.profilesLocked()
	kept := list[:0:0]
	for _, q := range list {
		if q.RuntimeID != r.RuntimeID || q.ID != r.AccountID {
			kept = append(kept, q)
		}
	}
	d.profiles = kept
	err := writeStore(d.accountsPath(), d.profiles)
	d.accountMu.Unlock()
	if err != nil {
		return stopped, err
	}
	// Only a folder of the app's own is deleted.
	if folder := accountFolder(*p); strings.HasPrefix(folder, filepath.Join(d.Store.Loc.Root, "runtimes", "accounts")+string(filepath.Separator)) {
		os.RemoveAll(folder)
	}
	d.allowMu.Lock()
	if _, ok := d.allowancesLocked()[accountKey(r.RuntimeID, &r.AccountID)]; ok {
		delete(d.allowances, accountKey(r.RuntimeID, &r.AccountID))
		d.saveAllowancesLocked()
	}
	d.allowMu.Unlock()
	d.tellAccountProfiles()
	d.tellAllowances()
	return stopped, nil
}

// linkShared links the person's own settings into an account's folder, where the folder
// has none of its own: so a second Claude has the person's skills and CLAUDE.md, and only
// its sign-in is its own. Done on every launch, so one added later is found too.
func (d *Daemon) linkShared(p wire.AccountProfile) {
	kind, ok := accountKinds[p.RuntimeID]
	folder := accountFolder(p)
	home := d.personalHome()
	if !ok || folder == "" || home == "" {
		return
	}
	from := filepath.Join(home, kind.defaultFolder)
	if v := os.Getenv(kind.variable); v != "" {
		from = v
	}
	for _, name := range kind.shared {
		src, dst := filepath.Join(from, name), filepath.Join(folder, name)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if _, err := os.Lstat(dst); err == nil {
			continue
		}
		os.Symlink(src, dst)
	}
}

// withAccount is the launch environment for an added account: its folder in the variable,
// and nothing left that would answer before the folder's sign-in.
func withAccount(env []string, p *wire.AccountProfile) []string {
	if p == nil {
		return env
	}
	kind, ok := accountKinds[p.RuntimeID]
	if !ok || accountFolder(*p) == "" {
		return env
	}
	env = without(env, append([]string{kind.variable}, kind.cleared...)...)
	return append(env, kind.variable+"="+accountFolder(*p))
}

// accountKey is the credential an account's allowance is kept under: the runtime's own
// for the Default account, <runtime>:account:<id> for an added one. Only the runtime's own
// is shared with servers (isSharedKey).
func accountKey(runtimeID string, accountID *string) string {
	if accountID == nil || *accountID == "" {
		return ownKey(runtimeID)
	}
	return runtimeID + ":account:" + *accountID
}

// agentKey is the credential an agent's turns spend.
func agentKey(a *wire.Agent) string {
	if a == nil {
		return ""
	}
	return accountKey(a.RuntimeID, a.AccountID)
}

// keyAccount is the added account a credential key is for, or "".
func keyAccount(key string) string {
	_, rest, _ := strings.Cut(key, ":")
	id, ok := strings.CutPrefix(rest, "account:")
	if !ok {
		return ""
	}
	return id
}

// credentialName is how a sentence names a credential: the runtime, and the account's name
// for an added one ("Claude (Work)").
func (d *Daemon) credentialName(key string) string {
	runtime, _, _ := strings.Cut(key, ":")
	name := runtimeName(runtime)
	if id := keyAccount(key); id != "" {
		if p := d.accountProfile(runtime, id); p != nil {
			return name + " (" + p.Name + ")"
		}
	}
	return name
}

// accountUnusable is why an added account cannot be used now, or nil; installed is as
// for unusable.
func (d *Daemon) accountUnusable(p wire.AccountProfile, installed map[string]bool) *string {
	if runtimeByID(p.RuntimeID) == nil {
		s := "not a runtime this app knows"
		return &s
	}
	if !installed[p.RuntimeID] {
		s := "not installed"
		return &s
	}
	if !p.SignedIn {
		s := "not signed in"
		return &s
	}
	return nil
}

func (d *Daemon) registerAccounts() {
	On(d, wire.CallRuntimesAccountProfiles, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.AccountProfile, error) {
		return d.accountProfiles(), nil
	})
	On(d, wire.CallRuntimesAddAccount, func(ctx context.Context, c *Client, r wire.AddAccountRequest) (wire.AccountProfile, error) {
		return d.addAccount(r)
	})
	On(d, wire.CallRuntimesRemoveAccount, func(ctx context.Context, c *Client, r wire.AccountRequest) ([]wire.UUID, error) {
		return d.removeAccount(ctx, r)
	})
	On(d, wire.CallRuntimesSetDefaultAccount, func(ctx context.Context, c *Client, r wire.DefaultAccountRequest) (wire.Empty, error) {
		return wire.Empty{}, d.setDefaultAccount(r)
	})
}
