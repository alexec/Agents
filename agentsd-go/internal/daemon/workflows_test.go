package daemon

import "testing"

// A workflow switched off and fired by its clock is refused: an outcome, no firing. Its
// summary must not need a firing time (it crashed the host on 2026-10-16).
func TestRefusedWorkflowSummary(t *testing.T) {
	b := []byte("---\nname: Off\ncron: \"* * * * *\"\n---\nSay hi.\n")
	w := parseWorkflow("/x", "off", b)
	w.Enabled = false
	w.lastOutcome = map[string]any{"refused": map[string]any{"_0": map[string]any{"disabled": map[string]any{}}}}
	s := w.summary(10, nil)
	if _, ok := s["lastFiredAt"]; ok {
		t.Fatalf("a refused run has no lastFiredAt: %v", s)
	}
	if s["isEnabled"] != false {
		t.Fatalf("isEnabled: %v", s["isEnabled"])
	}
}
