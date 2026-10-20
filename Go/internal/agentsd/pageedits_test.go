package agentsd

import (
	"fmt"
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
