package bitbucketmcp

import (
	"fmt"
	"testing"
)

// retry_pipeline (#3792) over the fake Bitbucket: a new run with the old run's target, on the
// same commit, without the links Bitbucket gives back.

func pipelineRun(build int, state string, target obj) obj {
	s := obj{"name": "COMPLETED", "result": obj{"name": state}}
	if state == "" {
		s = obj{"name": "IN_PROGRESS"}
	}
	return obj{"uuid": fmt.Sprintf("{p%d}", build), "build_number": build, "state": s, "target": target}
}

func TestARetryIsANewRunOfTheSameTarget(t *testing.T) {
	f := newFake(t)
	links := obj{"self": obj{"href": "https://api.bitbucket.org/c"}}
	f.pipelines[12] = pipelineRun(12, "FAILED", obj{"type": "pipeline_pullrequest_target", "source": "fix", "destination": "main",
		"commit": obj{"type": "commit", "hash": "abc", "links": links}, "destination_commit": obj{"hash": "def", "links": links},
		"selector": obj{"type": "pull-requests", "pattern": "**"}, "pullrequest": obj{"type": "pullrequest", "id": 3, "title": "Fix"}})
	f.pipelines[12]["variables"] = []obj{{"key": "MODE", "value": "fast"}}
	c := serve(t, f, false)

	out, ok := c.tool("retry_pipeline", map[string]any{"pipelineId": 12})
	if !ok {
		t.Fatalf("retry %v", out)
	}
	same(t, out, map[string]any{"retried": true, "pipelineId": float64(12), "newPipelineId": float64(13), "state": "PENDING",
		"commit": "abc", "url": "https://bitbucket.org/acme/app/pipelines/results/13"})
	f.mu.Lock()
	defer f.mu.Unlock()
	same(t, len(f.posted), 1)
	same(t, f.posted[0]["_path"], root+"/pipelines/")
	same(t, f.posted[0]["target"], map[string]any{"type": "pipeline_pullrequest_target", "source": "fix", "destination": "main",
		"commit": map[string]any{"type": "commit", "hash": "abc"}, "destination_commit": map[string]any{"hash": "def"},
		"selector": map[string]any{"type": "pull-requests", "pattern": "**"}, "pullrequest": map[string]any{"id": float64(3)}})
	same(t, f.posted[0]["variables"], []any{map[string]any{"key": "MODE", "value": "fast"}})
}

func TestARetryOfABranchRunKeepsItsCommit(t *testing.T) {
	f := newFake(t)
	f.pipelines[4] = pipelineRun(4, "ERROR", obj{"type": "pipeline_ref_target", "ref_type": "branch", "ref_name": "main",
		"commit": obj{"hash": "abc"}, "selector": obj{"type": "branches", "pattern": "main"}})
	c := serve(t, f, false)
	if out, ok := c.tool("retry_pipeline", map[string]any{"pipelineId": 4}); !ok || out["newPipelineId"] != float64(5) {
		t.Fatalf("retry %v", out)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	same(t, f.posted[0]["target"], map[string]any{"type": "pipeline_ref_target", "ref_type": "branch", "ref_name": "main",
		"commit": map[string]any{"type": "commit", "hash": "abc"}, "selector": map[string]any{"type": "branches", "pattern": "main"}})
	same(t, f.posted[0]["variables"], nil)
}

func TestARetryRefusesWhatItCannotRunAgain(t *testing.T) {
	f := newFake(t)
	f.pipelines[1] = pipelineRun(1, "", obj{"type": "pipeline_ref_target", "commit": obj{"hash": "abc"}})
	f.pipelines[2] = pipelineRun(2, "FAILED", obj{"type": "pipeline_ref_target", "commit": obj{"hash": "abc"}})
	f.pipelines[2]["variables"] = []obj{{"key": "TOKEN", "secured": true}}
	f.pipelines[3] = pipelineRun(3, "FAILED", obj{"type": "pipeline_ref_target"})
	c := serve(t, f, false)
	for _, args := range []map[string]any{{"pipelineId": 1}, {"pipelineId": 2}, {"pipelineId": 3}, {"pipelineId": 9}, {},
		{"pipelineId": 2, "repo": "not a repo"}} {
		if out, ok := c.tool("retry_pipeline", args); ok {
			t.Fatalf("%v worked: %v", args, out)
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	same(t, len(f.posted), 0)
}
