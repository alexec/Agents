package mcpevents

import (
	"slices"
	"testing"
)

func TestBlockedKeepsAFailureWhileItsRerunRuns(t *testing.T) {
	failed := Blocking{HeadSHA: "h", Conflict: true, FailedChecks: []FailedCheck{{Name: "go"}}}
	first := Blocked("pr.blocked:o/r:1", failed, nil)
	if first.ID != "pr.blocked:o/r:1:h:conflict,required_check_failed" || !first.On {
		t.Fatalf("first %+v", first)
	}
	rerun := Blocked("pr.blocked:o/r:1", Blocking{HeadSHA: "h", Conflict: true, ChecksRunning: true}, []string{first.ID})
	if rerun.ID != first.ID {
		t.Fatalf("a rerun on the same head keeps its failure: %s", rerun.ID)
	}
	pushed := Blocked("pr.blocked:o/r:1", Blocking{HeadSHA: "g", Conflict: true, ChecksRunning: true}, []string{first.ID})
	if pushed.ID != "pr.blocked:o/r:1:g:conflict" {
		t.Fatalf("a new head forgets it: %s", pushed.ID)
	}
	unknown := Blocked("pr.blocked:o/r:1", Blocking{HeadSHA: "g", Unknown: true}, []string{"pr.blocked:o/r:2:x:behind", first.ID})
	if unknown.ID != first.ID || !unknown.On {
		t.Fatalf("unknown keeps the last state: %+v", unknown)
	}
	if none := Blocked("pr.blocked:o/r:1", Blocking{HeadSHA: "g", Unknown: true}, nil); none.On {
		t.Fatalf("unknown with no last state: %+v", none)
	}
	clean := Blocked("pr.blocked:o/r:1", Blocking{HeadSHA: "g"}, []string{first.ID})
	if clean.On || len(clean.Data["reasons"].([]any)) != 0 {
		t.Fatalf("clean %+v", clean)
	}
	if !SkipsBlocked(false, []string{"x", "needs-approval"}) || !SkipsBlocked(true, nil) || SkipsBlocked(false, nil) {
		t.Fatal("skips")
	}
	if !slices.Equal(BlockedReasons, []string{"conflict", "required_check_failed", "changes_requested", "automerge_disabled", "behind"}) {
		t.Fatal("order")
	}
}
