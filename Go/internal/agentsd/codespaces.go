package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

const codespacesAPI = "https://api.github.com"

type codespacesClient interface {
	List(context.Context, string) ([]wire.ConnectorCodespace, error)
	Create(context.Context, string, string) (wire.ConnectorCodespace, error)
	Start(context.Context, string) error
	Stop(context.Context, string) error
	PrepareSSH(context.Context, string) error
}

type githubCodespaces struct {
	base  string
	token string
	http  *http.Client
}

func newGitHubCodespaces(token string) *githubCodespaces {
	return &githubCodespaces{base: codespacesAPI, token: token, http: &http.Client{Timeout: 25 * time.Second}}
}

func (g *githubCodespaces) List(ctx context.Context, repository string) ([]wire.ConnectorCodespace, error) {
	path, err := repositoryPathFromOwnerName(repository)
	if err != nil {
		return nil, err
	}
	var response struct {
		Codespaces []struct {
			Name        string `json:"name"`
			DisplayName string `json:"display_name"`
			State       string `json:"state"`
			Repository  struct {
				FullName string `json:"full_name"`
			} `json:"repository"`
			GitStatus struct {
				Ref string `json:"ref"`
			} `json:"git_status"`
		} `json:"codespaces"`
	}
	if err := g.request(ctx, http.MethodGet, "/repos/"+path+"/codespaces?per_page=100", nil, &response); err != nil {
		return nil, err
	}
	out := make([]wire.ConnectorCodespace, 0, len(response.Codespaces))
	for _, item := range response.Codespaces {
		if item.Name == "" {
			continue
		}
		branch := item.GitStatus.Ref
		ssh := "cs." + item.Name
		if branch != "" {
			ssh += "." + branch
		}
		name := item.DisplayName
		if name == "" {
			name = item.Name
		}
		repo := item.Repository.FullName
		if repo == "" {
			repo = repository
		}
		var ref *string
		if branch != "" {
			ref = &branch
		}
		out = append(out, wire.ConnectorCodespace{ID: item.Name, Name: name, Repository: repo,
			State: item.State, Ref: ref, SSH: ssh})
	}
	return out, nil
}

func (g *githubCodespaces) Create(ctx context.Context, repository, name string) (wire.ConnectorCodespace, error) {
	path, err := repositoryPathFromOwnerName(repository)
	if err != nil {
		return wire.ConnectorCodespace{}, err
	}
	var repo struct {
		DefaultBranch string `json:"default_branch"`
	}
	if err := g.request(ctx, http.MethodGet, "/repos/"+path, nil, &repo); err != nil {
		return wire.ConnectorCodespace{}, err
	}
	if repo.DefaultBranch == "" {
		return wire.ConnectorCodespace{}, fmt.Errorf("GitHub gave no default branch for %s", repository)
	}
	var result struct {
		Name        string `json:"name"`
		DisplayName string `json:"display_name"`
		State       string `json:"state"`
		Repository  struct {
			FullName string `json:"full_name"`
		} `json:"repository"`
		GitStatus struct {
			Ref string `json:"ref"`
		} `json:"git_status"`
	}
	body := map[string]string{"display_name": name, "ref": repo.DefaultBranch}
	data, _ := json.Marshal(body)
	if err := g.request(ctx, http.MethodPost, "/repos/"+path+"/codespaces", data, &result); err != nil {
		return wire.ConnectorCodespace{}, err
	}
	if result.Name == "" {
		return wire.ConnectorCodespace{}, fmt.Errorf("GitHub made the Codespace but gave no name")
	}
	branch := result.GitStatus.Ref
	if branch == "" {
		branch = repo.DefaultBranch
	}
	ssh := "cs." + result.Name + "." + branch
	displayName := result.DisplayName
	if displayName == "" {
		displayName = name
	}
	fullName := result.Repository.FullName
	if fullName == "" {
		fullName = repository
	}
	return wire.ConnectorCodespace{ID: result.Name, Name: displayName, Repository: fullName,
		State: result.State, Ref: &branch, SSH: ssh}, nil
}

func (g *githubCodespaces) Start(ctx context.Context, id string) error {
	return g.request(ctx, http.MethodPost, "/user/codespaces/"+url.PathEscape(id)+"/start", nil, nil)
}

func (g *githubCodespaces) Stop(ctx context.Context, id string) error {
	return g.request(ctx, http.MethodPost, "/user/codespaces/"+url.PathEscape(id)+"/stop", nil, nil)
}

func (g *githubCodespaces) PrepareSSH(ctx context.Context, login string) error {
	who := exec.CommandContext(ctx, "gh", "api", "user", "--jq", ".login")
	identity, err := who.Output()
	if err != nil || !strings.EqualFold(strings.TrimSpace(string(identity)), login) {
		return fmt.Errorf("Sign in to GitHub CLI as %s to connect this Codespace over SSH", login)
	}
	cmd := exec.CommandContext(ctx, "gh", "codespace", "ssh", "--config")
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("GitHub CLI could not prepare Codespaces SSH access; check that `gh` is installed and signed in")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("Could not find the home folder for SSH configuration")
	}
	return mergeCodespacesSSHConfig(filepath.Join(home, ".ssh", "config"), output)
}

