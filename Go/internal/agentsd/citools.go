package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/wire"
)

// A GitHub repository's CI settings as app tools (#3706, spec 3656): set_ci_secret,
// set_ci_variable and set_environment_gate, written with the person's GitHub connection. For
// set_ci_secret the agent names a session-only secret (#3548), or one in Settings ▸ Secrets,
// and agentsd reads it, seals it to the repository's key and puts it: the value goes in no
// argument, result, transcript or log, so the agent cannot print it.

// ciToolTimeout bounds one call: a gate reads each reviewer, then writes.
const ciToolTimeout = 60 * time.Second

// ciName is a CI secret's or variable's name as GitHub takes it.
var ciName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// ciRepoRef is owner/repo.
var ciRepoRef = regexp.MustCompile(`^[\w.-]+/[\w.-]+$`)

// ciRepo is the repository a call names, or its folder's when it names none, and its GitHub.
func (d *Daemon) ciRepo(caller wire.UUID, args map[string]json.RawMessage, what string) (string, forgeGitHub, error) {
	repo := strings.TrimSuffix(strings.TrimPrefix(strings.TrimSpace(argString(args, "repo")), "https://github.com/"), ".git")
	if repo == "" {
		a := d.Store.Agent(caller)
		if a == nil {
			return "", nil, &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was " + what + "."}
		}
		r := d.folderRepo(folderPath(a))
		if r.forge != "github" {
			return "", nil, Invalid("Nothing was %s: this folder's repository is not on GitHub. Name one in repo, as owner/repo.", what)
		}
		repo = r.path
	}
	if !ciRepoRef.MatchString(repo) {
		return "", nil, Invalid("Nothing was %s: %q is not a GitHub repository. Name it as owner/repo.", what, repo)
	}
	gh, err := d.forgeGitHub()
	if err != nil {
		return "", nil, Invalid("Nothing was %s: this machine has no GitHub connection. Ask me to connect GitHub in Settings ▸ Connectors.", what)
	}
	return repo, gh, nil
}

// ciNameOf is args' name, checked as GitHub checks it.
func ciNameOf(args map[string]json.RawMessage, what string) (string, error) {
	name := strings.TrimSpace(argString(args, "name"))
	if !ciName.MatchString(name) {
		return "", Invalid("Nothing was %s: name is letters, digits and underscores, not starting with a digit, e.g. SENTRY_AUTH_TOKEN.", what)
	}
	if strings.HasPrefix(strings.ToUpper(name), "GITHUB_") {
		return "", Invalid("Nothing was %s: GitHub keeps names that start with GITHUB_ for itself.", what)
	}
	return name, nil
}

// ciWords is a GitHub failure as the agent reads it.
func ciWords(err error, what, repo string) error {
	var ge *githubmcp.GitHubError
	if errors.As(err, &ge) {
		switch {
		case ge.Kind == githubmcp.NotSignedIn:
			return Invalid("Nothing was %s: the GitHub connection has expired. Ask me to connect GitHub again in Settings ▸ Connectors.", what)
		case ge.Kind == githubmcp.RateLimited:
			return Invalid("Nothing was %s: GitHub's rate limit. Try again in a minute.", what)
		case ge.Refused:
			return Invalid("Nothing was %s: GitHub refused it (%s). The GitHub connection may not reach %s, or may not change its settings.", what, ge.Message, repo)
		}
		return Invalid("Nothing was %s: %s", what, ge.Message)
	}
	return Invalid("Nothing was %s: %v", what, err)
}

