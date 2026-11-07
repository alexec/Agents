package agentsd

import (
	"bytes"
	"embed"
	"fmt"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strings"
)

// Starters for a new app (#3707, specs/3656-new-app/spec.md): an iPhone app and a web service,
// each with its deploy workflows, the deploy notice that Lineage reads and Sentry's SDK. The
// agent that makes a person's repository pushes one. A file names what the person chose with a
// placeholder, __NAME__ in capitals, such as __BUNDLE_ID__ or __SERVICE__.
//
// all: keeps the files whose names start with a dot, such as .github/workflows.
//
//go:embed all:templates
var startersFS embed.FS

var starterPlaceholder = regexp.MustCompile(`__[A-Z][A-Z0-9_]*__`)

// starterIDs is every starter, by id: iphone-app and web-service.
func starterIDs() []string {
	entries, _ := startersFS.ReadDir("templates")
	var ids []string
	for _, e := range entries {
		if e.IsDir() {
			ids = append(ids, e.Name())
		}
	}
	return ids
}

// starterRaw is a starter's files by path, as embedded.
func starterRaw(id string) (map[string][]byte, error) {
	root := path.Join("templates", id)
	if !starterKnown(id) {
		return nil, fmt.Errorf("no starter %q: use one of %s", id, strings.Join(starterIDs(), ", "))
	}
	files := map[string][]byte{}
	err := fs.WalkDir(startersFS, root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := startersFS.ReadFile(p)
		files[strings.TrimPrefix(p, root+"/")] = b
		return err
	})
	return files, err
}

func starterKnown(id string) bool {
	for _, known := range starterIDs() {
		if known == id {
			return true
		}
	}
	return false
}

// starterText is whether a file is text, so its placeholders are filled. An image is not.
func starterText(b []byte) bool { return bytes.IndexByte(b, 0) < 0 }

// starterPlaceholders is the placeholders a starter's files use, without the underscores and
// sorted: APP_NAME, BUNDLE_ID.
func starterPlaceholders(id string) ([]string, error) {
	files, err := starterRaw(id)
	if err != nil {
		return nil, err
	}
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
	return names, nil
}

// starterFiles is a starter's files by path, with each placeholder filled from values (keyed
// without the underscores). A placeholder with no value is an error, so a repository never gets
// a file that still says __BUNDLE_ID__.
func starterFiles(id string, values map[string]string) (map[string][]byte, error) {
	names, err := starterPlaceholders(id)
	if err != nil {
		return nil, err
	}
	var missing []string
	for _, n := range names {
		if values[n] == "" {
			missing = append(missing, n)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("starter %s needs %s", id, strings.Join(missing, ", "))
	}
	files, err := starterRaw(id)
	if err != nil {
		return nil, err
	}
	for p, b := range files {
		if starterText(b) {
			files[p] = starterPlaceholder.ReplaceAllFunc(b, func(m []byte) []byte {
				return []byte(values[strings.Trim(string(m), "_")])
			})
		}
	}
	return files, nil
}
