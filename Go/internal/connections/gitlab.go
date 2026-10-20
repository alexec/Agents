package connections

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// GitLab is the third provider (#1630): gitlab.com by the device flow, or any GitLab (a
// self-managed one too) by a personal access token, which has no refresh.
const GitLab = "gitlab"

// The Agents OAuth application on gitlab.com (#1630, made under the agentstest account). A
// non-confidential application: the device flow needs no client secret, at sign-in or at
// refresh, so there is none. The application ID is public.
const (
	GitLabClientID = "bc94bdfe92adcbee709d4ed637b84c1604bd06aa3098f4aef0b4839004fef52d"
	// GitLabCom is gitlab.com's root. A self-managed GitLab has no Agents application: it
	// signs in with a personal access token.
	GitLabCom = "https://gitlab.com/"
	// GitLabScope: read and write the API as the person (merge requests, pipelines, issues and
	// their comments). GitLab has no narrower scope that comments.
	GitLabScope = "api"
)

// NewGitLabFlow is the device flow for the Agents application on gitlab.com.
func NewGitLabFlow() *DeviceFlow {
	return &DeviceFlow{ClientID: GitLabClientID, Name: "GitLab", Base: GitLabCom, API: GitLabCom + "api/v4/",
		CodePath: "oauth/authorize_device", TokenPath: "oauth/token", UserPath: "user", Scope: GitLabScope,
		HTTP: &http.Client{Timeout: 30 * time.Second}}
}

// GitLabRoot is the address the person typed as a GitLab's root with a trailing slash:
// https:// when it names no scheme, without /api/v4 on the end. http is taken only for this
// machine (a fake in a walk), so a token never crosses the network in the clear.
func GitLabRoot(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return GitLabCom, nil
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("that is not a GitLab address")
	}
	switch u.Scheme {
	case "https":
	case "http":
		if host := u.Hostname(); host != "localhost" && !isLoopback(host) {
			return "", errors.New("a GitLab address starts with https://")
		}
	default:
		return "", errors.New("a GitLab address starts with https://")
	}
	path := strings.TrimSuffix(strings.TrimSuffix(u.Path, "/"), "/api/v4")
	return u.Scheme + "://" + u.Host + strings.TrimSuffix(path, "/") + "/", nil
}

func isLoopback(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// IsGitLabCom is root gitlab.com's.
func IsGitLabCom(root string) bool { return root == "" || root == GitLabCom }

// GitLabToken is what a personal access token reaches: its account, and when it ends (zero
// when it does not, or GitLab did not say).
type GitLabToken struct {
	Login     string
	ExpiresAt time.Time
}

// CheckGitLabToken asks the GitLab at root whose token this is, and when it ends. The token
// goes only in the Authorization header; an error never holds it.
func CheckGitLabToken(ctx context.Context, client *http.Client, root, token string) (GitLabToken, error) {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	login, err := accountName(ctx, client, "GitLab", root+"api/v4/user", token)
	if err != nil {
		return GitLabToken{}, err
	}
	t := GitLabToken{Login: login}
	// Best effort: an OAuth token or an older GitLab has no answer here, and the token is good
	// without one.
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, root+"api/v4/personal_access_tokens/self", nil)
	if err != nil {
		return t, nil
	}
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := client.Do(req)
	if err != nil {
		return t, nil
	}
	defer res.Body.Close()
	var self struct {
		ExpiresAt string `json:"expires_at"`
	}
	if res.StatusCode == http.StatusOK && json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&self) == nil && self.ExpiresAt != "" {
		// GitLab gives a day: the token works to the end of it, in UTC.
		if day, err := time.Parse("2006-01-02", self.ExpiresAt); err == nil {
			t.ExpiresAt = day.Add(24 * time.Hour)
		}
	}
	return t, nil
}

// GitLabConnection is the connection a personal access token makes on the GitLab at root.
// Workspace is the GitLab's host when it is not gitlab.com, for the row to say which.
func GitLabConnection(root, token string, t GitLabToken, at time.Time) Connection {
	c := Connection{Provider: GitLab, Login: t.Login, Access: token, AccessExpiresAt: t.ExpiresAt, ConnectedAt: at}
	if !IsGitLabCom(root) {
		c.URL = root
		if u, err := url.Parse(root); err == nil {
			c.Workspace = u.Host
		}
	}
	return c
}