// setCISecret is set_ci_secret.
func (d *Daemon) setCISecret(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	const what = "set"
	name, err := ciNameOf(args, what)
	if err != nil {
		return "", err
	}
	secret := strings.TrimSpace(argString(args, "secret"))
	if secret == "" {
		secret = name
	}
	if !secretAskName.MatchString(secret) {
		return "", Invalid("Nothing was set: secret is the name of a secret you asked for with ask_secret, e.g. SENTRY_AUTH_TOKEN.")
	}
	// A value that opens only for a signed approval is read after it (#4058).
	released := d.releasePending(caller, secret)
	var v string
	if !released {
		var ok, expired bool
		v, ok, expired = d.localSecret(caller, secret)
		if expired && (!ok || v == "") {
			return "", Invalid("Nothing was set: %s was for this session only and has expired. Ask me for it again with ask_secret.", secret)
		}
		if !ok || v == "" {
			return "", Invalid("Nothing was set: %s is not set. Ask me for it with ask_secret, then call set_ci_secret again.", secret)
		}
	}
	repo, gh, err := d.ciRepo(caller, args, what)
	if err != nil {
		return "", err
	}
	if d.secretIsSealed(caller, secret) {
		// Ask before use (#4015): a person approves it for this repo.
		waiting, err := d.approveSecretUse(caller, secret, wire.SecretUseCi, repo)
		if err != nil {
			return "", Invalid("Nothing was set: %s", err.Error())
		}
		if waiting != "" {
			return waiting, nil
		}
	}
	if released {
		var ok bool
		if v, ok, _ = d.localSecret(caller, secret); !ok || v == "" {
			return "", Invalid("Nothing was set: %s did not open.", secret)
		}
	}
	ctx, cancel := context.WithTimeout(d.ctx, ciToolTimeout)
	defer cancel()
	if err := gh.SetActionsSecret(ctx, repo, name, v); err != nil {
		return "", ciWords(err, what, repo)
	}
	d.secretRead(caller, secret, wire.SecretOperationUseCi, strings.ToLower(repo))
	return name + " is set as a CI secret in " + repo + ", from " + secret + ". Workflows read it as ${{ secrets." + name + " }}.", nil
}

// setCIVariable is set_ci_variable.
func (d *Daemon) setCIVariable(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	const what = "set"
	name, err := ciNameOf(args, what)
	if err != nil {
		return "", err
	}
	var value string
	if json.Unmarshal(args["value"], &value) != nil {
		return "", Invalid("Nothing was set: value is the variable's value, as text.")
	}
	repo, gh, err := d.ciRepo(caller, args, what)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(d.ctx, ciToolTimeout)
	defer cancel()
	replaced, err := gh.SetActionsVariable(ctx, repo, name, value)
	if err != nil {
		return "", ciWords(err, what, repo)
	}
	verb := "made"
	if replaced {
		verb = "changed"
	}
	return name + " is " + verb + " as a CI variable in " + repo + ". Workflows read it as ${{ vars." + name + " }}.", nil
}

// setEnvironmentGate is set_environment_gate.
func (d *Daemon) setEnvironmentGate(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	const what = "changed"
	env := strings.TrimSpace(argString(args, "environment"))
	if env == "" || len(env) > 255 || strings.ContainsAny(env, "/\\") {
		return "", Invalid("Nothing was changed: environment is the environment's name, e.g. production.")
	}
	var reviewers []string
	if raw, ok := args["reviewers"]; ok {
		if json.Unmarshal(raw, &reviewers) != nil {
			return "", Invalid("Nothing was changed: reviewers is a list of GitHub logins, and teams as org/team.")
		}
	}
	var who []string
	for _, r := range reviewers {
		if r = strings.TrimPrefix(strings.TrimSpace(r), "@"); r != "" {
			who = append(who, r)
		}
	}
	if len(who) == 0 || len(who) > 6 {
		return "", Invalid("Nothing was changed: reviewers is 1 to 6 GitHub logins, and teams as org/team.")
	}
	repo, gh, err := d.ciRepo(caller, args, what)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(d.ctx, ciToolTimeout)
	defer cancel()
	if err := gh.SetEnvironmentGate(ctx, repo, env, who); err != nil {
		return "", ciWords(err, what, repo)
	}
	return "A deploy to " + env + " in " + repo + " now waits for one of " + strings.Join(who, ", ") +
		" to approve it. A job takes the gate with environment: " + env + ".", nil
}
