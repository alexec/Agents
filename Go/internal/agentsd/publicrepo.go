package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/githubmcp"
	"github.com/agentloops-dev/agents/Go/wire"
)

// A public repository as an app tool (#4921): make_public_repository makes a public GitHub
// repository with the person's GitHub connection and pushes a folder's files as its first
// commit. Making something public is the person's choice (AGENTS.md), so nothing is made or
// pushed until the person says yes on the agent's card (personSaysYes), which names the
// repository, the folder and its files. A runtime's own permission check cannot tell that a
// form's answer approved `gh repo create --public`; this tool's card is the approval.
//
// The files are read before the card is shown and kept in memory: a yes pushes the files the
// card counted, not what is in the folder later.

// publicRepoLimits bound what one call reads and pushes.
const (
	publicRepoMaxFiles = 2000
	publicRepoMaxBytes = 50 << 20
)

// publicRepoCardTitle ends the title of make_public_repository's card, after the agent's name.
const publicRepoCardTitle = " wants to make a public repository"

// publicFiles is a folder's files as make_public_repository pushes them.
type publicFiles struct {
	files map[string][]byte
	// exec are the files that can be run.
	exec map[string]bool
	// top are the folder's own entries, the folders with a slash, for the card.
	top []string
}

// makePublicRepository is make_public_repository.
func (d *Daemon) makePublicRepository(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	since := time.Now()
	name := strings.TrimSpace(argString(args, "name"))
	if !ciRepoRef.MatchString("o/"+name) || name == "." || name == ".." {
		return "", Invalid("Nothing was made: name is the repository's name: letters, digits, '.', '-' and '_', e.g. app-starter.")
	}
	owner := strings.TrimPrefix(strings.TrimSpace(argString(args, "owner")), "@")
	if owner != "" && !ciRepoRef.MatchString(owner+"/r") {
		return "", Invalid("Nothing was made: owner is a GitHub login or organisation, or leave it out for the person's own.")
	}
	about := strings.TrimSpace(argString(args, "about"))
	if len(about) > 350 || strings.ContainsAny(about, "\n\r") {
		return "", Invalid("Nothing was made: about is one line of at most 350 characters.")
	}
	var template bool
	if raw, ok := args["template"]; ok && json.Unmarshal(raw, &template) != nil {
		return "", Invalid("Nothing was made: template is true or false.")
	}
	dir, err := publicFolder(argString(args, "folder"))
	if err != nil {
		return "", Invalid("Nothing was made: %v", err)
	}
	if d.Store.Agent(caller) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was made."}
	}
	gh, err := d.forgeGitHub()
	if err != nil {
		return "", Invalid("Nothing was made: this machine has no GitHub connection. Ask me to connect GitHub in Settings ▸ Connectors.")
	}
	got, err := readPublicFiles(dir)
	if err != nil {
		return "", Invalid("Nothing was made: %v", err)
	}
	question := publicRepoQuestion(owner, name, template, dir, got)
	return d.personSaysYesSince(since, caller, d.agentWho(caller)+publicRepoCardTitle, question, "Make it public", func(yes bool) (string, error) {
		if !yes {
			return "Nothing was made or pushed: the person said no, or didn’t answer. Do not make it another way.", nil
		}
		return d.publishRepository(gh, owner, name, about, template, dir, got)
	})
}

// publishRepository is make_public_repository after the person's yes.
func (d *Daemon) publishRepository(gh forgeGitHub, owner, name, about string, template bool, dir string, got publicFiles) (string, error) {
	const what = "made"
	c, _ := d.githubConnection()
	ctx, cancel := context.WithTimeout(d.ctx, ciToolTimeout)
	repo, made, err := gh.MakePublicRepository(ctx, owner, name, about, template)
	cancel()
	if err != nil {
		return "", ciWords(err, what, ownerOr(owner)+"/"+name)
	}
	if !made && repo.Private {
		return "", Invalid("Nothing was pushed: %s is on GitHub already, and private. Its visibility was left as it is.", repo.FullName)
	}
	var done []string
	if made {
		kind := "public"
		if template {
			kind = "public, a template repository"
		}
		done = append(done, "made "+repo.FullName+" on GitHub, "+kind)
	} else {
		done = append(done, repo.FullName+" was on GitHub already, public")
	}
	pushed, err := d.pushPublicFiles(repo, c.Access, got)
	if err != nil {
		return "", Invalid("%s, but %v. Call make_public_repository again to go on from there.", capitalise(strings.Join(done, "; ")), err)
	}
	if pushed {
		done = append(done, fmt.Sprintf("pushed the %d files in %s as its first commit, on main", len(got.files), shortPath(dir)))
	} else {
		done = append(done, "kept what was in it already, and pushed nothing")
	}
	return capitalise(strings.Join(done, "; ")) + ". Anyone can see it at https://github.com/" + repo.FullName + ".", nil
}

