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
// clones, whether it is private, and the person who made the call, who signs the first commit.
type Repository struct {
	FullName string
	CloneURL string
	Private  bool
	Login    string
	UserID   int64
}

// MakeRepository is owner/name, made private when GitHub has no repository there yet. owner is
// the person's login, or an organisation; empty is the person. made says whether this call made
// it.
func (g *RealGitHub) MakeRepository(ctx context.Context, owner, name, description string) (repo Repository, made bool, err error) {
	return g.makeRepository(ctx, owner, name, map[string]any{"description": description, "private": true})
}

// MakePublicRepository is MakeRepository for a public repository (#4921), a template one when
// template is true. Only make_public_repository calls it, after the person said yes on its card.
// A repository that is there already is only read, private or not.
func (g *RealGitHub) MakePublicRepository(ctx context.Context, owner, name, description string, template bool) (repo Repository, made bool, err error) {
	return g.makeRepository(ctx, owner, name, map[string]any{"description": description, "private": false, "is_template": template})
}

// makeRepository is owner/name, made empty with fields when GitHub has no repository there yet.
func (g *RealGitHub) makeRepository(ctx context.Context, owner, name string, fields map[string]any) (repo Repository, made bool, err error) {
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
		Private  bool   `json:"private"`
	}
	full := owner + "/" + name
	err = g.get(ctx, "repos/"+full, false, &found)
	var ge *GitHubError
	if errors.As(err, &ge) && ge.Kind == NotFound {
		create := "user/repos"
		if !strings.EqualFold(owner, me.Login) {
			create = "orgs/" + url.PathEscape(owner) + "/repos"
		}
		fields["name"], fields["auto_init"] = name, false
		body, _ := json.Marshal(fields)
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
	return Repository{FullName: found.FullName, CloneURL: found.CloneURL, Private: found.Private, Login: me.Login, UserID: me.ID}, made, nil
}
