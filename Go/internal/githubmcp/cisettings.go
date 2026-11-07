package githubmcp

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"golang.org/x/crypto/nacl/box"
)

// A repository's CI settings (#3706): its Actions secrets and variables, and an environment's
// required reviewers, written as the person with the host's GitHub connection. A secret's value
// is sealed here to the repository's public key (libsodium's sealed box, as GitHub asks), so
// only GitHub's runners can open it.

// mostReviewers is GitHub's limit on an environment's required reviewers.
const mostReviewers = 6

// sealSecret is value sealed to key, GitHub's base64 Curve25519 public key, in base64.
func sealSecret(key, value string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(key)
	if err != nil || len(raw) != 32 {
		return "", &GitHubError{Kind: Failed, Message: "GitHub: the repository's public key is not a Curve25519 key"}
	}
	var pub [32]byte
	copy(pub[:], raw)
	sealed, err := box.SealAnonymous(nil, []byte(value), &pub, rand.Reader)
	if err != nil {
		return "", &GitHubError{Kind: Failed, Message: "GitHub: " + err.Error()}
	}
	return base64.StdEncoding.EncodeToString(sealed), nil
}

// SetActionsSecret makes or replaces repo's Actions secret name with value, sealed to the
// repository's public key. The value is never sent unsealed.
func (g *RealGitHub) SetActionsSecret(ctx context.Context, repo, name, value string) error {
	if _, _, err := ownerName(repo); err != nil {
		return err
	}
	var key struct {
		KeyID string `json:"key_id"`
		Key   string `json:"key"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/actions/secrets/public-key", repo), false, &key); err != nil {
		return err
	}
	sealed, err := sealSecret(key.Key, value)
	if err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]string{"encrypted_value": sealed, "key_id": key.KeyID})
	_, err = g.do(ctx, http.MethodPut, fmt.Sprintf("repos/%s/actions/secrets/%s", repo, url.PathEscape(name)), body, false)
	return err
}

// SetActionsVariable makes or replaces repo's Actions variable name. It says whether the
// variable was there before.
func (g *RealGitHub) SetActionsVariable(ctx context.Context, repo, name, value string) (replaced bool, err error) {
	if _, _, err := ownerName(repo); err != nil {
		return false, err
	}
	body, _ := json.Marshal(map[string]string{"name": name, "value": value})
	_, err = g.do(ctx, http.MethodPatch, fmt.Sprintf("repos/%s/actions/variables/%s", repo, url.PathEscape(name)), body, false)
	var ge *GitHubError
	if !errors.As(err, &ge) || ge.Kind != NotFound {
		return err == nil, err
	}
	_, err = g.do(ctx, http.MethodPost, fmt.Sprintf("repos/%s/actions/variables", repo), body, false)
	return false, err
}

// SetEnvironmentGate makes or changes repo's environment so a deploy to it waits for one of
// reviewers: logins, and teams as org/team.
func (g *RealGitHub) SetEnvironmentGate(ctx context.Context, repo, environment string, reviewers []string) error {
	owner, _, err := ownerName(repo)
	if err != nil {
		return err
	}
	if len(reviewers) == 0 || len(reviewers) > mostReviewers {
		return &GitHubError{Kind: Failed, Message: fmt.Sprintf("GitHub: an environment takes 1 to %d reviewers", mostReviewers)}
	}
	type reviewer struct {
		Type string `json:"type"`
		ID   int64  `json:"id"`
	}
	var ids []reviewer
	for _, who := range reviewers {
		var found struct {
			ID int64 `json:"id"`
		}
		org, team, isTeam := strings.Cut(who, "/")
		if isTeam {
			if !strings.EqualFold(org, owner) {
				return &GitHubError{Kind: Failed, Message: fmt.Sprintf("GitHub: the team %s is not in %s, which owns the repository", who, owner)}
			}
			err = g.get(ctx, fmt.Sprintf("orgs/%s/teams/%s", url.PathEscape(org), url.PathEscape(team)), false, &found)
		} else {
			err = g.get(ctx, "users/"+url.PathEscape(who), false, &found)
		}
		var ge *GitHubError
		if errors.As(err, &ge) && ge.Kind == NotFound {
			return &GitHubError{Kind: NotFound, Message: "GitHub has no user or team " + who, Refused: true}
		}
		if err != nil {
			return err
		}
		kind := "User"
		if isTeam {
			kind = "Team"
		}
		ids = append(ids, reviewer{Type: kind, ID: found.ID})
	}
	body, _ := json.Marshal(map[string]any{"reviewers": ids})
	_, err = g.do(ctx, http.MethodPut, fmt.Sprintf("repos/%s/environments/%s", repo, url.PathEscape(environment)), body, false)
	return err
}
