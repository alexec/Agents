package skillcatalog

import (
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"

	"golang.org/x/text/collate"
	"golang.org/x/text/language"
)

// The three hashes a skill is known by (SkillHashes):
//   - BlobSHA: git's SHA-1 of one file, which GitHub's tree lists for every file.
//   - TreeSHA: git's SHA-1 of a folder, which the `skills` CLI records for a personal skill.
//   - ComputedHash: the CLI's own SHA-256 of a folder, which it records for a folder skill.

// BlobSHA is git's blob id: SHA-1 of "blob <length>\0" and the bytes.
func BlobSHA(data []byte) string {
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(data))
	h.Write(data)
	return hex.EncodeToString(h.Sum(nil))
}

const emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

// ErrSymbolicLink is a folder with a link in it, which TreeSHA refuses rather than hashes:
// a skill the app writes never has one.
var ErrSymbolicLink = errors.New("a symbolic link")

// TreeSHA is a folder hashed as git would: files 100644 or 100755, folders 40000, entries
// in git's order (a folder's name compared as if it ended in /). An empty folder is left
// out, as git has no way to hold one.
func TreeSHA(folder string) (string, error) {
	id, err := treeID(folder)
	if err != nil {
		return "", err
	}
	if id == nil {
		return emptyTree, nil
	}
	return hex.EncodeToString(id), nil
}

func treeID(folder string) ([]byte, error) {
	entries, err := os.ReadDir(folder)
	if err != nil {
		return nil, err
	}
	type line struct {
		key  string
		text []byte
	}
	var lines []line
	for _, e := range entries {
		name := e.Name()
		if name == ".git" {
			continue
		}
		path := filepath.Join(folder, name)
		info, err := os.Lstat(path)
		if err != nil {
			return nil, err
		}
		var mode string
		var id []byte
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			return nil, fmt.Errorf("%w: %s", ErrSymbolicLink, path)
		case info.IsDir():
			sub, err := treeID(path)
			if err != nil {
				return nil, err
			}
			if sub == nil {
				continue
			}
			mode, id = "40000", sub
		case info.Mode().IsRegular():
			data, err := os.ReadFile(path)
			if err != nil {
				return nil, err
			}
			mode = "100644"
			if info.Mode()&0o111 != 0 {
				mode = "100755"
			}
			sum := sha1.Sum(append([]byte(fmt.Sprintf("blob %d\x00", len(data))), data...))
			id = sum[:]
		default:
			continue
		}
		key := name
		if mode == "40000" {
			key += "/"
		}
		lines = append(lines, line{key, append([]byte(mode+" "+name+"\x00"), id...)})
	}
	if len(lines) == 0 {
		return nil, nil
	}
	sort.Slice(lines, func(i, j int) bool { return lines[i].key < lines[j].key })
	var body []byte
	for _, l := range lines {
		body = append(body, l.text...)
	}
	sum := sha1.Sum(append([]byte(fmt.Sprintf("tree %d\x00", len(body))), body...))
	return sum[:], nil
}

// File is one file of a skill, by its path in the folder with /.
type File struct {
	Path string
	Data []byte
}

// ComputedHash is the CLI's computeSkillFolderHash: SHA-256 over each file's path, then its
// bytes, in JavaScript's localeCompare order of the paths. .git and node_modules are
// skipped, and so is anything not a plain file.
func ComputedHash(folder string) (string, error) {
	var files []File
	if err := collect(folder, "", &files); err != nil {
		return "", err
	}
	return ComputedHashOf(files), nil
}

// ComputedHashOf is the same over files held in memory: what a preview stages.
func ComputedHashOf(files []File) string {
	sorted := append([]File(nil), files...)
	sort.SliceStable(sorted, func(i, j int) bool { return LocaleLess(sorted[i].Path, sorted[j].Path) })
	h := sha256.New()
	for _, f := range sorted {
		h.Write([]byte(f.Path))
		h.Write(f.Data)
	}
	return hex.EncodeToString(h.Sum(nil))
}

func collect(folder, prefix string, files *[]File) error {
	entries, err := os.ReadDir(folder)
	if err != nil {
		return err
	}
	for _, e := range entries {
		name := e.Name()
		path := filepath.Join(folder, name)
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		rel := name
		if prefix != "" {
			rel = prefix + "/" + name
		}
		switch {
		case info.Mode()&os.ModeSymlink != 0:
		case info.IsDir():
			if name == ".git" || name == "node_modules" {
				continue
			}
			if err := collect(path, rel, files); err != nil {
				return err
			}
		case info.Mode().IsRegular():
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			*files = append(*files, File{rel, data})
		}
	}
	return nil
}

var (
	collatorMu sync.Mutex
	collator   = collate.New(language.English)
)

// LocaleLess is `a.localeCompare(b) < 0` as node computes it: ICU's English collation,
// "_" before "-" and lower case before upper.
func LocaleLess(a, b string) bool {
	collatorMu.Lock()
	defer collatorMu.Unlock()
	return collator.CompareString(a, b) < 0
}
