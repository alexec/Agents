package agentsd

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/wire"
)

// An agent's gh and git as the GitHub App (#3926, spec 3856 §2 and §3). The github MCP
// server already posts with the App's token; an agent's own `gh pr create` and `git push`
// used the person's own gh login, with no App badge. Now a session whose folder the App
// reaches gets:
//
//   - a `gh` first on its PATH that asks this host for the current token at each call and
//     runs the real gh with it in GH_TOKEN, for that one call;
//   - git's credential helper for https://github.com set to `agentsd credential`, which asks
//     the same, in place of the person's own helpers.
//
// The token is the bot's installation token when the person's bot is installed on the
// repository's owner (#3858), else the person's user token of agents-loops. It is never in
// the agent's environment and never in a file: the environment holds only a grant, made
// when the runtime starts and taken back when it ends, that can ask this endpoint and
// nothing else. A session of any length gets a token that is good now, as the host renews
// it (connections/keep.go). A folder the App does not reach keeps the person's own gh and
// git, as before: the App's token would be refused there.

const (
	githubCredentialPath = "/credentials/github"
	// credentialURLEnv and credentialGrantEnv tell `agentsd credential` where to ask.
	credentialURLEnv   = "AGENTS_CREDENTIAL_URL"
	credentialGrantEnv = "AGENTS_CREDENTIAL_GRANT"
	// appReachTTL is how long a read of where the App is installed is kept.
	appReachTTL = 10 * time.Minute
)

type gitCredentialState struct {
	credMu sync.Mutex
	// credGrants is each grant, by the agent it is for.
	credGrants map[string]wire.UUID
	// appReach is whether agents-loops is installed on a repository, by repository.
	appReach map[string]reachRead
	botOnce  sync.Once
	bots     *connections.BotTokens
	// credentialSelf is the agentsd that git and gh run; a test gives a stand-in.
	credentialSelf string
}

type reachRead struct {
	installed bool
	at        time.Time
}

func (d *Daemon) botTokens() *connections.BotTokens {
	d.botOnce.Do(func() {
		d.bots = connections.NewBotTokens(d.connectionLocator())
		d.bots.Client = d.botClient()
	})
	return d.bots
}

// githubTokenFor is the token an agent's gh and git use for owner's repositories: the bot's
// when it is installed on owner, else the person's user token; bot says which.
func (d *Daemon) githubTokenFor(ctx context.Context, owner string) (token string, bot bool) {
	if owner != "" {
		if t, _ := d.botTokens().For(ctx, owner); t != "" {
			return t, true
		}
	}
	c, ok := d.githubConnection()
	if !ok || !c.Usable(time.Now()) {
		return "", false
	}
	return c.Access, false
}

