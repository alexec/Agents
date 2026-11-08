package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/wire"
)

func (f *fakeForgeGitHub) SetActionsSecret(_ context.Context, repo, name, value string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.wrote = append(f.wrote, "secret "+repo+" "+name+"="+value)
	return nil
}

func (f *fakeForgeGitHub) SetActionsVariable(_ context.Context, repo, name, value string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if repo == "alexec/private" {
		return false, &githubmcp.GitHubError{Kind: githubmcp.Failed, Message: "GitHub: HTTP 403", Refused: true}
	}
	f.wrote = append(f.wrote, "variable "+repo+" "+name+"="+value)
	return name == "OLD", nil
}

func (f *fakeForgeGitHub) SetEnvironmentGate(_ context.Context, repo, environment string, reviewers []string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.wrote = append(f.wrote, "gate "+repo+" "+environment+" "+strings.Join(reviewers, ","))
	return nil
}

func ciArgs(kv ...any) map[string]json.RawMessage {
	args := map[string]json.RawMessage{}
	for i := 0; i+1 < len(kv); i += 2 {
		b, _ := json.Marshal(kv[i+1])
		args[kv[i].(string)] = b
	}
	return args
}

// #3706: set_ci_secret puts a session-only secret into the folder's repo, by name, and its
// value is in no result; set_ci_variable and set_environment_gate write what they are given;
// each refuses what GitHub would refuse before it asks GitHub.
func TestTheCIToolsWriteTheRepositorysSettings(t *testing.T) {
	d, _, gh, _ := forgeDaemon(t)
	a := seeded(t, d, gitFolder(t, "git@github.com:alexec/newapp.git"), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	for _, name := range []string{"set_ci_secret", "set_ci_variable", "set_environment_gate"} {
		if !appToolServed(name) {
			t.Errorf("%s is not served", name)
		}
	}
	const value = "sntrys_3706-not-real"
	if err := d.setSessionSecret(a.ID, "SENTRY_TOKEN", value, false); err != nil {
		t.Fatal(err)
	}

	got, err := d.setCISecret(a.ID, ciArgs("name", "SENTRY_AUTH_TOKEN", "secret", "SENTRY_TOKEN"))
	if err != nil || strings.Contains(got, value) || !strings.Contains(got, "SENTRY_AUTH_TOKEN is set as a CI secret in alexec/newapp") {
		t.Fatalf("%q %v", got, err)
	}
	if _, err := d.setCISecret(a.ID, ciArgs("name", "MISSING")); err == nil || !strings.Contains(err.Error(), "ask_secret") {
		t.Fatalf("missing: %v", err)
	}
	if _, err := d.setCISecret(a.ID, ciArgs("name", "GITHUB_TOKEN", "secret", "SENTRY_TOKEN")); err == nil {
		t.Fatal("GITHUB_ was taken")
	}

	if got, err := d.setCIVariable(a.ID, ciArgs("name", "GCP_DEPLOY_SA", "value", "deploy@p.iam.gserviceaccount.com")); err != nil || !strings.Contains(got, "made") {
		t.Fatalf("%q %v", got, err)
	}
	if got, err := d.setCIVariable(a.ID, ciArgs("repo", "alexec/other", "name", "OLD", "value", "")); err != nil || !strings.Contains(got, "changed as a CI variable in alexec/other") {
		t.Fatalf("%q %v", got, err)
	}
	if _, err := d.setCIVariable(a.ID, ciArgs("name", "NOVALUE")); err == nil {
		t.Fatal("a variable with no value was taken")
	}
	if _, err := d.setCIVariable(a.ID, ciArgs("repo", "alexec/private", "name", "X", "value", "1")); err == nil || !strings.Contains(err.Error(), "may not reach alexec/private") {
		t.Fatalf("refused: %v", err)
	}

	if got, err := d.setEnvironmentGate(a.ID, ciArgs("environment", "app-store", "reviewers", []string{"@alexec", "alexec/release"})); err != nil || !strings.Contains(got, "app-store") {
		t.Fatalf("%q %v", got, err)
	}
	if _, err := d.setEnvironmentGate(a.ID, ciArgs("environment", "app-store", "reviewers", []string{})); err == nil {
		t.Fatal("a gate with nobody was taken")
	}
	if _, err := d.setEnvironmentGate(a.ID, ciArgs("environment", "app-store", "reviewers", []string{"a", "b", "c", "d", "e", "f", "g"})); err == nil {
		t.Fatal("seven reviewers were taken")
	}

	gh.mu.Lock()
	wrote := fmt.Sprint(gh.wrote)
	gh.mu.Unlock()
	want := "[secret alexec/newapp SENTRY_AUTH_TOKEN=" + value + " variable alexec/newapp GCP_DEPLOY_SA=deploy@p.iam.gserviceaccount.com variable alexec/other OLD= gate alexec/newapp app-store alexec,alexec/release]"
	if wrote != want {
		t.Fatalf("wrote %s", wrote)
	}
}

// With no GitHub connection the tools say so, and the brief names none of them.
func TestTheCIToolsNeedGitHub(t *testing.T) {
	d, _, _, file := forgeDaemon(t)
	file.Delete(connections.GitHub)
	a := seeded(t, d, gitFolder(t, "git@github.com:alexec/newapp.git"), nil)
	if _, err := d.setCIVariable(a.ID, ciArgs("name", "X", "value", "1")); err == nil || !strings.Contains(err.Error(), "no GitHub connection") {
		t.Fatalf("%v", err)
	}
	if d.hasGitHub() {
		t.Fatal("hasGitHub with no connection")
	}
}
