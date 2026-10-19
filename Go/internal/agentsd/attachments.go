package agentsd

import (
	"bytes"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// A project's attachments (#1556), in <agent folder>/.agents/attachments, are bound: one
// that no kept agent's transcript names goes after attachmentDays, and the folder is kept
// under attachmentFolderBytes, oldest first. A temporary file a cut-off write left goes
// after a day.

const (
	attachmentDays    = 7 * 24 * time.Hour
	attachmentTmpAge  = 24 * time.Hour
	attachmentsFolder = ".agents/attachments"
)

// attachmentFolderBytes is the most a folder's attachments come to: twenty of the
// largest (25 MB). A variable for the tests.
var attachmentFolderBytes int64 = 500 << 20

// writeAttachment writes data whole as a new attachment in root, then bounds the folder.
func (d *Daemon) writeAttachment(root, name string, data []byte) (string, error) {
	dir := filepath.Join(root, attachmentsFolder)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(dir, string(store.NewUUID())[:8]+"-"+filepath.Base(name))
	if err := store.WriteAtomically(path, data, 0o600); err != nil {
		return "", err
	}
	d.boundAttachments(root, path)
	return path, nil
}

// sweepAttachments bounds the attachments of every folder an agent here works in.
func (d *Daemon) sweepAttachments() {
	seen := map[string]bool{}
	for _, a := range d.Store.Agents() {
		root, err := d.agentFolder(a.ID)
		if err != nil || seen[root] {
			continue
		}
		seen[root] = true
		d.boundAttachments(root, "")
	}
}

type attachment struct {
	path string
	size int64
	at   time.Time
}

// boundAttachments deletes from root's attachments what is past the bounds; keep is
// the one just written, never deleted.
func (d *Daemon) boundAttachments(root, keep string) (deleted int) {
	dir := filepath.Join(root, attachmentsFolder)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	t := nowFunc()
	remove := func(path string) {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			log.Printf("attachments: %v", err)
			return
		}
		deleted++
	}
	var files []attachment
	var old []attachment
	for _, e := range entries {
		info, err := e.Info()
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		path := filepath.Join(dir, e.Name())
		if strings.HasPrefix(e.Name(), ".") {
			// WriteAtomically's temporary file: a write cut off left it.
			if strings.HasSuffix(e.Name(), ".tmp") && t.Sub(info.ModTime()) > attachmentTmpAge {
				remove(path)
			}
			continue
		}
		f := attachment{path: path, size: info.Size(), at: info.ModTime()}
		if path != keep && t.Sub(f.at) > attachmentDays {
			old = append(old, f)
			continue
		}
		files = append(files, f)
	}
	if len(old) > 0 {
		named := d.namedAttachments(root, old)
		for _, f := range old {
			if named[f.path] {
				files = append(files, f)
			} else {
				remove(f.path)
			}
		}
	}
	var total int64
	for _, f := range files {
		total += f.size
	}
	sort.Slice(files, func(i, j int) bool { return files[i].at.Before(files[j].at) })
	for _, f := range files {
		if total <= attachmentFolderBytes {
			break
		}
		if f.path == keep {
			continue
		}
		remove(f.path)
		total -= f.size
	}
	return deleted
}

// namedAttachments is which of files a transcript of an agent kept here, in root, names.
// An archived agent counts: it can be brought back. A name is looked for by its random
// prefix ("1A2B3C4D-"), which no escaping changes.
func (d *Daemon) namedAttachments(root string, files []attachment) map[string]bool {
	named := map[string]bool{}
	for _, a := range d.Store.Agents() {
		if r, err := d.agentFolder(a.ID); err != nil || r != root {
			continue
		}
		scanFor(d.Store.Loc.Transcript(string(a.ID)), files, named)
		if len(named) == len(files) {
			break
		}
	}
	return named
}

// scanFor marks in named each file whose key the file at path has, read a piece at a
// time: a transcript can be large.
func scanFor(path string, files []attachment, named map[string]bool) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	const piece = 1 << 20
	overlap := 0
	for _, a := range files {
		overlap = max(overlap, len(attachmentKey(a.path))-1)
	}
	buf := make([]byte, overlap+piece)
	kept := 0
	for {
		n, err := io.ReadFull(f, buf[kept:kept+piece])
		window := buf[:kept+n]
		for _, a := range files {
			if !named[a.path] && bytes.Contains(window, []byte(attachmentKey(a.path))) {
				named[a.path] = true
			}
		}
		if err != nil {
			return
		}
		kept = min(overlap, len(window))
		copy(buf, window[len(window)-kept:])
	}
}

// attachmentKey is the random prefix writeAttachment gives a name, with its dash.
func attachmentKey(path string) string {
	base := filepath.Base(path)
	if i := strings.IndexByte(base, '-'); i > 0 {
		return base[:i+1]
	}
	return base
}
