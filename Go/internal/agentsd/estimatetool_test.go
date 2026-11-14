package agentsd

import (
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

// A closed issue says its estimate against what it took, in Work's words (#3590).
func TestEstimateWordsSaysTheEstimateAgainstTheActual(t *testing.T) {
	work := 3*3600.0 + 14*60
	level := "epic"
	open, closed := int64(0), int64(3)
	e := wire.LineageEstimate{
		Node: wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#3557"}, Level: &level,
		OpenChildren: &open, ClosedChildren: &closed,
		Kept:   &wire.LineageEstimateKept{Matches: 12, Cost: map[string]float64{"USD": 5.57}, WorkingSeconds: &work},
		Actual: &wire.LineageCost{Cost: map[string]float64{"USD": 6.17}, WorkingSeconds: 2*3600 + 40*60},
	}
	got := estimateWords(e)
	for _, want := range []string{
		"github:issue:alexec/agents#3557 (epic)",
		"Children: 0 open, 3 closed.",
		"Closed. Estimated $5.57, 3h 14m of work; actual $6.17, 2h 40m of work.",
		"No open children, so nothing is left to estimate.",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("no %q in\n%s", want, got)
		}
	}
}

// An open issue says the median and the range of each figure.
func TestEstimateWordsSaysTheFigures(t *testing.T) {
	by := "level"
	e := wire.LineageEstimate{
		Node: wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#7"}, MatchedBy: &by, Matches: 31, ClosedIssues: 80,
		Cost:           map[string]wire.LineageEstimateRange{"USD": {Median: 3.2, P10: 1.1, P90: 9.8}},
		WorkingSeconds: &wire.LineageEstimateRange{Median: 7800, P10: 1800, P90: 21600},
	}
	got := estimateWords(e)
	for _, want := range []string{"from 31 closed issues (matched by the same type and level)", "- Cost: $3.20 ($1.10 to $9.80)", "- Agents' work: 2h 10m (30m to 6h 0m)"} {
		if !strings.Contains(got, want) {
			t.Errorf("no %q in\n%s", want, got)
		}
	}
	if strings.Contains(got, "Closed") {
		t.Errorf("an open issue says it is closed:\n%s", got)
	}
	e.Cost, e.WorkingSeconds = nil, nil
	if got := estimateWords(e); !strings.Contains(got, "Not enough past work to estimate") {
		t.Errorf("%s", got)
	}
}

// A ref is taken as it is; a bare word is not an issue.
func TestEstimateNodeTakesARef(t *testing.T) {
	d := &Daemon{}
	n, err := d.estimateNode("", "linear:issue:eng#ENG-4")
	if err != nil || n.Ref != "linear:issue:eng#ENG-4" || n.Kind != "issue" {
		t.Fatalf("%+v %v", n, err)
	}
	if _, err := d.estimateNode("", "soon"); err == nil {
		t.Fatal("a word was taken as an issue")
	}
	if _, err := d.estimateNode("", " "); err == nil {
		t.Fatal("nothing was taken as an issue")
	}
}
