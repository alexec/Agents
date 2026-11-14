package agentsd

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A new app's repository as an app tool (#3708, spec 3656): make_app_repository makes a
// private GitHub repository with the person's GitHub connection, pushes a starter (#3707) as
// its first commit, clones it on this machine and adds it as a folder, so it shows in the
// session list on every client. A step that is done already is skipped, so the agent can call
// it again after a step failed.

// newAppGitTimeout bounds one git command: a clone of a new repository, or the starter's push.
const newAppGitTimeout = 5 * time.Minute

// makeAppRepository is make_app_repository.
func (d *Daemon) makeAppRepository(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	const what = "made"
	name := strings.TrimSpace(argString(args, "name"))
	if !ciRepoRef.MatchString("o/"+name) || name == "." || name == ".." {
		return "", Invalid("Nothing was made: name is the repository's name: letters, digits, '.', '-' and '_', e.g. tide-log.")
	}
	starter := strings.TrimSpace(argString(args, "starter"))
	starterRef, ok := starterRepo(starter)
	if !ok {
		return "", Invalid("Nothing was made: starter is a template repository, owner/name, or one of ours: %s.", starterShortList())
	}
	values := map[string]string{}
	if raw, ok := args["values"]; ok && json.Unmarshal(raw, &values) != nil {
		return "", Invalid("Nothing was made: values is an object of the starter's placeholders, e.g. {\"APP_NAME\": \"Tide Log\"}.")
	}
	owner := strings.TrimPrefix(strings.TrimSpace(argString(args, "owner")), "@")
	if owner != "" && !ciRepoRef.MatchString(owner+"/r") {
		return "", Invalid("Nothing was made: owner is a GitHub login or organisation, or leave it out for the person's own.")
	}
	if d.Store.Agent(caller) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was made."}
	}
	gh, err := d.forgeGitHub()
	if err != nil {
		return "", Invalid("Nothing was made: this machine has no GitHub connection. Ask me to connect GitHub in Settings ▸ Connectors.")
	}
	c, _ := d.githubConnection()
	token := c.Access

	// The starter is fetched before anything is made, so its missing values are refused first.
	// GITHUB_REPO is the repository's own name, which the app knows; the rest are the agent's.
	raw, err := fetchStarter(starterRef, token)
	if err != nil {
		return "", Invalid("Nothing was made: %v.", err)
	}
	values["GITHUB_REPO"] = "owner/" + name
	if missing := starterMissing(raw, values); len(missing) > 0 {
		return "", Invalid("Nothing was made: the %s starter needs %s. It takes values for %s.", starter,
			strings.Join(missing, ", "), strings.Join(withoutRepo(starterPlaceholders(raw)), ", "))
	}

	ctx, cancel := context.WithTimeout(d.ctx, ciToolTimeout)
	repo, made, err := gh.MakeRepository(ctx, owner, name, values["APP_NAME"])
	cancel()
	if err != nil {
		return "", ciWords(err, what, ownerOr(owner)+"/"+name)
	}
	var done []string
	if made {
		done = append(done, "made "+repo.FullName+" on GitHub, private")
	} else {
		done = append(done, repo.FullName+" was on GitHub already")
	}
	values["GITHUB_REPO"] = repo.FullName
	files, err := fillStarter(raw, values)
	if err != nil {
		return "", Invalid("Nothing more was made: %v", err)
	}
	remote, ok := parseRemote(repo.CloneURL)
	if !ok {
		return "", Invalid("Nothing more was made: GitHub gave %q as the address to clone, which git cannot use.", repo.CloneURL)
	}

	dest := filepath.Join(canonical(cloneParent()), remote.folderName)
	if _, err := os.Stat(dest); err == nil {
		s, err := d.adoptClone(dest, remote)
		if err != nil {
			return "", Invalid("%s, but %v", capitalise(strings.Join(done, "; ")), err)
		}
		done = append(done, shortPath(store.FolderPath(s.Folder.Folder))+" was cloned already, and is a folder")
		return newAppSaid(done), nil
	}
	pushed, err := d.cloneNewApp(repo.CloneURL, dest, token, repo.Login, repo.UserID, files)
	if err != nil {
		return "", Invalid("%s, but %v. Call make_app_repository again to go on from there.", capitalise(strings.Join(done, "; ")), err)
	}
	if pushed {
		done = append(done, "pushed the "+starter+" starter as its first commit, on main")
	} else {
		done = append(done, "kept what was in it already, with no starter")
	}
	s, err := d.addFolder(store.FolderURL(dest))
	if err != nil {
		return "", Invalid("%s, and cloned it to %s, but it is not a folder: %v", capitalise(strings.Join(done, "; ")), shortPath(dest), err)
	}
	done = append(done, "cloned it to "+shortPath(store.FolderPath(s.Folder.Folder))+" and added it as a folder")
	return newAppSaid(done), nil
}

