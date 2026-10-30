// Package lineage is the graph of the SDLC (#2348, spec 2348-lineage): typed nodes (an
// issue, a pull request, a session, a workflow run, a commit, ...) and typed links between
// them (works-on, opens, fixes, ...). The store holds only links, so many-to-many needs
// nothing more: a node is in the graph while a link names it.
//
// Store is the one way in, for reads and writes, so a graph database can replace the files
// later (Alex, 2026-10-22). Files is today's store: an append-only <root>/lineage.jsonl.
package lineage

import (
	"bytes"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The kinds of node and the relationships and sources this build makes. The lists are
// open: a kind, relationship or source from a newer build is kept as it is.
const (
	KindIssue       = "issue"
	KindPR          = "pr"
	KindSession     = "session"
	KindWorkflowRun = "workflow-run"
	KindCommit      = "commit"
	KindFile        = "file"
	KindBranch      = "branch"
	KindMilestone   = "milestone"
	KindWorkflow    = "workflow"

	RelWorksOn = "works-on"
	RelOpens   = "opens"
	RelFixes   = "fixes"
	RelStarted = "started"
	RelReviews = "reviews"
	RelCloses  = "closes"
	RelPartOf  = "part-of"

	SourceStart  = "start"
	SourceBranch = "branch"
	SourcePRBody = "pr-body"
	SourceHelper = "helper"
	SourceAgent  = "agent"
	SourcePerson = "person"
)

// The bounds (#2348; "Bound data, not concurrency"). An ended link is kept KeepEnded after
// its end; at most MostLinks are kept, the oldest ended ones going first, then the oldest
// active ones. An answer holds at most MostAnswer links, and a walk reaches at most
// MostNodes nodes, at most MostDepth links away.
const (
	KeepEnded    = 90 * 24 * time.Hour
	MostLinks    = 20_000
	MostAnswer   = 500
	MostNodes    = 500
	MostDepth    = 4
	DefaultDepth = 2
	// rewriteMargin is how many lines past the links kept the file may grow before it is
	// written again whole.
	rewriteMargin = 2_000
)

// Store is the lineage graph, for reads and writes.
type Store interface {
	// Link starts a link at at. When the same link (from, to, rel) is active already, it
	// is the answer, unchanged.
	Link(r wire.LineageLinkRequest, at time.Time) (wire.LineageLink, error)
	// End ends the active link from, to, rel at at, and says it; none when it was not active.
	End(r wire.LineageEndRequest, at time.Time) ([]wire.LineageLink, error)
	// Links is a node's links, either way, newest first, at most MostAnswer.
	Links(n wire.LineageNode) wire.LineageLinks
	// Walk is the graph within depth links of a node, either way.
	Walk(n wire.LineageNode, depth int) wire.LineageGraph
	// Close writes what is left and lets the file go.
	Close() error
}

var (
	kindPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,39}$`)
	refPattern  = regexp.MustCompile(`^[a-z][a-z0-9-]{0,19}:\S`)
)

// maxRef bounds a ref, so one line stays small.
const maxRef = 512

func checkNode(n wire.LineageNode) error {
	if !kindPattern.MatchString(n.Kind) {
		return fmt.Errorf("kind %q: want lower case letters, digits and -, such as issue or workflow-run", n.Kind)
	}
	if len(n.Ref) > maxRef || !refPattern.MatchString(n.Ref) {
		return fmt.Errorf("ref %q: want <scheme>:<id>, such as github:alexec/Agents#123 or session:<agent id>", n.Ref)
	}
	return nil
}

func checkWord(what, w string) error {
	if !kindPattern.MatchString(w) {
		return fmt.Errorf("%s %q: want lower case letters, digits and -, such as works-on", what, w)
	}
	return nil
}

// line is one line of lineage.jsonl: a link started, or a link ended.
type line struct {
	Link *wire.LineageLink      `json:"link,omitempty"`
	End  *wire.LineageEndRequest `json:"end,omitempty"`
	At   *wire.Date             `json:"at,omitempty"`
}

type key struct {
	from, to wire.LineageNode
	rel      string
}

func keyOf(l wire.LineageLink) key { return key{l.From, l.To, l.Rel} }

// Files is the store as files: every change is one line appended to path, and the file is
// written again whole, through a temporary file and a rename, when it has grown well past
// what is kept.
type Files struct {
	mu   sync.Mutex
	path string
	// links is every link kept, oldest start first.
	links []wire.LineageLink
	// active is the index in links of each active link.
	active map[key]int
	// byNode is the indexes in links of each node's links.
	byNode   map[wire.LineageNode][]int
	appended int
	file     *os.File
	now      func() time.Time
}

// Open reads path, keeping what it can: a line it cannot read is left out and the file set
// aside beside it, and a torn last line is dropped.
func Open(path string, now func() time.Time) *Files {
	f := &Files{path: path, now: now}
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Printf("%s: %v; starting with no links", filepath.Base(path), err)
	}
	var links []wire.LineageLink
	active := map[key]int{}
	raws := bytes.Split(data, []byte("\n"))
	for len(raws) > 0 && len(raws[len(raws)-1]) == 0 {
		raws = raws[:len(raws)-1]
	}
	unreadable := 0
	for i, raw := range raws {
		var l line
		if len(raw) == 0 {
			continue
		}
		bad := diskjson.Unmarshal(raw, &l) != nil
		switch {
		case !bad && l.Link != nil && checkNode(l.Link.From) == nil && checkNode(l.Link.To) == nil:
			// A rewritten file holds ended links whole.
			k := keyOf(*l.Link)
			if l.Link.EndedAt == nil {
				if _, on := active[k]; on {
					continue
				}
				active[k] = len(links)
			}
			links = append(links, *l.Link)
		case !bad && l.End != nil && l.At != nil:
			k := key{l.End.From, l.End.To, l.End.Rel}
			if i, on := active[k]; on {
				at := *l.At
				links[i].EndedAt = &at
				delete(active, k)
			}
		default:
			if i < len(raws)-1 {
				unreadable++
			}
		}
	}
	if unreadable > 0 {
		aside := fmt.Sprintf("%s.unreadable-%d", path, now().Unix())
		os.WriteFile(aside, data, 0o644)
		store.TrimSetAsides(path)
		log.Printf("%s: %d lines could not be read; the file is kept as %s", filepath.Base(path), unreadable, filepath.Base(aside))
	}
	f.links = links
	f.appended = len(raws)
	if f.prune() || unreadable > 0 {
		f.rewrite()
	} else {
		f.index()
	}
	return f
}

// index makes active and byNode again from links.
func (f *Files) index() {
	f.active = map[key]int{}
	f.byNode = map[wire.LineageNode][]int{}
	for i, l := range f.links {
		if l.EndedAt == nil {
			f.active[keyOf(l)] = i
		}
		f.byNode[l.From] = append(f.byNode[l.From], i)
		if l.To != l.From {
			f.byNode[l.To] = append(f.byNode[l.To], i)
		}
	}
}

// prune drops the ended links past KeepEnded, then the oldest past MostLinks, ended ones
// first. It says whether it dropped any.
func (f *Files) prune() bool {
	oldest := wire.DateOf(f.now().Add(-KeepEnded))
	kept := f.links[:0:0]
	for _, l := range f.links {
		if l.EndedAt == nil || *l.EndedAt >= oldest {
			kept = append(kept, l)
		}
	}
	if over := len(kept) - MostLinks; over > 0 {
		gone := map[int]bool{}
		for i := 0; i < len(kept) && len(gone) < over; i++ {
			if kept[i].EndedAt != nil {
				gone[i] = true
			}
		}
		for i := 0; i < len(kept) && len(gone) < over; i++ {
			gone[i] = true
		}
		var left []wire.LineageLink
		for i, l := range kept {
			if !gone[i] {
				left = append(left, l)
			}
		}
		kept = left
	}
	dropped := len(kept) != len(f.links)
	f.links = kept
	return dropped
}

func encode(l line) []byte {
	b, err := diskjson.Marshal(l)
	if err != nil {
		log.Printf("lineage: encode: %v", err)
		return nil
	}
	return append(b, '\n')
}

// rewrite writes every link kept, ended ones whole, and indexes them again.
func (f *Files) rewrite() {
	var buf bytes.Buffer
	for _, l := range f.links {
		buf.Write(encode(line{Link: &l}))
	}
	if f.file != nil {
		f.file.Close()
		f.file = nil
	}
	if err := store.WriteAtomically(f.path, buf.Bytes(), 0o644); err != nil {
		log.Printf("%s: could not rewrite: %v", filepath.Base(f.path), err)
	}
	f.appended = len(f.links)
	f.index()
}

// append writes one line with one write on an O_APPEND descriptor, so it lands whole; a
// file left ending in a torn line is given a newline first. The change is in links before,
// so a file written again whole here holds it.
func (f *Files) append(l line) error {
	b := encode(l)
	if b == nil {
		return errors.New("could not encode the link")
	}
	if f.file == nil {
		os.MkdirAll(filepath.Dir(f.path), 0o755)
		file, err := os.OpenFile(f.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
		if err != nil {
			return err
		}
		if endsTorn(f.path) {
			file.Write([]byte("\n"))
		}
		f.file = file
	}
	if _, err := f.file.Write(b); err != nil {
		f.file.Close()
		f.file = nil
		return err
	}
	f.appended++
	if f.appended > len(f.links)+rewriteMargin || len(f.links) > MostLinks+rewriteMargin/2 {
		f.prune()
		f.rewrite()
	}
	return nil
}

func endsTorn(path string) bool {
	r, err := os.Open(path)
	if err != nil {
		return false
	}
	defer r.Close()
	st, err := r.Stat()
	if err != nil || st.Size() == 0 {
		return false
	}
	last := make([]byte, 1)
	_, err = r.ReadAt(last, st.Size()-1)
	return err == nil && last[0] != '\n'
}

func (f *Files) Link(r wire.LineageLinkRequest, at time.Time) (wire.LineageLink, error) {
	if err := checkNode(r.From); err != nil {
		return wire.LineageLink{}, err
	}
	if err := checkNode(r.To); err != nil {
		return wire.LineageLink{}, err
	}
	if err := checkWord("rel", r.Rel); err != nil {
		return wire.LineageLink{}, err
	}
	if err := checkWord("source", r.Source); err != nil {
		return wire.LineageLink{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	l := wire.LineageLink{From: r.From, To: r.To, Rel: r.Rel, Source: r.Source, At: wire.DateOf(at)}
	k := keyOf(l)
	if i, on := f.active[k]; on {
		return f.links[i], nil
	}
	i := len(f.links)
	f.links = append(f.links, l)
	f.active[k] = i
	f.byNode[l.From] = append(f.byNode[l.From], i)
	if l.To != l.From {
		f.byNode[l.To] = append(f.byNode[l.To], i)
	}
	if err := f.append(line{Link: &l}); err != nil {
		// Not written, so not kept: the write failed before any rewrite.
		f.links = f.links[:i]
		f.index()
		return wire.LineageLink{}, err
	}
	return l, nil
}

func (f *Files) End(r wire.LineageEndRequest, at time.Time) ([]wire.LineageLink, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	k := key{r.From, r.To, r.Rel}
	i, on := f.active[k]
	if !on {
		return []wire.LineageLink{}, nil
	}
	end := wire.DateOf(at)
	f.links[i].EndedAt = &end
	delete(f.active, k)
	ended := f.links[i]
	if err := f.append(line{End: &r, At: &end}); err != nil {
		f.links[i].EndedAt = nil
		f.active[k] = i
		return nil, err
	}
	return []wire.LineageLink{ended}, nil
}

// linksOf is the indexes in links of a node's links, newest start first. Under mu.
func (f *Files) linksOf(n wire.LineageNode) []int {
	idx := f.byNode[n]
	out := make([]int, 0, len(idx))
	for i := len(idx) - 1; i >= 0; i-- {
		out = append(out, idx[i])
	}
	return out
}

func (f *Files) Links(n wire.LineageNode) wire.LineageLinks {
	f.mu.Lock()
	defer f.mu.Unlock()
	idx := f.linksOf(n)
	out := wire.LineageLinks{Links: make([]wire.LineageLink, 0, min(len(idx), MostAnswer))}
	for _, i := range idx[:min(len(idx), MostAnswer)] {
		out.Links = append(out.Links, f.links[i])
	}
	if len(idx) > MostAnswer {
		t := true
		out.Limited = &t
	}
	return out
}

func (f *Files) Walk(n wire.LineageNode, depth int) wire.LineageGraph {
	if depth <= 0 {
		depth = DefaultDepth
	}
	depth = min(depth, MostDepth)
	f.mu.Lock()
	defer f.mu.Unlock()
	seen := map[wire.LineageNode]bool{n: true}
	g := wire.LineageGraph{Nodes: []wire.LineageNode{n}, Links: []wire.LineageLink{}}
	went := map[int]bool{}
	limited := false
	edge := []wire.LineageNode{n}
	for range depth {
		var next []wire.LineageNode
		for _, at := range edge {
			for _, i := range f.linksOf(at) {
				if went[i] {
					continue
				}
				l := f.links[i]
				other := l.To
				if other == at {
					other = l.From
				}
				if !seen[other] {
					if len(g.Nodes) >= MostNodes {
						limited = true
						continue
					}
					seen[other] = true
					g.Nodes = append(g.Nodes, other)
					next = append(next, other)
				}
				went[i] = true
				g.Links = append(g.Links, l)
			}
		}
		edge = next
	}
	sort.SliceStable(g.Links, func(i, j int) bool { return g.Links[i].At > g.Links[j].At })
	if limited {
		g.Limited = &limited
	}
	return g
}

func (f *Files) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.file == nil {
		return nil
	}
	err := f.file.Close()
	f.file = nil
	return err
}