const (
	codespacesSSHBegin = "# BEGIN Agents Codespaces SSH"
	codespacesSSHEnd   = "# END Agents Codespaces SSH"
)

var codespacesSSHConfigMu sync.Mutex

func mergeCodespacesSSHConfig(path string, generated []byte) error {
	config := strings.TrimSpace(string(generated))
	if config == "" {
		return fmt.Errorf("GitHub CLI returned no Codespaces SSH configuration")
	}
	codespacesSSHConfigMu.Lock()
	defer codespacesSSHConfigMu.Unlock()

	current, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("Could not read SSH configuration")
	}
	text := string(current)
	begin, end := strings.Index(text, codespacesSSHBegin), strings.Index(text, codespacesSSHEnd)
	block := codespacesSSHBegin + "\n" + config + "\n" + codespacesSSHEnd
	if begin >= 0 && end >= begin {
		end += len(codespacesSSHEnd)
		text = text[:begin] + block + text[end:]
	} else {
		text = strings.TrimRight(text, "\n")
		if text != "" {
			text += "\n\n"
		}
		text += block + "\n"
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("Could not prepare the SSH configuration folder")
	}
	mode := os.FileMode(0o600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	if err := store.WriteAtomically(path, []byte(text), mode); err != nil {
		return fmt.Errorf("Could not save the Codespaces SSH configuration")
	}
	return nil
}

func (g *githubCodespaces) request(ctx context.Context, method, path string, body []byte, answer any) error {
	if g.token == "" {
		return fmt.Errorf("Connect GitHub to use Codespaces")
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(g.base, "/")+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Authorization", "Bearer "+g.token)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "agents-codespaces")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	client := g.http
	if client == nil {
		client = http.DefaultClient
	}
	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("GitHub Codespaces: %w", err)
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	if err != nil {
		return fmt.Errorf("GitHub Codespaces: %w", err)
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		var problem struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(data, &problem)
		if problem.Message != "" {
			return fmt.Errorf("GitHub Codespaces: %s", problem.Message)
		}
		return fmt.Errorf("GitHub Codespaces returned %s", res.Status)
	}
	if answer != nil && len(data) > 0 {
		if err := json.Unmarshal(data, answer); err != nil {
			return fmt.Errorf("GitHub Codespaces gave an unreadable response")
		}
	}
	return nil
}

func repositoryPathFromOwnerName(repository string) (string, error) {
	owner, name, ok := strings.Cut(repository, "/")
	if !ok || owner == "" || name == "" || strings.Contains(name, "/") {
		return "", fmt.Errorf("The folder repository must be owner/name")
	}
	return url.PathEscape(owner) + "/" + url.PathEscape(name), nil
}

func (d *Daemon) connectorCodespaces(ctx context.Context, request wire.ConnectorCodespacesRequest) (wire.ConnectorCodespaces, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	folder, err := d.setupFolder(string(request.Folder))
	if err != nil {
		return wire.ConnectorCodespaces{}, err
	}
	f, connection, connected := d.forgeAt(ctx, folder)
	if f.provider != wire.ConnectionProviderGithub || f.repo == "" {
		return wire.ConnectorCodespaces{}, invalid("This folder needs a GitHub repository for Codespaces.")
	}
	if !connected || !connection.Usable(time.Now()) {
		return wire.ConnectorCodespaces{}, invalid("Connect GitHub before using Codespaces.")
	}
	client := d.codespacesClient(connection.Access)
	result := wire.ConnectorCodespaces{Repository: &f.repo, Codespaces: []wire.ConnectorCodespace{}}
	if request.Action == "list" {
		result.Codespaces, err = client.List(ctx, f.repo)
		return result, err
	}
	if request.Action == "create" {
		name := strings.TrimSpace(deref(request.Name))
		if name == "" {
			return result, Invalid("Give the new Codespace a name.")
		}
		created, createErr := client.Create(ctx, f.repo, name)
		if createErr != nil {
			return result, createErr
		}
		result.Codespaces = append(result.Codespaces, created)
		return result, nil
	}
	if request.Action == "prepareSSH" {
		if err := client.PrepareSSH(ctx, connection.Login); err != nil {
			return result, err
		}
		result.Codespaces, err = client.List(ctx, f.repo)
		return result, err
	}
	id := strings.TrimSpace(deref(request.ID))
	if id == "" {
		return result, Invalid("Choose a Codespace.")
	}
	spaces, err := client.List(ctx, f.repo)
	if err != nil {
		return result, err
	}
	found := false
	for _, codespace := range spaces {
		found = found || codespace.ID == id
	}
	if !found {
		return result, Invalid("That Codespace is not in this folder's repository.")
	}
	switch request.Action {
	case "start":
		err = client.Start(ctx, id)
	case "stop":
		err = client.Stop(ctx, id)
	default:
		return result, Invalid("Choose list, create, start, stop or prepare SSH.")
	}
	if err != nil {
		return result, err
	}
	result.Codespaces, err = client.List(ctx, f.repo)
	return result, err
}

func (d *Daemon) codespacesClient(token string) codespacesClient {
	if d.newCodespacesClient != nil {
		return d.newCodespacesClient(token)
	}
	return newGitHubCodespaces(token)
}
