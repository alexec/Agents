package agentsd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The Files pane (DaemonCore+Files.swift): every read kept to an agent's folder.

const (
	CodeFileGone        = -32032
	CodeFileNotReadable = -32033
	listingLimit        = 5000
	textLimit           = 128 << 10
	imageLimit          = 4 << 20
)

func fileError(code int, msg string) *Error { return &Error{Code: code, Message: msg} }

// agentFolder is the folder an agent works in, its links resolved.
func (d *Daemon) agentFolder(id wire.UUID) (string, error) {
	a := d.Store.Agent(id)
	if a == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."}
	}
	root := store.FolderPath(a.Cwd)
	if r, err := store.Resolve(root); err == nil {
		root = r
	}
	return root, nil
}

// scoped resolves path, links and all, and checks that it is in the agent's folder.
func (d *Daemon) scoped(id wire.UUID, path string) (string, error) {
	root, err := d.agentFolder(id)
	if err != nil {
		return "", err
	}
	path = strings.TrimPrefix(path, "file://")
	if !filepath.IsAbs(path) {
		return "", Invalid("The path has to be absolute, starting at /.")
	}
	real, err := store.Resolve(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fileError(CodeFileGone, filepath.Base(path)+" is gone.")
		}
		return "", fileError(CodeFileNotReadable, filepath.Base(path)+" can't be opened.")
	}
	if !inside(root, real) {
		return "", Invalid("%s is outside the folders this agent works in.", path)
	}
	return real, nil
}

// resolved is path with its links followed, as far as it exists: a file not made yet in a
// folder reached through a link is still found in that folder.
func resolved(path string) string {
	path = filepath.Clean(path)
	rest := ""
	for p := path; ; p = filepath.Dir(p) {
		if r, err := store.Resolve(p); err == nil {
			return filepath.Join(r, rest)
		}
		if p == filepath.Dir(p) {
			return path
		}
		rest = filepath.Join(filepath.Base(p), rest)
	}
}

func inside(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, "../")
}

func fileURL(p string, dir bool) wire.URL {
	return slashed(store.FolderURL(p), dir)
}

func slashed(u wire.URL, dir bool) wire.URL {
	if dir && !strings.HasSuffix(string(u), "/") {
		u += "/"
	}
	return u
}

// listing is a folder's entries, folders first, at most listingLimit of them.
func listing(dir string) (wire.DirectoryListing, error) {
	fi, err := os.Stat(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return wire.DirectoryListing{}, fileError(CodeFileGone, filepath.Base(dir)+" is gone.")
		}
		return wire.DirectoryListing{}, fileError(CodeFileNotReadable, filepath.Base(dir)+" can't be opened.")
	}
	if !fi.IsDir() {
		return wire.DirectoryListing{}, Invalid("That is a file.")
	}
	items, err := os.ReadDir(dir)
	if err != nil {
		return wire.DirectoryListing{}, fileError(CodeFileNotReadable, filepath.Base(dir)+" can't be opened.")
	}
	// The folder's links are resolved once; an entry keeps its own name, link or not (#1265).
	base := dir
	if r, err := store.Resolve(dir); err == nil {
		base = r
	}
	entries := []wire.DirectoryEntry{}
	for _, it := range items {
		info, err := it.Info()
		if err != nil {
			continue
		}
		p := filepath.Join(dir, it.Name())
		isDir := info.IsDir()
		if info.Mode()&os.ModeSymlink != 0 {
			if t, err := os.Stat(p); err == nil {
				isDir = t.IsDir()
			}
		}
		at := wire.DateOf(info.ModTime())
		e := wire.DirectoryEntry{URL: slashed(store.PathURL(filepath.Join(base, it.Name())), isDir), Name: it.Name(), IsDirectory: isDir, ModifiedAt: &at}
		if !isDir {
			s := info.Size()
			e.Size = &s
		}
		entries = append(entries, e)
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDirectory != entries[j].IsDirectory {
			return entries[i].IsDirectory
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	var omitted int64
	if len(entries) > listingLimit {
		omitted = int64(len(entries) - listingLimit)
		entries = entries[:listingLimit]
	}
	return wire.DirectoryListing{URL: fileURL(dir, true), Entries: entries, Omitted: omitted}, nil
}

var imageKinds = map[string]string{"png": "PNG image", "jpg": "JPEG image", "jpeg": "JPEG image", "gif": "GIF image",
	"heic": "HEIC image", "heif": "HEIF image", "webp": "WebP image", "tiff": "TIFF image", "tif": "TIFF image",
	"bmp": "BMP image", "svg": "SVG image", "icns": "Icon"}

func sizeWords(n int64) string {
	switch {
	case n < 1000:
		return fmt.Sprintf("%d bytes", n)
	case n < 1000*1000:
		return fmt.Sprintf("%d KB", (n+500)/1000)
	default:
		return fmt.Sprintf("%.1f MB", float64(n)/1e6)
	}
}

// reading is FileProbe: text (its first 128 KiB), an image (up to 4 MiB), or other; or
// unchanged, when the stamp the window holds is still the file's.
func reading(path string, known *wire.FileStamp) (wire.FileReading, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return wire.FileReading{}, fileError(CodeFileGone, filepath.Base(path)+" is gone.")
	}
	if fi.IsDir() {
		return wire.FileReading{}, Invalid("That is a folder.")
	}
	st := wire.FileStamp{Size: fi.Size(), ModifiedAt: wire.DateOf(fi.ModTime())}
	if known != nil && *known == st {
		return wire.FileReading{Kind: "unchanged", Stamp: st}, nil
	}
	size := float64(fi.Size())
	other := func(what string) wire.FileReading {
		described := what + ", " + sizeWords(fi.Size())
		return wire.FileReading{Kind: "other", Stamp: st, Size: &size, DescribedAs: &described}
	}
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	if what, ok := imageKinds[ext]; ok {
		if fi.Size() > imageLimit {
			return other(what), nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return wire.FileReading{}, fileError(CodeFileNotReadable, filepath.Base(path)+" can't be opened.")
		}
		described := what + ", " + sizeWords(fi.Size())
		return wire.FileReading{Kind: "image", Stamp: st, Bytes: b, DescribedAs: &described}, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return wire.FileReading{}, fileError(CodeFileNotReadable, filepath.Base(path)+" can't be opened.")
	}
	defer f.Close()
	b := make([]byte, textLimit)
	n, _ := f.Read(b)
	b = b[:n]
	head := b[:min(len(b), 8192)]
	trimmed := b
	for i := 0; i < 3 && len(trimmed) > 0 && !utf8.Valid(trimmed); i++ {
		trimmed = trimmed[:len(trimmed)-1] // a character cut at the end
	}
	if strings.IndexByte(string(head), 0) >= 0 || !utf8.Valid(trimmed) {
		if ext != "" {
			return other(strings.ToUpper(ext) + " file"), nil
		}
		return other("Binary file"), nil
	}
	text := string(trimmed)
	truncated := fi.Size() > textLimit
	return wire.FileReading{Kind: "text", Stamp: st, Text: &text, IsTruncated: &truncated, Size: &size}, nil
}

