package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

// The Files pane (DaemonCore+Files.swift): every read scoped to an agent's folder.

type stamp struct {
	Size       int64 `json:"size"`
	ModifiedAt Date  `json:"modifiedAt"`
}

type listingEntry struct {
	URL         string `json:"url"`
	Name        string `json:"name"`
	IsDirectory bool   `json:"isDirectory"`
	Size        *int64 `json:"size,omitempty"`
	ModifiedAt  Date   `json:"modifiedAt"`
}

const listingLimit = 5000

func fileErr(code int, msg string) *RPCError { return &RPCError{Code: code, Message: msg} }

// scoped resolves path and checks it is in the agent's folder.
func (d *Daemon) scoped(agentID, path string) (string, error) {
	a := d.store.Agent(agentID)
	if a == nil {
		return "", fileErr(-32005, "That agent is not here.")
	}
	if !filepath.IsAbs(path) {
		return "", fileErr(-32602, "The path has to be absolute, starting at /.")
	}
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fileErr(-32032, filepath.Base(path)+" is gone.")
		}
		return "", fileErr(-32033, filepath.Base(path)+" can't be opened.")
	}
	root, _ := filepath.EvalSymlinks(folderPath(a.Cwd))
	if rel, err := filepath.Rel(root, real); err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return "", fileErr(-32602, path+" is outside the folders this agent works in.")
	}
	return real, nil
}

func listing(dir string) (any, error) {
	fi, err := os.Stat(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fileErr(-32032, filepath.Base(dir)+" is gone.")
		}
		return nil, fileErr(-32033, filepath.Base(dir)+" can't be opened.")
	}
	if !fi.IsDir() {
		return nil, fileErr(-32602, "That is a file.")
	}
	items, err := os.ReadDir(dir)
	if err != nil {
		return nil, fileErr(-32033, filepath.Base(dir)+" can't be opened.")
	}
	entries := []listingEntry{}
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
		e := listingEntry{URL: fileURL(p, isDir), Name: it.Name(), IsDirectory: isDir, ModifiedAt: FromTime(info.ModTime())}
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
	omitted := 0
	if len(entries) > listingLimit {
		omitted = len(entries) - listingLimit
		entries = entries[:listingLimit]
	}
	return map[string]any{"url": fileURL(dir, true), "entries": entries, "omitted": omitted}, nil
}

func fileURL(p string, dir bool) string {
	if dir {
		return folderURL(p)
	}
	return "file://" + p
}

