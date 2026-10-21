package agentsd

import (
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/wire"
)

// Page edits (022 FR-016): the person typed on a live page, artifact/write put it on disk,
// and the agent is told on its next turn which passages are no longer the ones it wrote.
// Its own folder watch cannot tell its writes from the person's; the moment of the write is
// the one moment that is known. Only the note is held, in memory: the edit itself is in the
// file, and a daemon that restarts forgets the note by design (DaemonCore+Artifacts).

// pageEdit is one passage the person changed: its lines in the document as written,
// counted from one, and its text.
type pageEdit struct {
	path        string
	first, last int
	text        string
}

// pageEditLimit is the most held per agent and the most the note quotes; past it the note
// says to read the file.
const pageEditLimit = 20

type pageEdits struct {
	mu      sync.Mutex
	byAgent map[wire.UUID][]pageEdit
	// more is the agents that had edits dropped past the limit.
	more map[wire.UUID]bool
}

// remember is rememberArtifactEdits: the passages of written that changed from previous,
// a passage edited twice before the agent's next turn held once with its later text.
func (p *pageEdits) remember(agent wire.UUID, path, previous, written string) {
	passages := splitPassages(written)
	changed := changedPassages(previous, written)
	if len(changed) == 0 {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.byAgent == nil {
		p.byAgent, p.more = map[wire.UUID][]pageEdit{}, map[wire.UUID]bool{}
	}
	edits := p.byAgent[agent]
	for _, i := range changed {
		ps := passages[i]
		kept := edits[:0]
		for _, e := range edits {
			if e.path != path || e.first != ps.first || e.last != ps.last {
				kept = append(kept, e)
			}
		}
		edits = append(kept, pageEdit{path: path, first: ps.first, last: ps.last, text: ps.source})
	}
	if len(edits) > pageEditLimit {
		edits = append([]pageEdit(nil), edits[len(edits)-pageEditLimit:]...)
		p.more[agent] = true
	}
	p.byAgent[agent] = edits
}

// take is the note for agent's next turn, "" when the person changed nothing; told once.
func (p *pageEdits) take(agent wire.UUID) string {
	p.mu.Lock()
	edits, more := p.byAgent[agent], p.more[agent]
	delete(p.byAgent, agent)
	delete(p.more, agent)
	p.mu.Unlock()
	return pageEditNote(edits, more)
}

// pageEditNote is Briefing.artifactEdited: each changed passage quoted, not named, since an
// agent told "lines 12–15 changed" may read its own last version and put it back.
func pageEditNote(edits []pageEdit, more bool) string {
	if len(edits) == 0 {
		return ""
	}
	var paths []string
	byPath := map[string][]pageEdit{}
	for _, e := range edits {
		if byPath[e.path] == nil {
			paths = append(paths, e.path)
		}
		byPath[e.path] = append(byPath[e.path], e)
	}
	var paragraphs []string
	for _, path := range paths {
		es := byPath[path]
		sort.SliceStable(es, func(i, j int) bool { return es[i].first < es[j].first })
		blocks := make([]string, len(es))
		for i, e := range es {
			blocks[i] = fmt.Sprintf("Lines %d–%d now read:\n\n```\n%s\n```", e.first, e.last, e.text)
		}
		paragraphs = append(paragraphs, "Since your last turn I edited `"+path+"`. "+strings.Join(blocks, "\n\n"))
	}
	if more {
		paragraphs = append(paragraphs, "…and more. Read the file before changing it.")
	}
	paragraphs = append(paragraphs, "Work from what is there now; do not restore what you wrote before.")
	return strings.Join(paragraphs, "\n\n")
}

// passage is Passage: a run of source lines between blank lines, a fenced block kept whole.
type passage struct {
	source      string
	first, last int
}

func isBlankLine(l string) bool { return strings.Trim(l, " \t") == "" }

// opensFence is up to three spaces, then three or more backticks or tildes.
func opensFence(l string) (byte, int, bool) {
	t := strings.TrimLeft(l, " ")
	if len(l)-len(t) > 3 || t == "" || t[0] != '`' && t[0] != '~' {
		return 0, 0, false
	}
	run := len(t) - len(strings.TrimLeft(t, t[:1]))
	if run < 3 || t[0] == '`' && strings.Contains(t[run:], "`") {
		return 0, 0, false
	}
	return t[0], run, true
}

func closesFence(l string, c byte, n int) bool {
	t := strings.TrimLeft(l, " ")
	if len(l)-len(t) > 3 {
		return false
	}
	run := len(t) - len(strings.TrimLeft(t, string(c)))
	return run >= n && isBlankLine(t[run:])
}

// splitPassages is Passage.split: leading blank lines belong to the first passage.
func splitPassages(text string) []passage {
	if text == "" {
		return nil
	}
	lines := strings.Split(text, "\n")
	count := len(lines)
	if strings.HasSuffix(text, "\n") {
		count--
	}
	var out []passage
	var current []string
	start := 1
	var fenceChar byte
	fenceLen := 0
	allBlank := func() bool {
		for _, l := range current {
			if !isBlankLine(l) {
				return false
			}
		}
		return true
	}
	for i := 0; i < count; {
		line, number := lines[i], i+1
		switch {
		case fenceLen > 0:
			current = append(current, line)
			if closesFence(line, fenceChar, fenceLen) {
				fenceLen = 0
			}
			i++
		case isBlankLine(line) && len(current) > 0 && !allBlank():
			out = append(out, passage{source: strings.Join(current, "\n"), first: start, last: number - 1})
			current = nil
			for i < count && isBlankLine(lines[i]) {
				i++
			}
			start = i + 1
		case isBlankLine(line):
			current = append(current, line)
			i++
		default:
			if len(current) == 0 {
				start = number
			}
			if c, n, ok := opensFence(line); ok {
				fenceChar, fenceLen = c, n
			}
			current = append(current, line)
			i++
		}
	}
	if len(current) > 0 && !allBlank() {
		out = append(out, passage{source: strings.Join(current, "\n"), first: start, last: count})
	}
	return out
}

// passageHolding is Passage.index(containing:in:): a line in the blank run after a passage
// is that passage's, one past the end is the last.
func passageHolding(line int, ps []passage) int {
	if line < 1 || len(ps) == 0 {
		return -1
	}
	before := 0
	for i, p := range ps {
		if line >= p.first && line <= p.last {
			return i
		}
		if p.last < line {
			before = i
		}
	}
	return before
}

// lineDiffLimit bounds the table the line diff fills: past it, every line between the
// common start and end counts as changed.
const lineDiffLimit = 4_000_000

// lineDiff is the lines of new that were inserted and the lines of old that were removed,
// by index, from a longest common subsequence.
func lineDiff(old, new []string) (inserted, removed map[int]bool) {
	inserted, removed = map[int]bool{}, map[int]bool{}
	pre := 0
	for pre < len(old) && pre < len(new) && old[pre] == new[pre] {
		pre++
	}
	suf := 0
	for suf < len(old)-pre && suf < len(new)-pre && old[len(old)-1-suf] == new[len(new)-1-suf] {
		suf++
	}
	a, b := old[pre:len(old)-suf], new[pre:len(new)-suf]
	if len(a)*len(b) > lineDiffLimit {
		for i := range a {
			removed[pre+i] = true
		}
		for j := range b {
			inserted[pre+j] = true
		}
		return
	}
	// The longest common run of a[i:] and b[j:] is filled a row at a time, two rows kept;
	// of each cell only the way back is kept, one bit (#1853): whether
	// an insertion goes before a removal there. A 4M-cell table is ~500 KB, not 32 MB.
	n := len(b)
	below, row := make([]int32, n+1), make([]int32, n+1)
	insertFirst := make([]uint64, (len(a)*n+63)/64)
	for i := len(a) - 1; i >= 0; i-- {
		for j := n - 1; j >= 0; j-- {
			if a[i] == b[j] {
				row[j] = below[j+1] + 1
				continue
			}
			row[j] = max(below[j], row[j+1])
			if row[j+1] >= below[j] {
				c := i*n + j
				insertFirst[c/64] |= 1 << (c % 64)
			}
		}
		below, row = row, below
	}
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		switch {
		case i < len(a) && j < len(b) && a[i] == b[j]:
			i, j = i+1, j+1
		case j < len(b) && (i == len(a) || insertFirst[(i*n+j)/64]&(1<<((i*n+j)%64)) != 0):
			inserted[pre+j] = true
			j++
		default:
			removed[pre+i] = true
			i++
		}
	}
	return
}