func expandHome(p string) string {
	home, _ := os.UserHomeDir()
	if p == "" || p == "~" {
		return home
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home, p[2:])
	}
	return p
}

// raw serves a method not yet in the OpenRPC document, with its own params type.
func (d *Daemon) registerFiles() {
	On(d, wire.CallFilesList, func(ctx context.Context, c *Client, r wire.FilesListRequest) (wire.DirectoryListing, error) {
		dir, err := d.scoped(r.AgentID, r.Folder)
		if err != nil {
			return wire.DirectoryListing{}, err
		}
		return listing(dir)
	})
	On(d, wire.CallFilesRead, func(ctx context.Context, c *Client, r wire.FilesReadRequest) (wire.FileReading, error) {
		path, err := d.scoped(r.AgentID, r.Path)
		if err != nil {
			return wire.FileReading{}, err
		}
		return reading(path, r.KnownStamp)
	})
	// Add Folder's directory picker: anywhere this user may read, ~ allowed.
	On(d, wire.CallFilesBrowse, func(ctx context.Context, c *Client, r wire.FilesBrowseRequest) (wire.DirectoryListing, error) {
		path := ""
		if r.Path != nil {
			path = strings.TrimPrefix(*r.Path, "file://")
		}
		path = expandHome(path)
		if !filepath.IsAbs(path) {
			return wire.DirectoryListing{}, Invalid("Give an absolute path, or one starting ~.")
		}
		return listing(path)
	})
	On(d, wire.CallFilesMention, func(ctx context.Context, c *Client, r wire.FileMentionRequest) ([]wire.FileMentionDTO, error) {
		out := []wire.FileMentionDTO{}
		root, err := d.agentFolder(r.AgentID)
		if err != nil {
			return out, nil
		}
		term := strings.ToLower(r.Term)
		seen := 0
		filepath.WalkDir(root, func(path string, e os.DirEntry, err error) error {
			seen++
			if err != nil || len(out) >= 50 || seen > 20000 {
				return filepath.SkipDir
			}
			if e.IsDir() && excludedName(e.Name()) {
				return filepath.SkipDir
			}
			rel, _ := filepath.Rel(root, path)
			if !e.IsDir() && strings.Contains(strings.ToLower(rel), term) {
				out = append(out, wire.FileMentionDTO{Path: path, RelativePath: rel})
			}
			return nil
		})
		return out, nil
	})
	On(d, wire.CallFilesWatch, func(ctx context.Context, c *Client, r wire.FilesWatchRequest) (wire.Empty, error) {
		return wire.Empty{}, d.watchFiles(c, r)
	})
	On(d, wire.CallFilesUnwatch, func(ctx context.Context, c *Client, r wire.FilesWatchRequest) (wire.Empty, error) {
		d.unwatchFiles(c, r)
		return wire.Empty{}, nil
	})

	// Settings files, and attachments.
	On(d, wire.CallFilesReadText, func(ctx context.Context, c *Client, r wire.FilesTextRequest) (wire.FilesText, error) {
		path := expandHome(r.Path)
		b, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			return wire.FilesText{}, nil
		}
		if err != nil || len(b) > 1<<20 {
			return wire.FilesText{}, fileError(CodeFileNotReadable, filepath.Base(path)+" can't be opened.")
		}
		text := string(b)
		return wire.FilesText{Text: &text}, nil
	})
	On(d, wire.CallFilesSaveText, func(ctx context.Context, c *Client, r wire.FilesSaveTextRequest) (wire.Empty, error) {
		path := expandHome(r.Path)
		if len(r.Text) > 1<<20 {
			return wire.Empty{}, Invalid("That is more than 1 MB.")
		}
		if _, err := os.Stat(path); err == nil && r.OnlyIfAbsent != nil && *r.OnlyIfAbsent {
			return wire.Empty{}, nil
		}
		if err := store.WriteAtomically(path, []byte(r.Text), 0o644); err != nil {
			return wire.Empty{}, fileError(CodeFileNotReadable, err.Error())
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallFilesWrite, func(ctx context.Context, c *Client, r wire.FilesWriteRequest) (wire.FilesWriteResponse, error) {
		root, err := d.agentFolder(r.AgentID)
		if err != nil {
			return wire.FilesWriteResponse{}, err
		}
		if len(r.Data) > 25<<20 {
			return wire.FilesWriteResponse{}, Invalid("That is more than 25 MB.")
		}
		path, err := d.writeAttachment(root, r.Name, r.Data)
		if err != nil {
			return wire.FilesWriteResponse{}, fileError(CodeFileNotReadable, err.Error())
		}
		return wire.FilesWriteResponse{Path: path}, nil
	})
}

// buildOutputNames is what a folder's watch leaves out (#216), as DaemonCore does.
var buildOutputNames = []string{"node_modules", ".build", "build", "DerivedData", "target", "dist"}

func excludedName(name string) bool {
	if name == ".git" {
		return true
	}
	for _, n := range buildOutputNames {
		if n == name {
			return true
		}
	}
	return false
}

// MARK: watching (files/watch): a client hears files/changed for the folders that changed
// under an agent's folder, while it watches.

// folderLimit is FilesChangedNotification.folderLimit: past it the notice says "many".
const folderLimit = 64

type interest struct {
	client *Client
	agent  wire.UUID
}

func (d *Daemon) watchFiles(c *Client, r wire.FilesWatchRequest) error {
	root, err := d.agentFolder(r.AgentID)
	if err != nil {
		return err
	}
	if !isDir(root) {
		return fileError(CodeFileGone, filepath.Base(root)+" is gone.")
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	w := d.watches[root]
	if w == nil {
		w, err = newFilesWatch(root, func(folders []string) { d.filesChanged(root, folders) })
		if err != nil {
			return err
		}
		d.watches[root] = w
	}
	d.interests[root] = append(d.interests[root], interest{client: c, agent: r.AgentID})
	return nil
}

func (d *Daemon) unwatchFiles(c *Client, r wire.FilesWatchRequest) {
	root, err := d.agentFolder(r.AgentID)
	if err != nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.dropInterest(root, func(i interest) bool { return i.client == c && i.agent == r.AgentID })
}

// dropInterest removes interests, and the watch with the last of them. Holds d.mu.
func (d *Daemon) dropInterest(root string, gone func(interest) bool) {
	var keep []interest
	for _, i := range d.interests[root] {
		if !gone(i) {
			keep = append(keep, i)
		}
	}
	if len(keep) > 0 {
		d.interests[root] = keep
		return
	}
	delete(d.interests, root)
	if w := d.watches[root]; w != nil {
		w.stop()
		delete(d.watches, root)
	}
}

// forgetWatches is a client gone: everything it watched goes with it.
func (d *Daemon) forgetWatches(c *Client) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for root := range d.interests {
		d.dropInterest(root, func(i interest) bool { return i.client == c })
	}
}

func (d *Daemon) filesChanged(root string, folders []string) {
	n := wire.FilesChangedNotification{Folders: folders}
	if len(folders) > folderLimit {
		n.Folders = folders[:folderLimit]
		many := true
		n.Many = &many
	}
	d.mu.Lock()
	is := append([]interest(nil), d.interests[root]...)
	d.mu.Unlock()
	for _, i := range is {
		n.AgentID = i.agent
		Notify(i.client, wire.NotifyFilesChanged, n)
	}
}
