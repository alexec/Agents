package agentsd

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCodespacesListUsesTheGitHubConnectionAndRepository(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/repos/alexec/agents/codespaces" || r.URL.Query().Get("per_page") != "100" {
			t.Errorf("request %s %s?%s", r.Method, r.URL.Path, r.URL.RawQuery)
		}
		if r.Header.Get("Authorization") != "Bearer test-token" || r.Header.Get("X-GitHub-Api-Version") != "2022-11-28" {
			t.Errorf("headers %v", r.Header)
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"codespaces": []any{map[string]any{
			"name": "silver-space", "display_name": "Silver Space", "state": "Shutdown",
			"repository": map[string]any{"full_name": "alexec/agents"},
			"git_status": map[string]any{"ref": "main"},
		}}})
	}))
	defer server.Close()
	client := newGitHubCodespaces("test-token")
	client.base, client.http = server.URL, server.Client()
	spaces, err := client.List(context.Background(), "alexec/agents")
	if err != nil {
		t.Fatal(err)
	}
	if len(spaces) != 1 || spaces[0].ID != "silver-space" || spaces[0].Name != "Silver Space" ||
		spaces[0].State != "Shutdown" || spaces[0].SSH != "cs.silver-space.main" || spaces[0].Ref == nil || *spaces[0].Ref != "main" {
		t.Fatalf("codespaces: %+v", spaces)
	}
}

func TestCodespacesCreateUsesTheRepositoryDefaultBranch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("authorization header missing")
		}
		if r.Method == http.MethodGet {
			if r.URL.Path != "/repos/alexec/agents" {
				t.Errorf("repository path %s", r.URL.Path)
			}
			json.NewEncoder(w).Encode(map[string]string{"default_branch": "main"})
			return
		}
		if r.Method != http.MethodPost || r.URL.Path != "/repos/alexec/agents/codespaces" {
			t.Errorf("create request %s %s", r.Method, r.URL.Path)
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body["display_name"] != "Alex's Codespace" || body["ref"] != "main" {
			t.Errorf("create body %v, %v", body, err)
		}
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(map[string]any{
			"name": "silver-space", "display_name": "Alex's Codespace", "state": "Queued",
			"repository": map[string]string{"full_name": "alexec/agents"},
			"git_status": map[string]string{"ref": "main"},
		})
	}))
	defer server.Close()
	client := newGitHubCodespaces("test-token")
	client.base, client.http = server.URL, server.Client()
	space, err := client.Create(context.Background(), "alexec/agents", "Alex's Codespace")
	if err != nil {
		t.Fatal(err)
	}
	if space.ID != "silver-space" || space.State != "Queued" || space.SSH != "cs.silver-space.main" {
		t.Fatalf("codespace: %+v", space)
	}
}

func TestCodespacesStartAndStopUseTheCodespaceID(t *testing.T) {
	var methods []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method+" "+r.URL.Path)
		w.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	client := newGitHubCodespaces("test-token")
	client.base, client.http = server.URL, server.Client()
	if err := client.Start(context.Background(), "silver-space"); err != nil {
		t.Fatal(err)
	}
	if err := client.Stop(context.Background(), "silver-space"); err != nil {
		t.Fatal(err)
	}
	if len(methods) != 2 || methods[0] != "POST /user/codespaces/silver-space/start" || methods[1] != "POST /user/codespaces/silver-space/stop" {
		t.Fatalf("requests: %v", methods)
	}
}

func TestCodespacesRepositoryMustBeOwnerAndName(t *testing.T) {
	for _, repository := range []string{"", "owner", "owner/name/extra", "/name", "owner/"} {
		if _, err := repositoryPathFromOwnerName(repository); err == nil {
			t.Errorf("accepted %q", repository)
		}
	}
}

func TestMergeCodespacesSSHConfigKeepsUserConfigAndReplacesOnlyItsBlock(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".ssh", "config")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("Host work\n  HostName work.example\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := mergeCodespacesSSHConfig(path, []byte("Host cs.first.main\n  ProxyCommand gh codespace ssh --stdio")); err != nil {
		t.Fatal(err)
	}
	if err := mergeCodespacesSSHConfig(path, []byte("Host cs.second.main\n  ProxyCommand gh codespace ssh --stdio")); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(contents)
	if !strings.Contains(text, "Host work\n  HostName work.example") || strings.Contains(text, "Host cs.first.main") ||
		!strings.Contains(text, "Host cs.second.main") || strings.Count(text, codespacesSSHBegin) != 1 || strings.Count(text, codespacesSSHEnd) != 1 {
		t.Fatalf("SSH config: %s", text)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("SSH config permissions: %v, %v", info, err)
	}
}

func TestMergeCodespacesSSHConfigRejectsEmptyOutput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	if err := mergeCodespacesSSHConfig(path, nil); err == nil {
		t.Fatal("accepted empty config")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("created file after empty config: %v", err)
	}
}

func TestPrepareSSHUsesTheConnectedGitHubAccount(t *testing.T) {
	root := t.TempDir()
	bin := filepath.Join(root, "bin")
	home := filepath.Join(root, "home")
	if err := os.MkdirAll(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatal(err)
	}
	gh := filepath.Join(bin, "gh")
	script := "#!/bin/sh\n" +
		"if [ \"$1 $2 $3 $4\" = 'api user --jq .login' ]; then echo alexec; exit 0; fi\n" +
		"if [ \"$1 $2 $3\" = 'codespace ssh --config' ]; then echo 'Host cs.test.main'; exit 0; fi\n" +
		"exit 1\n"
	if err := os.WriteFile(gh, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	t.Setenv("HOME", home)
	client := newGitHubCodespaces("test-token")
	if err := client.PrepareSSH(context.Background(), "alexec"); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(filepath.Join(home, ".ssh", "config"))
	if err != nil || !strings.Contains(string(contents), "Host cs.test.main") {
		t.Fatalf("config %q, error %v", contents, err)
	}
	if err := client.PrepareSSH(context.Background(), "someone-else"); err == nil || !strings.Contains(err.Error(), "Sign in to GitHub CLI as someone-else") {
		t.Fatalf("wrong account was not refused: %v", err)
	}
}

var _ codespacesClient = (*githubCodespaces)(nil)
