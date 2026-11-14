package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/lineage"
	"github.com/agentloops-dev/agents/Go/internal/repoalias"
	"github.com/agentloops-dev/agents/Go/internal/safe"
)

// Repo aliases (#4957, spec 4929-github-organisation): when a repo's owner moves, such as
// alexec/Agents to agentloops-dev/Agents, the refs stored before the move (lineage, waits,
// workflow triggers) name the old owner and the events after it the new one. GitHub's own
// redirect says the new name: GET /repos/<old> answers with the new full_name. The daemon
// asks it for each GitHub repo its folders and its lineage name, keeps the answers in
// repo-aliases.json, and reads and matches refs by the new name (repoalias). It writes no
// stored file again.

const (
	// repoAliasFirstCheck is how long after the start the first check waits, out of its way.
	repoAliasFirstCheck = 2 * time.Minute
	// repoAliasCheckEvery is how often the repos are asked again.
	repoAliasCheckEvery = 24 * time.Hour
	// repoAliasMostAsked bounds the repos one check asks GitHub about.
	repoAliasMostAsked = 50
	repoAliasAPI       = "https://api.github.com"
)

func (d *Daemon) repoAliasesPath() string { return filepath.Join(d.Store.Loc.Root, "repo-aliases.json") }

// loadRepoAliases reads the book kept; with no file, the book is left as it is.
func (d *Daemon) loadRepoAliases() {
	if _, err := os.Stat(d.repoAliasesPath()); errors.Is(err, os.ErrNotExist) {
		return
	}
	if err := repoalias.Load(d.repoAliasesPath()); err != nil {
		log.Printf("repo aliases: %v; starting with none", err)
	}
}

// StartRepoAliases asks GitHub, a while after the start and then once a day, whether the
// repos the folders and the lineage name moved.
func (d *Daemon) StartRepoAliases() { safe.Go("repo aliases", d.repoAliasClock) }

func (d *Daemon) repoAliasClock() {
	wait := repoAliasFirstCheck
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-time.After(wait):
		}
		d.checkRepoAliases(d.ctx)
		wait = repoAliasCheckEvery
	}
}

// checkRepoAliases asks GitHub about each repo named and keeps each move it says; it says
// how many it added.
func (d *Daemon) checkRepoAliases(ctx context.Context) int {
	added := 0
	for _, repo := range d.githubReposNamed() {
		if ctx.Err() != nil {
			break
		}
		to, err := d.githubFullName(ctx, repo)
		if err != nil {
			log.Printf("repo aliases: %s: %v", repo, err)
			continue
		}
		if to != "" && !strings.EqualFold(to, repo) && repoalias.Add("github", repo, to, nowFunc()) {
			log.Printf("repo aliases: %s moved to %s", repo, to)
			added++
		}
	}
	if added > 0 {
		if err := repoalias.Save(d.repoAliasesPath()); err != nil {
			log.Printf("repo aliases: %v", err)
		}
		if r, ok := d.lineageFiles(); ok {
			r.Realias()
		}
		d.realiasCost()
	}
	return added
}

// lineageFiles is the lineage store under the noting wrapper, when it can name its nodes again.
func (d *Daemon) lineageFiles() (interface{ Realias() }, bool) {
	s := d.lineage()
	if n, ok := s.(notingStore); ok {
		s = n.Store
	}
	r, ok := s.(interface{ Realias() })
	return r, ok
}

// githubReposNamed is each GitHub repo a folder's origin or a lineage node names, lower case,
// once, at most repoAliasMostAsked. A repo known to have moved is asked by its name now, so a
// second move (a to b, then b to c; #5332) is found and the chain ends at the name GitHub has.
func (d *Daemon) githubReposNamed() []string {
	seen := map[string]bool{}
	var out []string
	add := func(repo string) {
		repo = repoalias.Topic("github", strings.ToLower(repo))
		if repo == "" || seen[repo] || !strings.Contains(repo, "/") {
			return
		}
		seen[repo] = true
		out = append(out, repo)
	}
	for _, f := range d.folderPaths() {
		if r := d.folderRepo(f); r.forge == "github" {
			add(r.path)
		}
	}
	links, states := d.lineage().All()
	refs := make([]string, 0, 2*len(links)+len(states))
	for _, l := range links {
		refs = append(refs, l.From.Ref, l.To.Ref)
	}
	for _, s := range states {
		refs = append(refs, s.Node.Ref)
	}
	for _, ref := range refs {
		if len(out) >= repoAliasMostAsked {
			break
		}
		if r, ok := lineage.RefOfText(ref); ok && r.Provider == "github" {
			if r.Type == "repo" && r.Topic == "" {
				add(r.ID)
			} else {
				add(r.Topic)
			}
		}
	}
	if len(out) > repoAliasMostAsked {
		out = out[:repoAliasMostAsked]
	}
	return out
}

// githubFullName is the repo's full_name now, as GitHub answers GET /repos/<repo> (it follows
// a moved repo's redirect); "" when GitHub does not know it.
func (d *Daemon) githubFullName(ctx context.Context, repo string) (string, error) {
	base := d.repoAliasAPI
	if base == "" {
		base = repoAliasAPI
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	owner, _, _ := strings.Cut(repo, "/")
	token, _ := d.githubTokenFor(ctx, owner)
	full, status, err := getFullName(ctx, base, repo, token)
	if err == nil && token != "" && (status == http.StatusNotFound || status == http.StatusUnauthorized || status == http.StatusForbidden) {
		// A bot token for the old owner may not reach the new one; a public repo answers anyone.
		full, status, err = getFullName(ctx, base, repo, "")
	}
	if err != nil {
		return "", err
	}
	switch status {
	case http.StatusOK:
		return full, nil
	case http.StatusNotFound:
		return "", nil
	default:
		return "", fmt.Errorf("GitHub answered %d", status)
	}
}

func getFullName(ctx context.Context, base, repo, token string) (string, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(base, "/")+"/repos/"+repo, nil)
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		return "", resp.StatusCode, nil
	}
	var answer struct {
		FullName string `json:"full_name"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&answer); err != nil {
		return "", 0, err
	}
	return answer.FullName, resp.StatusCode, nil
}
