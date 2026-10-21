package agentsd

import (
	"fmt"
	"maps"
	"math/rand/v2"
	goruntime "runtime"
	"slices"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Passages are runs of lines between blank lines, with a fence kept whole and its lines
// counted from one (PassageTests).
func TestPassagesSplitOnBlankLinesAndKeepFencesWhole(t *testing.T) {
	got := splitPassages("\n# Title\n\nOne.\nTwo.\n\n\n```\na\n\nb\n```\n")
	want := []passage{{"\n# Title", 1, 2}, {"One.\nTwo.", 4, 5}, {"```\na\n\nb\n```", 8, 12}}
	if !slices.Equal(got, want) {
		t.Fatalf("%+v", got)
	}
	if splitPassages("") != nil || splitPassages("\n\n") != nil {
		t.Fatal("an empty document has passages")
	}
}

// What changed is said in passages of the new text (PassageTests, "What changed").
func TestChangedPassagesAreThePassagesOfTheNewText(t *testing.T) {
	for _, tc := range []struct {
		old, new string
		want     []int
	}{
		{"A\n\nB", "A\n\nB", nil},
		{"A\n\nB", "A\n\nB\n\nC", []int{2}},
		{"A\n\nB one\n\nC", "A\n\nB two\n\nC", []int{1}},
		{"A\n\nB\n\nC\n\nD", "A!\n\nB\n\nC\n\nD!", []int{0, 3}},
		{"A\n\nB\n\nC", "A\n\nC", []int{1}},
		{"A\n\nB\n\nC", "A\n\nB", []int{1}},
		{"A\n\nB", "X\n\nY\n\nZ", []int{0, 1, 2}},
		{"", "X\n\nY", []int{0, 1}},
		{"X\n\nY", "", nil},
	} {
		if got := changedPassages(tc.old, tc.new); !slices.Equal(got, tc.want) {
			t.Errorf("%q → %q: %v, want %v", tc.old, tc.new, got, tc.want)
		}
	}
}

// The note quotes each passage under its file, in line order, and says what to do
// (specs/022-live-artifacts/contracts/daemon-api.md).
func TestThePageEditNoteQuotesEachPassage(t *testing.T) {
	if pageEditNote(nil, false) != "" {
		t.Fatal("a note for nothing")
	}
	note := pageEditNote([]pageEdit{{"/p/notes.md", 20, 21, "Later."}, {"/p/notes.md", 3, 3, "Earlier."}, {"/p/b.md", 1, 1, "B."}}, false)
	if !strings.HasPrefix(note, "Since your last turn I edited `/p/notes.md`. Lines 3–3 now read:\n\n```\nEarlier.\n```\n\nLines 20–21 now read:") ||
		strings.Count(note, "I edited `/p/notes.md`") != 1 || !strings.Contains(note, "I edited `/p/b.md`") ||
		!strings.HasSuffix(note, "Work from what is there now; do not restore what you wrote before.") {
		t.Fatal(note)
	}
}

// The person's edits are held until the agent's next turn and told once; past twenty the
// note says to read the file.
func TestPageEditsAreToldOnceAndBounded(t *testing.T) {
	var p pageEdits
	agent := wire.UUID("A")
	p.remember(agent, "/p/n.md", "A\n\nB", "A\n\nB two")
	p.remember(agent, "/p/n.md", "A\n\nB two", "A\n\nB three")
	if note := p.take(agent); strings.Count(note, "now read:") != 1 || !strings.Contains(note, "B three") {
		t.Fatal(note)
	}
	if note := p.take(agent); note != "" {
		t.Fatal(note)
	}
	var old, doc []string
	for i := range 21 {
		old = append(old, fmt.Sprint(i))
		doc = append(doc, fmt.Sprintf("Line %d.", i))
	}
	p.remember(agent, "/p/n.md", strings.Join(old, "\n\n"), strings.Join(doc, "\n\n"))
	if note := p.take(agent); strings.Count(note, "now read:") != pageEditLimit || !strings.Contains(note, "…and more. Read the file before changing it.") {
		t.Fatal(note)
	}
}

// lineDiffTable is lineDiff as it was before #1853, with the whole table, to hold the bit
// table to the same answers.
func lineDiffTable(a, b []string) (inserted, removed map[int]bool) {
	inserted, removed = map[int]bool{}, map[int]bool{}
	lcs := make([][]int, len(a)+1)
	for i := range lcs {
		lcs[i] = make([]int, len(b)+1)
	}
	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else {
				lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
			}
		}
	}
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		switch {
		case i < len(a) && j < len(b) && a[i] == b[j]:
			i, j = i+1, j+1
		case j < len(b) && (i == len(a) || lcs[i][j+1] >= lcs[i+1][j]):
			inserted[j] = true
			j++
		default:
			removed[i] = true
			i++
		}
	}
	return
}

// The bit table gives the whole table's answers, on lines with many repeats.
func TestLineDiffMatchesTheWholeTable(t *testing.T) {
	r := rand.New(rand.NewPCG(1, 2))
	lines := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = []string{"", "a", "b", "c", "d"}[r.IntN(5)]
		}
		return out
	}
	for range 500 {
		a, b := lines(r.IntN(40)), lines(r.IntN(40))
		// Unlike lineDiff, the reference trims nothing; a differing first and last line keep
		// lineDiff from trimming either, so both see the same lines.
		a, b = append(append([]string{"x"}, a...), "y"), append(append([]string{"z"}, b...), "w")
		gi, gr := lineDiff(a, b)
		wi, wr := lineDiffTable(a, b)
		if !maps.Equal(gi, wi) || !maps.Equal(gr, wr) {
			t.Fatalf("%q -> %q: %v %v, want %v %v", a, b, gi, gr, wi, wr)
		}
	}
}

// pageEditedFarApart is a 2,000-line page and the same page edited near lines 10 and 1990,
// which fills the table between them (#1853).
func pageEditedFarApart() (string, string) {
	var lines []string
	for i := range 1600 {
		lines = append(lines, fmt.Sprintf("Line %d of the page.", i))
		if i%5 == 4 {
			lines = append(lines, "")
		}
	}
	old := strings.Join(lines, "\n")
	lines[10], lines[len(lines)-12] = "Edited near the top.", "Edited near the end."
	return old, strings.Join(lines, "\n")
}

// A save of a long page edited far apart allocates under 2 MB, not the 31 MB the whole
// table took, and marks only the two passages edited.
func TestChangedPassagesIsBounded(t *testing.T) {
	old, new := pageEditedFarApart()
	if got := changedPassages(old, new); len(got) != 2 {
		t.Fatalf("changed %v", got)
	}
	var before, after goruntime.MemStats
	goruntime.GC()
	goruntime.ReadMemStats(&before)
	changedPassages(old, new)
	goruntime.ReadMemStats(&after)
	if n := after.TotalAlloc - before.TotalAlloc; n > 2<<20 {
		t.Fatalf("allocated %d bytes", n)
	}
}

func BenchmarkChangedPassagesFarApart(b *testing.B) {
	old, new := pageEditedFarApart()
	b.ReportAllocs()
	for b.Loop() {
		changedPassages(old, new)
	}
}