var imageExts = map[string]string{"png": "PNG image", "jpg": "JPEG image", "jpeg": "JPEG image", "gif": "GIF image",
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

// reading is FileProbe.swift: text (first 128 KiB), an image (up to 4 MiB), or other.
func reading(path string, known *stamp) (any, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return nil, fileErr(-32032, filepath.Base(path)+" is gone.")
	}
	if fi.IsDir() {
		return nil, fileErr(-32602, "That is a folder.")
	}
	st := stamp{Size: fi.Size(), ModifiedAt: FromTime(fi.ModTime())}
	if known != nil && *known == st {
		return map[string]any{"kind": "unchanged", "stamp": st}, nil
	}
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	if what, ok := imageExts[ext]; ok {
		if fi.Size() <= 4<<20 {
			b, err := os.ReadFile(path)
			if err != nil {
				return nil, fileErr(-32033, filepath.Base(path)+" can't be opened.")
			}
			return map[string]any{"kind": "image", "bytes": b, "describedAs": what + ", " + sizeWords(fi.Size()), "stamp": st}, nil
		}
		return map[string]any{"kind": "other", "describedAs": what + ", " + sizeWords(fi.Size()), "size": fi.Size(), "stamp": st}, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, fileErr(-32033, filepath.Base(path)+" can't be opened.")
	}
	defer f.Close()
	b := make([]byte, 128<<10)
	n, _ := f.Read(b)
	b = b[:n]
	head := b
	if len(head) > 8192 {
		head = head[:8192]
	}
	trimmed := b
	for i := 0; i < 3 && len(trimmed) > 0 && !utf8.Valid(trimmed); i++ {
		trimmed = trimmed[:len(trimmed)-1] // a character cut at the end
	}
	if strings.IndexByte(string(head), 0) >= 0 || !utf8.Valid(trimmed) {
		what := "Binary file"
		if ext != "" {
			what = strings.ToUpper(ext) + " file"
		}
		return map[string]any{"kind": "other", "describedAs": what + ", " + sizeWords(fi.Size()), "size": fi.Size(), "stamp": st}, nil
	}
	return map[string]any{"kind": "text", "text": string(trimmed), "isTruncated": fi.Size() > 128<<10, "size": fi.Size(), "stamp": st}, nil
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

func (d *Daemon) registerFiles() {
	d.Handle("files/list", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[struct {
			AgentID string `json:"agentID"`
			Folder  string `json:"folder"`
		}](p)
		if err != nil {
			return nil, invalid(err)
		}
		dir, err := d.scoped(r.AgentID, r.Folder)
		if err != nil {
			return nil, err
		}
		return listing(dir)
	})
	d.Handle("files/read", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[struct {
			AgentID    string `json:"agentID"`
			Path       string `json:"path"`
			KnownStamp *stamp `json:"knownStamp"`
		}](p)
		if err != nil {
			return nil, invalid(err)
		}
		path, err := d.scoped(r.AgentID, r.Path)
		if err != nil {
			return nil, err
		}
		return reading(path, r.KnownStamp)
	})
	d.Handle("files/browse", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			Path string `json:"path"`
		}](p)
		path := expandHome(r.Path)
		if !filepath.IsAbs(path) {
			return nil, fileErr(-32602, "Give an absolute path, or one starting ~.")
		}
		return listing(path)
	})
	d.Handle("files/readText", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			Path string `json:"path"`
		}](p)
		b, err := os.ReadFile(expandHome(r.Path))
		if os.IsNotExist(err) {
			return empty(), nil
		}
		if err != nil || len(b) > 1<<20 {
			return nil, fileErr(-32033, filepath.Base(r.Path)+" can't be opened.")
		}
		return map[string]any{"text": string(b)}, nil
	})
	d.Handle("files/saveText", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			Path         string `json:"path"`
			Text         string `json:"text"`
			OnlyIfAbsent bool   `json:"onlyIfAbsent"`
		}](p)
		path := expandHome(r.Path)
		if len(r.Text) > 1<<20 {
			return nil, fileErr(-32602, "That is more than 1 MB.")
		}
		if _, err := os.Stat(path); err == nil && r.OnlyIfAbsent {
			return empty(), nil
		}
		os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte(r.Text), 0o644); err != nil {
			return nil, fileErr(-32033, err.Error())
		}
		return empty(), nil
	})
	d.Handle("files/write", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[struct {
			AgentID string `json:"agentID"`
			Name    string `json:"name"`
			Data    []byte `json:"data"`
		}](p)
		if err != nil {
			return nil, invalid(err)
		}
		a := d.store.Agent(r.AgentID)
		if a == nil {
			return nil, fileErr(-32005, "That agent is not here.")
		}
		if len(r.Data) > 25<<20 {
			return nil, fileErr(-32602, "That is more than 25 MB.")
		}
		dir := filepath.Join(folderPath(a.Cwd), ".agents", "attachments")
		os.MkdirAll(dir, 0o700)
		path := filepath.Join(dir, NewUUID()[:8]+"-"+filepath.Base(r.Name))
		if err := os.WriteFile(path, r.Data, 0o600); err != nil {
			return nil, fileErr(-32033, err.Error())
		}
		return map[string]any{"path": path}, nil
	})
	d.Handle("files/mention", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			AgentID string `json:"agentID"`
			Term    string `json:"term"`
		}](p)
		a := d.store.Agent(r.AgentID)
		out := []map[string]string{}
		if a == nil {
			return out, nil
		}
		root := folderPath(a.Cwd)
		term := strings.ToLower(r.Term)
		filepath.WalkDir(root, func(path string, e os.DirEntry, err error) error {
			if err != nil || len(out) >= 50 {
				return filepath.SkipDir
			}
			if e.IsDir() && (e.Name() == ".git" || e.Name() == "node_modules") {
				return filepath.SkipDir
			}
			rel, _ := filepath.Rel(root, path)
			if !e.IsDir() && strings.Contains(strings.ToLower(rel), term) {
				out = append(out, map[string]string{"path": path, "relativePath": rel})
			}
			return nil
		})
		return out, nil
	})
}
