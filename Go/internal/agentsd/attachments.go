package agentsd

import (
	"bytes"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A folder's attachments (#1556), in <agent folder>/.agents/attachments, are bound: one
// that no kept agent's transcript names goes after attachmentDays, and the folder is kept
// under attachmentFolderBytes, oldest first. A temporary file a cut-off write left goes
// after a day. A write applies only the size bound; the hourly sweep looks for the names
// (#1651), and remembers which agent names each old file it keeps, so each old file is
// looked for in the transcripts once, not at each sweep.

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
	dir, err := attachmentsDir(root, true)
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, string(store.NewUUID())[:8]+"-"+filepath.Base(name))
	if err := store.WriteAtomically(path, data, 0o600); err != nil {
		return "", err
	}
	d.boundAttachments(root, path, false)
	return path, nil
}

// attachmentsDir is root's attachments folder, made when create is set. .agents and
// .agents/attachments each have to be a real folder, not a link: a folder can commit
// either as a link to a folder outside it, and the sweep would delete what is there.
func attachmentsDir(root string, create bool) (string, error) {
	dir := root
	for _, name := range strings.Split(attachmentsFolder, "/") {
		dir = filepath.Join(dir, name)
		info, err := os.Lstat(dir)
		if os.IsNotExist(err) && create {
			if err := os.Mkdir(dir, 0o700); err != nil && !os.IsExist(err) {
				return "", err
			}
			info, err = os.Lstat(dir)
		}
		if err != nil {
			return "", err
		}
		if !info.IsDir() {
			return "", fmt.Errorf("%s is not a folder (a link is refused)", dir)
		}
	}
	return dir, nil
}

// attachmentBook is, per agent folder, which agent's transcript names each old
// attachment the last sweep kept. It holds no more than the old files that folder keeps.
type attachmentBook struct {
	namedMu sync.Mutex
	namedBy map[string]map[string]wire.UUID
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
		d.boundAttachments(root, "", true)
	}
	d.namedMu.Lock()
	for root := range d.namedBy {
		if !seen[root] {
			delete(d.namedBy, root)
		}
	}
	d.namedMu.Unlock()
}

type attachment struct {
	path string
	size int64
	at   time.Time
}

// boundAttachments deletes from root's attachments what is past the bounds; keep is
// the one just written, never deleted. Only with byAge does it delete an old file that no
// transcript names: that reads transcripts, so a write does not.
func (d *Daemon) boundAttachments(root, keep string, byAge bool) (deleted int) {
	dir, err := attachmentsDir(root, false)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("attachments: %v", err)
		}
		return 0
	}
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
		if byAge && path != keep && t.Sub(f.at) > attachmentDays {
			old = append(old, f)
			continue
		}
		files = append(files, f)
	}
	if byAge {
		named := d.namedAttachments(root, old)
		for _, f := range old {
			if _, ok := named[f.path]; ok {
				files = append(files, f)
			} else {
				remove(f.path)
			}
		}
		d.namedMu.Lock()
		if d.namedBy == nil {
			d.namedBy = map[string]map[string]wire.UUID{}
		}
		if len(named) > 0 {
			d.namedBy[root] = named
		} else {
			delete(d.namedBy, root)
		}
		d.namedMu.Unlock()
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

// namedAttachments is, for each of files that a transcript of an agent kept here, in
// root, names, the agent that names it. An archived agent counts: it can be brought back.
// A file the last sweep found named by an agent still kept here is named still, as a
// transcript only grows; only the others are looked for. A name is looked for by its
// random prefix ("1A2B3C4D-"), which no escaping changes.
func (d *Daemon) namedAttachments(root string, files []attachment) map[string]wire.UUID {
	named := map[string]wire.UUID{}
	var agents []wire.UUID
	here := map[wire.UUID]bool{}
	for _, a := range d.Store.Agents() {
		if r, err := d.agentFolder(a.ID); err == nil && r == root {
			agents = append(agents, a.ID)
			here[a.ID] = true
		}
	}
	d.namedMu.Lock()
	known := d.namedBy[root]
	d.namedMu.Unlock()
	var unknown []attachment
	for _, f := range files {
		if id, ok := known[f.path]; ok && here[id] {
			named[f.path] = id
		} else {
			unknown = append(unknown, f)
		}
	}
	for _, id := range agents {
		if len(unknown) == 0 {
			break
		}
		found := map[string]bool{}
		scanFor(d.Store.Loc.Transcript(string(id)), unknown, found)
		rest := unknown[:0:0]
		for _, f := range unknown {
			if found[f.path] {
				named[f.path] = id
			} else {
				rest = append(rest, f)
			}
		}
		unknown = rest
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
		if err != nil || len(named) == len(files) {
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
