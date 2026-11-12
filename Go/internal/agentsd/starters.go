package agentsd

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Starters for a new app (#3707, #4561, specs/3656-new-app/spec.md): a starter is a GitHub
// template repository, such as alexec/iphone-app-starter (TestFlight and the App Store) or
// alexec/web-service-starter (Cloud Run), each with its deploy workflows, the deploy notice
// that Lineage reads and Sentry's SDK. make_app_repository fetches its default branch, fills
// its placeholders and pushes the result as the new repository's first commit. A file names
// what the person chose with a placeholder, __NAME__ in capitals, such as __BUNDLE_ID__.
//
// A template's .starterignore names, one path a line, the files that are the template's own,
// not the app's: its CI, which builds it with sample values, and its .github/README.md, which
// GitHub shows on the template's page in place of the app's README.md.

// starterShortNames are our starters, by the short names the tool takes.
var starterShortNames = map[string]string{
	"iphone-app":  "alexec/iphone-app-starter",
	"web-service": "alexec/web-service-starter",
}

// starterGitBase is where a starter's repository is cloned from: GitHub, or a folder of bare
// repositories in a test.
var starterGitBase = "https://github.com"

// starterMaxBytes bounds a starter's files, so a large repository named as a starter is
// refused rather than read into memory.
const starterMaxBytes = 32 << 20

var starterPlaceholder = regexp.MustCompile(`__[A-Z][A-Z0-9_]*__`)

// starterRepo is the repository of a starter: a short name, or owner/name.
func starterRepo(starter string) (string, bool) {
	if repo, ok := starterShortNames[starter]; ok {
		return repo, true
	}
	owner, name, _ := strings.Cut(starter, "/")
	dots := func(s string) bool { return strings.Trim(s, ".") == "" }
	return starter, ciRepoRef.MatchString(starter) && !dots(owner) && !dots(name)
}

// starterShortList is the short names, sorted, for a message.
func starterShortList() string {
	names := make([]string, 0, len(starterShortNames))
	for n, repo := range starterShortNames {
		names = append(names, n+" ("+repo+")")
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

// fetchStarter is the files of repo's default branch, by path, less .git and what its
// .starterignore names. token, when there is one, reads a private template.
func fetchStarter(repo, token string) (map[string][]byte, error) {
	dir, err := os.MkdirTemp("", "agents-starter-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	var auth []string
	if token != "" {
		auth = []string{"GIT_TERMINAL_PROMPT=0", "GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=http.https://github.com/.extraheader",
			"GIT_CONFIG_VALUE_0=AUTHORIZATION: basic " + base64.StdEncoding.EncodeToString([]byte("x-access-token:"+token))}
	} else {
		auth = []string{"GIT_TERMINAL_PROMPT=0"}
	}
	clone := filepath.Join(dir, "starter")
	if _, err := newAppGit(dir, auth, "clone", "-q", "--depth=1", "--", starterGitBase+"/"+repo+".git", clone); err != nil {
		return nil, fmt.Errorf("could not fetch the starter %s: %v", repo, err)
	}
	files := map[string][]byte{}
	total := 0
	err = filepath.WalkDir(clone, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		if total += len(b); total > starterMaxBytes {
			return fmt.Errorf("the starter %s is more than %d MB", repo, starterMaxBytes>>20)
		}
		rel, _ := filepath.Rel(clone, p)
		files[filepath.ToSlash(rel)] = b
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("the starter %s has no files", repo)
	}
	return withoutStarterIgnored(files), nil
}

// withoutStarterIgnored is files less .starterignore and the paths it names.
func withoutStarterIgnored(files map[string][]byte) map[string][]byte {
	ignore, ok := files[".starterignore"]
	if !ok {
		return files
	}
	delete(files, ".starterignore")
	sc := bufio.NewScanner(bytes.NewReader(ignore))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.Trim(line, "/")
		for p := range files {
			if p == line || strings.HasPrefix(p, line+"/") {
				delete(files, p)
			}
		}
	}
	return files
}

// starterText is whether a file is text, so its placeholders are filled. An image is not.
func starterText(b []byte) bool { return bytes.IndexByte(b, 0) < 0 }

// starterPlaceholders is the placeholders a starter's files use, without the underscores and
// sorted: APP_NAME, BUNDLE_ID.
func starterPlaceholders(files map[string][]byte) []string {
	seen := map[string]bool{}
	for _, b := range files {
		if !starterText(b) {
			continue
		}
		for _, m := range starterPlaceholder.FindAll(b, -1) {
			seen[strings.Trim(string(m), "_")] = true
		}
	}
	names := make([]string, 0, len(seen))
	for n := range seen {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// starterMissing is the placeholders that values has no value for.
func starterMissing(files map[string][]byte, values map[string]string) []string {
	var missing []string
	for _, n := range starterPlaceholders(files) {
		if values[n] == "" {
			missing = append(missing, n)
		}
	}
	return missing
}

// fillStarter is files with each placeholder filled from values (keyed without the
// underscores). A placeholder with no value is an error, so a repository never gets a file
// that still says __BUNDLE_ID__.
func fillStarter(files map[string][]byte, values map[string]string) (map[string][]byte, error) {
	if missing := starterMissing(files, values); len(missing) > 0 {
		return nil, fmt.Errorf("the starter needs %s", strings.Join(missing, ", "))
	}
	out := make(map[string][]byte, len(files))
	for p, b := range files {
		if starterText(b) {
			b = starterPlaceholder.ReplaceAllFunc(b, func(m []byte) []byte {
				return []byte(values[strings.Trim(string(m), "_")])
			})
		}
		out[p] = b
	}
	return out, nil
}