// cloneNewApp clones cloneURL to dest with the GitHub connection's token, and when the
// repository has no commit yet pushes files as its first, on main. The token goes to git in
// its environment, not its arguments or the clone's config, so neither ps nor the folder has
// it. It says whether it pushed.
func (d *Daemon) cloneNewApp(cloneURL, dest, token, login string, userID int64, files map[string][]byte) (bool, error) {
	d.cloneMu.Lock()
	if d.clones == nil {
		d.clones = map[string]wire.CloneSummary{}
	}
	if _, busy := d.clones[dest]; busy {
		d.cloneMu.Unlock()
		return false, errors.New(shortPath(dest) + " is already being cloned")
	}
	c := wire.CloneSummary{ID: store.NewUUID(), URL: cloneURL, Folder: store.FolderURL(dest), StartedAt: now()}
	d.clones[dest] = c
	d.cloneMu.Unlock()
	Broadcast(d, wire.NotifyCloneChanged, wire.CloneNotification{Clone: c, Finished: false})
	staging := filepath.Join(d.Store.Loc.Root, "Clones", string(c.ID))
	defer func() {
		os.RemoveAll(staging)
		d.cloneMu.Lock()
		delete(d.clones, dest)
		d.cloneMu.Unlock()
		Broadcast(d, wire.NotifyCloneChanged, wire.CloneNotification{Clone: c, Finished: true})
	}()
	if err := os.MkdirAll(staging, 0o755); err != nil {
		return false, err
	}
	staged := filepath.Join(staging, filepath.Base(dest))
	auth := gitTokenEnv(token)
	if _, err := newAppGit(staging, auth, "clone", "--", cloneURL, staged); err != nil {
		return false, fmt.Errorf("could not clone it: %v", err)
	}
	pushed, err := firstCommit(staged, auth, login, userID, "The starter", files, writeStarter)
	if err != nil {
		return false, err
	}
	if _, err := os.Stat(dest); err == nil {
		return pushed, errors.New(shortPath(dest) + " appeared while the clone ran, and nothing in it was changed")
	}
	if err := os.Rename(staged, dest); err != nil {
		return pushed, fmt.Errorf("could not move the clone to %s: %v", shortPath(dest), err)
	}
	return pushed, nil
}

// gitTokenEnv is the environment that gives git the GitHub token for github.com: in a header,
// so it is in neither git's arguments nor the clone's config.
func gitTokenEnv(token string) []string {
	return []string{"GIT_TERMINAL_PROMPT=0", "GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=http.https://github.com/.extraheader",
		"GIT_CONFIG_VALUE_0=AUTHORIZATION: basic " + base64.StdEncoding.EncodeToString([]byte("x-access-token:"+token))}
}

// firstCommit pushes files as the first commit on main, with message, of staged, a clone, when the repository
// has no branch yet: write puts them in the clone. It says whether it pushed; a repository with
// commits keeps them.
func firstCommit(staged string, auth []string, login string, userID int64, message string, files map[string][]byte, write func(string, map[string][]byte) error) (bool, error) {
	if branches, err := newAppGit(staged, nil, "for-each-ref", "--count=1", "refs/remotes/origin"); err != nil || branches != "" {
		return false, nil
	}
	if err := write(staged, files); err != nil {
		return false, fmt.Errorf("could not write the files: %v", err)
	}
	email := fmt.Sprintf("%d+%s@users.noreply.github.com", userID, login)
	who := []string{"GIT_AUTHOR_NAME=" + login, "GIT_AUTHOR_EMAIL=" + email, "GIT_COMMITTER_NAME=" + login, "GIT_COMMITTER_EMAIL=" + email}
	for _, step := range [][]string{
		{"symbolic-ref", "HEAD", "refs/heads/main"},
		{"add", "-A"},
		{"-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", message},
	} {
		if _, err := newAppGit(staged, who, step...); err != nil {
			return false, fmt.Errorf("could not commit the files: %v", err)
		}
	}
	if _, err := newAppGit(staged, auth, "push", "-u", "origin", "main"); err != nil {
		return false, fmt.Errorf("could not push the first commit: %v", err)
	}
	return true, nil
}

// writeStarter writes files under dir; a shell script can be run.
func writeStarter(dir string, files map[string][]byte) error {
	paths := make([]string, 0, len(files))
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		full := filepath.Join(dir, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(p, ".sh") {
			mode = 0o755
		}
		if err := os.WriteFile(full, files[p], mode); err != nil {
			return err
		}
	}
	return nil
}

// newAppGit runs git in dir with env, for longer than git's usual deadline: a clone or a push
// goes over the network.
func newAppGit(dir string, env []string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), newAppGitTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), env...)
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return "", errors.New("git is not installed on this machine")
		}
		lines := strings.Split(strings.TrimSpace(errOut.String()), "\n")
		if msg := strings.TrimSpace(strings.TrimPrefix(lines[len(lines)-1], "fatal: ")); msg != "" {
			return "", errors.New(msg)
		}
		return "", errors.New("git failed")
	}
	return strings.TrimSpace(out.String()), nil
}

// newAppSaid is what make_app_repository did, in one sentence for the agent.
func newAppSaid(done []string) string {
	return capitalise(strings.Join(done, "; ")) + ". It shows in the session list on every client."
}

func capitalise(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

func ownerOr(owner string) string {
	if owner == "" {
		return "your account"
	}
	return owner
}

// withoutRepo is a starter's placeholders less GITHUB_REPO, which the app fills itself.
func withoutRepo(names []string) []string {
	var out []string
	for _, n := range names {
		if n != "GITHUB_REPO" {
			out = append(out, n)
		}
	}
	return out
}