// changedPassages is PassageChange.between(old:new:).changed: the passages of new holding a
// line that is new, or that now sits where lines were removed with nothing put in their
// place. Inserted blank lines count only when nothing else does: an appended paragraph
// brings the blank line before it, which belongs to the unchanged passage above.
func changedPassages(old, new string) []int {
	split := func(s string) []string {
		if s == "" {
			return nil
		}
		return strings.Split(s, "\n")
	}
	oldLines, newLines := split(old), split(new)
	inserted, removed := lineDiff(oldLines, newLines)
	if len(newLines) == 0 || len(inserted)+len(removed) == 0 {
		return nil
	}
	marked, blank := map[int]bool{}, map[int]bool{}
	for j := range inserted {
		if isBlankLine(newLines[j]) {
			blank[j+1] = true
		} else {
			marked[j+1] = true
		}
	}
	// Retained old and new lines pair up in order: the old-to-new map.
	newAt := map[int]int{}
	var retainedOld []int
	for i, j := 0, 0; i < len(oldLines); i++ {
		if removed[i] {
			continue
		}
		for inserted[j] {
			j++
		}
		newAt[i] = j
		retainedOld = append(retainedOld, i)
		j++
	}
	for r := range removed {
		prev, next := -1, len(newLines)
		for _, i := range retainedOld {
			if i < r {
				prev = newAt[i]
			} else if i > r {
				next = newAt[i]
				break
			}
		}
		if next == prev+1 {
			marked[min(next, len(newLines)-1)+1] = true
		}
	}
	if len(marked) == 0 {
		marked = blank
	}
	passages := splitPassages(new)
	seen := map[int]bool{}
	var out []int
	for line := range marked {
		if i := passageHolding(line, passages); i >= 0 && !seen[i] {
			seen[i] = true
			out = append(out, i)
		}
	}
	sort.Ints(out)
	return out
}