// appReaches is whether agents-loops is installed on repo for the person, kept a while: a
// failed read is a no, so a session starts as before when GitHub is not reached.
func (d *Daemon) appReaches(ctx context.Context, repo, token string) bool {
	key := strings.ToLower(repo)
	d.credMu.Lock()
	r, ok := d.appReach[key]
	d.credMu.Unlock()
	if ok && time.Since(r.at) < appReachTTL {
		return r.installed
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	installed, _, err := d.setupReader(token).AppReach(ctx, repo, connections.GitHubAppSlug)
	if err != nil {
		log.Printf("credentials: could not read where %s is installed: %v", connections.GitHubAppSlug, err)
		installed = false
	}
	d.credMu.Lock()
	if d.appReach == nil {
		d.appReach = map[string]reachRead{}
	}
	d.appReach[key] = reachRead{installed: installed, at: time.Now()}
	d.credMu.Unlock()
	return installed
}

// withGitHubCredential is env for agent's runtime in dir with gh and git asking this host
// for the App's token, or env as it was when the App does not reach dir's repository.
func (d *Daemon) withGitHubCredential(env []string, agent wire.UUID, dir string) []string {
	ctx, cancel := context.WithTimeout(d.ctx, 20*time.Second)
	defer cancel()
	repo, ok := githubmcp.RepoAt(ctx, dir)
	if !ok {
		return env
	}
	owner, _, _ := strings.Cut(repo, "/")
	token, bot := d.githubTokenFor(ctx, owner)
	if token == "" || !bot && !d.appReaches(ctx, repo, token) {
		return env
	}
	self := d.credentialSelf
	if self == "" {
		var err error
		if self, err = os.Executable(); err != nil {
			return env
		}
	}
	port, err := d.startAppTools()
	if err != nil {
		log.Printf("credentials: could not listen: %v", err)
		return env
	}
	grant := string(store.NewUUID())
	d.dropGitHubCredential(agent)
	d.credMu.Lock()
	if d.credGrants == nil {
		d.credGrants = map[string]wire.UUID{}
	}
	d.credGrants[grant] = agent
	d.credMu.Unlock()

	// A token the host itself was started with is the person's, and would win over ours.
	env = without(env, "GH_TOKEN", "GITHUB_TOKEN", credentialURLEnv, credentialGrantEnv)
	env = append(env, credentialURLEnv+"=http://127.0.0.1:"+strconv.Itoa(port)+githubCredentialPath, credentialGrantEnv+"="+grant)
	env = withGitConfig(env,
		// The empty helper first: the person's own helpers, which answer with their own token,
		// are not asked.
		"credential.https://github.com.helper", "",
		"credential.https://github.com.helper", "!"+shellQuote(self)+" credential",
		// So the helper is told the repository, and its owner picks the bot's install.
		"credential.https://github.com.useHttpPath", "true")
	bin := filepath.Join(d.Store.Loc.Root, "runtimes", "github")
	if gh := lookPath(env, "gh", bin); gh != "" {
		if err := writeGHShim(bin, self, gh); err != nil {
			log.Printf("credentials: could not write gh: %v", err)
		} else {
			env = prependPath(env, bin)
		}
	}
	return env
}

// dropGitHubCredential takes back an agent's grant: its runtime has ended.
func (d *Daemon) dropGitHubCredential(agent wire.UUID) {
	d.credMu.Lock()
	defer d.credMu.Unlock()
	for g, a := range d.credGrants {
		if a == agent {
			delete(d.credGrants, g)
		}
	}
}

// serveGitHubCredential answers `agentsd credential`: the current token for the grant's
// agent, as plain text, for the owner asked (?owner=) or else the agent's folder's.
func (d *Daemon) serveGitHubCredential(w http.ResponseWriter, r *http.Request) {
	grant := bearer(r.Header.Get("Authorization"))
	d.credMu.Lock()
	agent, ok := d.credGrants[grant]
	d.credMu.Unlock()
	if grant == "" || !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	owner := r.URL.Query().Get("owner")
	if owner == "" {
		if a := d.Store.Agent(agent); a != nil {
			if repo, ok := githubmcp.RepoAt(r.Context(), store.FolderPath(a.Cwd)); ok {
				owner, _, _ = strings.Cut(repo, "/")
			}
		}
	}
	token, _ := d.githubTokenFor(r.Context(), owner)
	if token == "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = io.WriteString(w, token)
}

// withGitConfig is env with the key and value pairs added to git's configuration, after any
// the environment has already (GIT_CONFIG_COUNT).
func withGitConfig(env []string, pairs ...string) []string {
	n := 0
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "GIT_CONFIG_COUNT="); ok {
			n, _ = strconv.Atoi(v)
		}
	}
	env = without(env, "GIT_CONFIG_COUNT")
	for i := 0; i+1 < len(pairs); i += 2 {
		env = append(env, fmt.Sprintf("GIT_CONFIG_KEY_%d=%s", n, pairs[i]), fmt.Sprintf("GIT_CONFIG_VALUE_%d=%s", n, pairs[i+1]))
		n++
	}
	return append(env, "GIT_CONFIG_COUNT="+strconv.Itoa(n))
}

// lookPath is name's path on env's PATH, or "", skipping the folder skip.
func lookPath(env []string, name, skip string) string {
	for _, kv := range env {
		dirs, ok := strings.CutPrefix(kv, "PATH=")
		if !ok {
			continue
		}
		for _, dir := range filepath.SplitList(dirs) {
			if dir == "" || dir == skip {
				continue
			}
			p := filepath.Join(dir, name)
			if fi, err := os.Stat(p); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
				return p
			}
		}
	}
	return ""
}

// writeGHShim writes bin/gh: the real gh, with the token this host has now in GH_TOKEN for
// that one call. When the host does not answer, gh runs as the person's own login, as before.
func writeGHShim(bin, agentsd, gh string) error {
	if err := os.MkdirAll(bin, 0o700); err != nil {
		return err
	}
	script := "#!/bin/sh\n" +
		"# gh as the GitHub App (#3926): Agents writes this file. The token is asked at each call, never kept.\n" +
		"if token=$(" + shellQuote(agentsd) + " credential token) && [ -n \"$token\" ]; then\n" +
		"\tGH_TOKEN=$token\n\texport GH_TOKEN\n" +
		"fi\n" +
		"exec " + shellQuote(gh) + " \"$@\"\n"
	path := filepath.Join(bin, "gh")
	if old, err := os.ReadFile(path); err == nil && string(old) == script {
		return nil
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(script), 0o700); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
