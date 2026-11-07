package githubmcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

// A new app's repository (#3708): made on GitHub as the person, private, with nothing in it,
// so the host can push a starter as its first commit.

// repoName is a repository's name as GitHub takes it.
var repoName = regexp.MustCompile(`^[A-Za-z0-9._-]{1,100}$`)

// Repository is a repository the person owns or can write: its owner/name, the address git
// clones and the person who made the call, who signs the first commit.
type Repository struct {
	FullName string
	CloneURL string
	Login    string
	UserID   int64
}

// MakeRepository is owner/name, made private when GitHub has no repository there yet. owner is
// the person's login, or an organisation; empty is the person. made says whether this call made
// it.
func (g *RealGitHub) MakeRepository(ctx context.Context, owner, name, description string) (repo Repository, made bool, err error) {
	if !repoName.MatchString(name) || name == "." || name == ".." {
		return Repository{}, false, &GitHubError{Kind: Failed, Message: fmt.Sprintf("GitHub: %q is not a repository name", name), Refused: true}
	}
	var me struct {
		Login string `json:"login"`
		ID    int64  `json:"id"`
	}
	if err := g.get(ctx, "user", false, &me); err != nil {
		return Repository{}, false, err
	}
	if owner == "" {
		owner = me.Login
	}
	var found struct {
		FullName string `json:"full_name"`
		CloneURL string `json:"clone_url"`
	}
	full := owner + "/" + name
	err = g.get(ctx, "repos/"+full, false, &found)
	var ge *GitHubError
	if errors.As(err, &ge) && ge.Kind == NotFound {
		create := "user/repos"
		if !strings.EqualFold(owner, me.Login) {
			create = "orgs/" + url.PathEscape(owner) + "/repos"
		}
		body, _ := json.Marshal(map[string]any{"name": name, "description": description, "private": true, "auto_init": false})
		var b []byte
		if b, err = g.do(ctx, http.MethodPost, create, body, false); err == nil {
			if json.Unmarshal(b, &found) != nil {
				err = &GitHubError{Kind: Failed, Message: "GitHub: the new repository's answer was not JSON"}
			}
		}
		made = err == nil
	}
	if err != nil {
		return Repository{}, false, err
	}
	if found.FullName == "" || found.CloneURL == "" {
		return Repository{}, false, &GitHubError{Kind: Failed, Message: fmt.Sprintf("GitHub gave no address for %s", full)}
	}
	return Repository{FullName: found.FullName, CloneURL: found.CloneURL, Login: me.Login, UserID: me.ID}, made, nil
}
