// Package lineage is the graph of the SDLC (#2348, spec 2348-lineage): typed nodes (an
// issue, a pull request, a session, a workflow run, a commit, ...) and typed links between
// them (works-on, opens, fixes, ...). The store holds only links, so many-to-many needs
// nothing more: a node is in the graph while a link names it.
//
// A session node also has a state (#4274): working, waiting, needs-you, stopped, archived or
// deleted, each change with its time, so the graph says what each session is doing now.
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

	"github.com/agentloops-dev/agents/Go/internal/agentsd/diskjson"
	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/repoalias"
	"github.com/agentloops-dev/agents/Go/wire"
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
	KindWorkflow    = "workflow"
	KindRelease     = "release"
	// KindDoc is a doc behind the work (#3308): a file under specs/ or docs/, or a docs page.
	KindDoc = "doc"
	// KindCIRun is a forge's CI run (#3581): a GitHub Actions run or a GitLab pipeline. Not
	// KindWorkflowRun, which is an Agents workflow's run.
	KindCIRun = "ci-run"
	// KindHealth is a health signal (#3585): a Sentry issue, sentry:<org>/<issue id>.
	KindHealth = "health"
	// KindDeploy is a build or a version put on a deploy target (#3584), as a TestFlight build:
	// testflight:<bundle id>/<build>, or a version submitted for App Review (#3657):
	// appstore:<bundle id>/<version>. KindTarget is where it went: target:testflight:<bundle id>.
	KindDeploy = "deploy"
	KindTarget = "target"

	RelWorksOn = "works-on"
	RelOpens   = "opens"
	RelFixes   = "fixes"
	RelStarted = "started"
	RelReviews = "reviews"
	RelCloses  = "closes"
	RelPartOf  = "part-of"
	// RelReads and RelLinksTo are a session that read a doc, or named it in what it said (#3308).
	RelReads   = "reads"
	RelLinksTo = "links-to"
	// RelBuilds is a CI run that builds a PR, or the release of the tag it ran on (#3581).
	RelBuilds = "builds"
	// RelSeenIn is a health signal seen in a release or a deploy (#3585).
	RelSeenIn = "seen-in"
	// RelDeployedAs is a release deployed as a deploy (#3584); the deploy is part-of its target.
	// A TestFlight build is deployed-as the App Store version it was submitted as (#3657).
	RelDeployedAs = "deployed-as"
	// RelReports is an issue filed for a health signal, or commented on for it (#3586).
	RelReports = "reports"

	SourceStart  = "start"
	SourceBranch = "branch"
	SourcePRBody = "pr-body"
	SourceHelper = "helper"
	SourceAgent  = "agent"
	SourcePerson = "person"
	// SourceForge is a link the forge says, such as an issue part-of its parent epic (#3582).
	SourceForge = "forge"
	// SourceHealth is a link a health source says, such as Sentry's release of an issue (#3585).
	SourceHealth = "health"
)

// The bounds (#2348; "Bound data, not concurrency"). An ended link is kept KeepEnded after
// its end; at most MostLinks are kept, the oldest ended ones going first, then the oldest
// active ones. A change of state is kept KeepEnded too, except each node's latest; at most
// MostStates are kept, the oldest that are not a node's latest going first (#4274). An
// answer holds at most MostAnswer links or states, and a walk reaches at most MostNodes
// nodes, at most MostDepth links away.
const (
	KeepEnded    = 90 * 24 * time.Hour
	MostLinks    = 20_000
	MostStates   = 20_000
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
	// Walk is the graph within depth links of a node, either way, with the state now of
	// each node in it that has one.
	Walk(n wire.LineageNode, depth int) wire.LineageGraph
	// SetState records that a node's state changed to state at at (#4274), unless it is in
	// that state already, and says whether it recorded it. Links says a node's changes.
	SetState(n wire.LineageNode, state wire.LineageSessionStateName, at time.Time) (bool, error)
	// All is every link and every change of state kept, each oldest first: a machine's
	// whole send to its control plane (#4275).
	All() ([]wire.LineageLink, []wire.LineageStateChange)
	// Prune drops what is past the bounds now, not only at open or on a long append
	// (#3649), and says how many links it dropped.
	Prune() int
	// Canon is a node as the store names it (#4800): the full ref form, and an agents node
	// (a session, a workflow, a workflow's run) with the topic the store has for its id.
	Canon(n wire.LineageNode) wire.LineageNode
	// Close writes what is left and lets the file go.
	Close() error
}