// pushPublicFiles clones repo in a staging folder of its own, pushes the files as its first
// commit when it has none, and removes the clone: nothing is kept on this machine.
func (d *Daemon) pushPublicFiles(repo githubmcp.Repository, token string, got publicFiles) (bool, error) {
	staging := filepath.Join(d.Store.Loc.Root, "Clones", string(store.NewUUID()))
	defer os.RemoveAll(staging)
	if err := os.MkdirAll(staging, 0o755); err != nil {
		return false, err
	}
	auth := gitTokenEnv(token)
	staged := filepath.Join(staging, "repo")
	if _, err := newAppGit(staging, auth, "clone", "--", repo.CloneURL, staged); err != nil {
		return false, fmt.Errorf("could not clone it: %v", err)
	}
	write := func(dir string, files map[string][]byte) error { return writePublicFiles(dir, files, got.exec) }
	return firstCommit(staged, auth, repo.Login, repo.UserID, "The first commit", got.files, write)
}

// publicFolder is the folder an agent named: absolute or under ~, there, and neither the home
// folder nor one above it.
func publicFolder(given string) (string, error) {
	given = strings.TrimSpace(given)
	home, _ := os.UserHomeDir()
	if rest, ok := strings.CutPrefix(given, "~/"); ok && home != "" {
		given = filepath.Join(home, rest)
	}
	if given == "" || !filepath.IsAbs(given) {
		return "", errors.New("folder is the folder whose files are the first commit, as an absolute path or under ~/")
	}
	dir := canonical(filepath.Clean(given))
	fi, err := os.Stat(dir)
	if err != nil || !fi.IsDir() {
		return "", fmt.Errorf("%s is not a folder", shortPath(dir))
	}
	if home != "" {
		h := canonical(home)
		if rel, err := filepath.Rel(dir, h); err == nil && !strings.HasPrefix(rel, "..") {
			return "", fmt.Errorf("%s is the home folder or above it; name the one folder to publish", shortPath(dir))
		}
		// Keys and secrets are never published, even with a yes.
		for _, private := range []string{".ssh", ".gnupg", ".agents/secrets"} {
			if rel, err := filepath.Rel(filepath.Join(h, private), dir); err == nil && !strings.HasPrefix(rel, "..") {
				return "", fmt.Errorf("%s holds keys or secrets, which are never published", shortPath(dir))
			}
		}
	}
	return dir, nil
}

// readPublicFiles is every file under dir but .git, within the limits. A link or any other
// file that is not a plain file is refused, as it could point outside the folder.
func readPublicFiles(dir string) (publicFiles, error) {
	got := publicFiles{files: map[string][]byte{}, exec: map[string]bool{}}
	// Each file is read through root, so a link put in its place after the walk saw it
	// cannot reach outside the folder.
	root, err := os.OpenRoot(dir)
	if err != nil {
		return publicFiles{}, err
	}
	defer root.Close()
	total := 0
	err = filepath.WalkDir(dir, func(path string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == dir {
			return nil
		}
		rel, _ := filepath.Rel(dir, path)
		rel = filepath.ToSlash(rel)
		if e.IsDir() {
			if e.Name() == ".git" {
				return filepath.SkipDir
			}
			if !strings.Contains(rel, "/") {
				got.top = append(got.top, rel+"/")
			}
			return nil
		}
		if !e.Type().IsRegular() {
			return fmt.Errorf("%s is a link or a special file, which is not published", rel)
		}
		if len(got.files) == publicRepoMaxFiles {
			return fmt.Errorf("%s has more than %d files", shortPath(dir), publicRepoMaxFiles)
		}
		fi, err := e.Info()
		if err != nil {
			return err
		}
		if total += int(fi.Size()); total > publicRepoMaxBytes {
			return fmt.Errorf("%s has more than %d MB of files", shortPath(dir), publicRepoMaxBytes>>20)
		}
		b, err := root.ReadFile(rel)
		if err != nil {
			return err
		}
		got.files[rel] = b
		got.exec[rel] = fi.Mode()&0o111 != 0
		if !strings.Contains(rel, "/") {
			got.top = append(got.top, rel)
		}
		return nil
	})
	if err != nil {
		return publicFiles{}, err
	}
	if len(got.files) == 0 {
		return publicFiles{}, fmt.Errorf("%s has no files", shortPath(dir))
	}
	sort.Strings(got.top)
	return got, nil
}

// writePublicFiles writes files under dir, each that could be run in the folder still so.
func writePublicFiles(dir string, files map[string][]byte, exec map[string]bool) error {
	for p, b := range files {
		full := filepath.Join(dir, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		if exec[p] {
			mode = 0o755
		}
		if err := os.WriteFile(full, b, mode); err != nil {
			return err
		}
	}
	return nil
}

// publicRepoQuestion is the card's question: where, what kind, and which files.
func publicRepoQuestion(owner, name string, template bool, dir string, got publicFiles) string {
	where := name + " on your GitHub account"
	if owner != "" {
		where = owner + "/" + name
	}
	kind := "a public repository"
	if template {
		kind = "a public template repository"
	}
	top := got.top
	more := ""
	if len(top) > 8 {
		top, more = top[:8], fmt.Sprintf(" and %d more", len(got.top)-8)
	}
	files := "files"
	if len(got.files) == 1 {
		files = "file"
	}
	return fmt.Sprintf("Make %s, %s, with the %d %s in %s (%s%s) as its first commit? Anyone can see it.",
		kind, where, len(got.files), files, shortPath(dir), strings.Join(top, ", "), more)
}