// Topics is the topic of an agents node whose old form did not say it (#4800): the project
// repo of a session, by its id, or of a workflow, by its folder and name. "" when it is not
// known. Open asks it only for the lines it reads in the old form.
type Topics func(kind, id string) string

// Full is a node in the full ref form (#4800, spec 4724-event-bus, "A ref"): a ref in the old
// form is read through wire.RefFromLineage, with topic as the project of an agents node; a
// form it does not know is kept as it is.
func Full(n wire.LineageNode, topic string) wire.LineageNode {
	if r, ok := wire.RefFromLineage(n.Kind, n.Ref, wire.RefContext{Topic: topic}); ok {
		n.Ref = r.String()
	}
	return n
}

// ParseNode is a node's ref, parsed; ok is false for a ref that is not in the full form.
func ParseNode(n wire.LineageNode) (wire.Ref, bool) {
	r, err := wire.ParseRef(n.Ref)
	return r, err == nil
}

// agentsKey is an agents node's identity: its type and id. Its topic is not part of it, so
// a session written with its project and read without one is one node.
func agentsKey(r wire.Ref) string { return r.Type + "#" + r.ID }

var (
	kindPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,39}$`)
	refPattern  = regexp.MustCompile(`^[a-z][a-z0-9-]{0,19}:\S`)
)

// maxRef bounds a ref, so one line stays small.
const maxRef = 512

// CheckNode says what is wrong with a node's kind or ref, or nil.
func CheckNode(n wire.LineageNode) error { return checkNode(n) }

// CheckWord says what is wrong with a relationship or a source, or nil.
func CheckWord(what, w string) error { return checkWord(what, w) }

func checkNode(n wire.LineageNode) error {
	if !kindPattern.MatchString(n.Kind) {
		return fmt.Errorf("kind %q: want lower case letters, digits and -, such as issue or workflow-run", n.Kind)
	}
	if len(n.Ref) > maxRef || !refPattern.MatchString(n.Ref) {
		return fmt.Errorf("ref %q: want provider:type:topic#id, such as github:issue:alexec/agents#123", n.Ref)
	}
	return nil
}

func checkWord(what, w string) error {
	if !kindPattern.MatchString(w) {
		return fmt.Errorf("%s %q: want lower case letters, digits and -, such as works-on", what, w)
	}
	return nil
}

// line is one line of lineage.jsonl: a link started, a link ended, or a node's change of
// state (with At).
type line struct {
	Link  *wire.LineageLink       `json:"link,omitempty"`
	End   *wire.LineageEndRequest `json:"end,omitempty"`
	State *stateLine              `json:"state,omitempty"`
	At    *wire.Date              `json:"at,omitempty"`
}

type stateLine struct {
	Node  wire.LineageNode             `json:"node"`
	State wire.LineageSessionStateName `json:"state"`
}

// change is a node's change of state, as Files keeps it.
type change struct {
	node wire.LineageNode
	wire.LineageSessionState
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
	byNode map[wire.LineageNode][]int
	// states is every change of state kept, oldest first; stateOf is the indexes in states
	// of each node's changes.
	states  []change
	stateOf map[wire.LineageNode][]int
	// agentsTopic is the topic of each agents node in links and states, by agentsKey.
	agentsTopic map[string]string
	appended    int
	file        *os.File
	now         func() time.Time
}

// Open reads path, keeping what it can: a line it cannot read is left out and the file set
// aside beside it, and a torn last line is dropped.
//
// A line in the old ref form (before #4800) is read in the full form, topics saying the
// project of an agents node, and the file is written again in it.
func Open(path string, now func() time.Time) *Files { return OpenWith(path, now, nil) }

// OpenWith is Open, with topics for the agents nodes of lines in the old form.
func OpenWith(path string, now func() time.Time, topics Topics) *Files {
	f := &Files{path: path, now: now, agentsTopic: map[string]string{}}
	converted := false
	// A node named again only by a repo's move (#4957) does not write the file again.
	full := func(n *wire.LineageNode) {
		if _, ok := ParseNode(*n); ok {
			if m := f.canonLocked(*n); m != *n {
				converted = converted || f.unaliasedLocked(*n) != *n
				*n = m
			}
			f.noteTopic(*n)
			return
		}
		topic := ""
		if r, ok := wire.RefFromLineage(n.Kind, n.Ref, wire.RefContext{}); ok && r.Provider == "agents" && topics != nil {
			topic = topics(n.Kind, r.ID)
		}
		if m := f.canonLocked(Full(*n, topic)); m != *n {
			*n, converted = m, true
		}
		f.noteTopic(*n)
	}
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Printf("%s: %v; starting with no links", filepath.Base(path), err)
	}
	var links []wire.LineageLink
	var states []change
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
		if !bad {
			switch {
			case l.Link != nil:
				full(&l.Link.From)
				full(&l.Link.To)
			case l.End != nil:
				full(&l.End.From)
				full(&l.End.To)
			case l.State != nil:
				full(&l.State.Node)
			}
		}
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
		case !bad && l.State != nil && l.At != nil && checkNode(l.State.Node) == nil:
			states = append(states, change{l.State.Node, wire.LineageSessionState{State: l.State.State, At: *l.At}})
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
	f.links, f.states = links, states
	f.appended = len(raws)
	if f.prune() || unreadable > 0 || converted {
		f.rewrite()
	} else {
		f.index()
	}
	return f
}

// index makes active, byNode and stateOf again from links and states.
func (f *Files) index() {
	f.active = map[key]int{}
	f.byNode = map[wire.LineageNode][]int{}
	f.stateOf = map[wire.LineageNode][]int{}
	f.agentsTopic = map[string]string{}
	for i, c := range f.states {
		f.stateOf[c.node] = append(f.stateOf[c.node], i)
		f.noteTopic(c.node)
	}
	for i, l := range f.links {
		if l.EndedAt == nil {
			f.active[keyOf(l)] = i
		}
		f.byNode[l.From] = append(f.byNode[l.From], i)
		if l.To != l.From {
			f.byNode[l.To] = append(f.byNode[l.To], i)
		}
		f.noteTopic(l.From)
		f.noteTopic(l.To)
	}
}

// noteTopic keeps the topic of n when it is an agents node the store has none for. Under mu.
func (f *Files) noteTopic(n wire.LineageNode) {
	if r, ok := ParseNode(n); ok && r.Provider == "agents" {
		if _, known := f.agentsTopic[agentsKey(r)]; !known {
			f.agentsTopic[agentsKey(r)] = r.Topic
		}
	}
}

// Canon is n in the full form, with the topic the store has for an agents node's id.
func (f *Files) Canon(n wire.LineageNode) wire.LineageNode {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.canonLocked(n)
}

// canonLocked is Canon, under mu: a ref in the old form is read in the full form, and an
// agents node takes the topic the store has for its id, so it is one node whatever topic it
// is named with.
//
// A repo whose owner moved (#4957) is named by its name now, so a node stored before the
// move and one named after it are one node.
func (f *Files) canonLocked(n wire.LineageNode) wire.LineageNode { return f.canonWith(n, true) }

// unaliasedLocked is canonLocked with no repo's move: what the file would say.
func (f *Files) unaliasedLocked(n wire.LineageNode) wire.LineageNode { return f.canonWith(n, false) }

func (f *Files) canonWith(n wire.LineageNode, alias bool) wire.LineageNode {
	n = Full(n, "")
	r, ok := ParseNode(n)
	if !ok {
		return n
	}
	if moved := repoalias.Ref(r); alias && moved != r && moved.Check() == nil {
		r = moved
		n.Ref = r.String()
	}
	if r.Provider != "agents" {
		return n
	}
	if topic, known := f.agentsTopic[agentsKey(r)]; known && topic != r.Topic {
		if alias {
			topic = repoalias.Topic(r.Provider, topic)
		} else if topic == repoalias.Topic(r.Provider, r.Topic) {
			return n // only the move names it apart
		}
		r.Topic = topic
		n.Ref = r.String()
	}
	return n
}

// Realias names every node again by its repo's name now, in memory only, after the book of
// moved repos changed (#4957): links that are then the same link are one.
func (f *Files) Realias() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.agentsTopic = map[string]string{}
	for i := range f.states {
		f.states[i].node = f.canonLocked(f.states[i].node)
	}
	seen := map[key]bool{}
	links := f.links[:0]
	for _, l := range f.links {
		l.From, l.To = f.canonLocked(l.From), f.canonLocked(l.To)
		if l.EndedAt == nil {
			if seen[keyOf(l)] {
				continue
			}
			seen[keyOf(l)] = true
		}
		links = append(links, l)
	}
	f.links = links
	f.index()
}

// removedKindMilestone is the kind of a forge milestone's node, which #3878 removed: prune
// drops each link from or to one, and a milestone's shipped-in link to its release.
const removedKindMilestone = "milestone"

// prune drops what Bound drops, and the states past their bounds. It says whether it
// dropped any.
func (f *Files) prune() bool {
	kept := Bound(f.links, f.now())
	dropped := len(kept) != len(f.links)
	f.links = kept
	return f.pruneStates() || dropped
}

// Bound is links, oldest start first, within the bounds at now: the links of a removed
// kind go, the ended links past KeepEnded, then the oldest past MostLinks, ended ones
// first. The control plane's copy of a machine's links (#4275) is bounded by it too. links
// is not changed.
func Bound(links []wire.LineageLink, now time.Time) []wire.LineageLink {
	oldest := wire.DateOf(now.Add(-KeepEnded))
	kept := links[:0:0]
	for _, l := range links {
		if l.From.Kind == removedKindMilestone || l.To.Kind == removedKindMilestone {
			continue
		}
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
	return kept
}

// pruneStates drops the changes of state past KeepEnded that are not their node's latest,
// then the oldest past MostStates, those that are not a node's latest first. It says
// whether it dropped any.
func (f *Files) pruneStates() bool {
	oldest := wire.DateOf(f.now().Add(-KeepEnded))
	latest := map[wire.LineageNode]int{}
	for i, c := range f.states {
		latest[c.node] = i
	}
	gone := map[int]bool{}
	for i, c := range f.states {
		if c.At < oldest && latest[c.node] != i {
			gone[i] = true
		}
	}
	over := len(f.states) - len(gone) - MostStates
	for i := 0; i < len(f.states) && over > 0; i++ {
		if !gone[i] && latest[f.states[i].node] != i {
			gone[i] = true
			over--
		}
	}
	for i := 0; i < len(f.states) && over > 0; i++ {
		if !gone[i] {
			gone[i] = true
			over--
		}
	}
	if len(gone) == 0 {
		return false
	}
	kept := make([]change, 0, len(f.states)-len(gone))
	for i, c := range f.states {
		if !gone[i] {
			kept = append(kept, c)
		}
	}
	f.states = kept
	return true
}

func encode(l line) []byte {
	b, err := diskjson.Marshal(l)
	if err != nil {
		log.Printf("lineage: encode: %v", err)
		return nil
	}
	return append(b, '\n')
}

// rewrite writes every link kept, ended ones whole, then every change of state kept, and
// indexes them again.
func (f *Files) rewrite() {
	var buf bytes.Buffer
	for _, l := range f.links {
		buf.Write(encode(line{Link: &l}))
	}
	for _, c := range f.states {
		at := c.At
		buf.Write(encode(line{State: &stateLine{c.node, c.State}, At: &at}))
	}
	if f.file != nil {
		f.file.Close()
		f.file = nil
	}
	if err := store.WriteAtomically(f.path, buf.Bytes(), 0o644); err != nil {
		log.Printf("%s: could not rewrite: %v", filepath.Base(f.path), err)
	}
	f.appended = len(f.links) + len(f.states)
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
	if f.appended > len(f.links)+len(f.states)+rewriteMargin || len(f.links) > MostLinks+rewriteMargin/2 ||
		len(f.states) > MostStates+rewriteMargin/2 {
		f.prune()
		f.rewrite()
	}
	return nil
}

// Prune says how many links it dropped; changes of state it drops are not counted.
func (f *Files) Prune() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	before := len(f.links)
	if !f.prune() {
		return 0
	}
	f.rewrite()
	return before - len(f.links)
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
	r.From, r.To = f.canonLocked(r.From), f.canonLocked(r.To)
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
	f.noteTopic(l.From)
	f.noteTopic(l.To)
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
	r.From, r.To = f.canonLocked(r.From), f.canonLocked(r.To)
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

func (f *Files) SetState(n wire.LineageNode, state wire.LineageSessionStateName, at time.Time) (bool, error) {
	if err := checkNode(n); err != nil {
		return false, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	n = f.canonLocked(n)
	if s, ok := f.stateNow(n); ok && s.State == state {
		return false, nil
	}
	c := change{n, wire.LineageSessionState{State: state, At: wire.DateOf(at)}}
	i := len(f.states)
	f.states = append(f.states, c)
	f.stateOf[n] = append(f.stateOf[n], i)
	f.noteTopic(n)
	if err := f.append(line{State: &stateLine{n, state}, At: &c.At}); err != nil {
		f.states = f.states[:i]
		f.index()
		return false, err
	}
	return true, nil
}

// stateNow is a node's latest change of state. Under mu.
func (f *Files) stateNow(n wire.LineageNode) (wire.LineageSessionState, bool) {
	idx := f.stateOf[n]
	if len(idx) == 0 {
		return wire.LineageSessionState{}, false
	}
	return f.states[idx[len(idx)-1]].LineageSessionState, true
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
	n = f.canonLocked(n)
	idx := f.linksOf(n)
	out := wire.LineageLinks{Links: make([]wire.LineageLink, 0, min(len(idx), MostAnswer))}
	for _, i := range idx[:min(len(idx), MostAnswer)] {
		out.Links = append(out.Links, f.links[i])
	}
	if len(idx) > MostAnswer {
		t := true
		out.Limited = &t
	}
	states := f.stateOf[n]
	for i := len(states) - 1; i >= 0 && len(out.States) < MostAnswer; i-- {
		out.States = append(out.States, f.states[states[i]].LineageSessionState)
	}
	return out
}

func (f *Files) All() ([]wire.LineageLink, []wire.LineageStateChange) {
	f.mu.Lock()
	defer f.mu.Unlock()
	states := make([]wire.LineageStateChange, 0, len(f.states))
	for _, c := range f.states {
		states = append(states, wire.LineageStateChange{Node: c.node, State: c.State, At: c.At})
	}
	return append([]wire.LineageLink(nil), f.links...), states
}

func (f *Files) Walk(n wire.LineageNode, depth int) wire.LineageGraph {
	f.mu.Lock()
	defer f.mu.Unlock()
	return WalkOver(f.links, f.linksOf, f.stateNow, f.canonLocked(n), depth)
}

// WalkOver is the graph within depth links of n, either way, over links: linksOf is the
// indexes in links of a node's links, newest start first, and stateNow a node's latest state.
// A machine's own walk and the control plane's walk of its merged copy (#4276) are both this.
func WalkOver(links []wire.LineageLink, linksOf func(wire.LineageNode) []int,
	stateNow func(wire.LineageNode) (wire.LineageSessionState, bool), n wire.LineageNode, depth int) wire.LineageGraph {
	if depth <= 0 {
		depth = DefaultDepth
	}
	depth = min(depth, MostDepth)
	seen := map[wire.LineageNode]bool{n: true}
	g := wire.LineageGraph{Nodes: []wire.LineageNode{n}, Links: []wire.LineageLink{}}
	went := map[int]bool{}
	limited := false
	edge := []wire.LineageNode{n}
	for range depth {
		var next []wire.LineageNode
		for _, at := range edge {
			for _, i := range linksOf(at) {
				if went[i] {
					continue
				}
				l := links[i]
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
					// A doc is a leaf (#3308): many sessions read the same one, and the walk
					// does not go through it to their work.
					if other.Kind != KindDoc {
						next = append(next, other)
					}
				}
				went[i] = true
				g.Links = append(g.Links, l)
			}
		}
		edge = next
	}
	sort.SliceStable(g.Links, func(i, j int) bool { return g.Links[i].At > g.Links[j].At })
	for _, n := range g.Nodes {
		if s, ok := stateNow(n); ok {
			if g.States == nil {
				g.States = map[string]wire.LineageSessionState{}
			}
			g.States[n.Ref] = s
		}
	}
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
