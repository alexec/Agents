package bitbucketmcp

import (
	"context"
	"fmt"
	"net/http"
)

// retry_pipeline (#3792): Pipelines' API 2.0 has no "rerun the failed steps", so a run is
// retried as a new run of the same pipeline on the same commit: its target, sent again to
// pipelines/. A run is named by its build number, as failed_log's is.

// commitRef is a commit in a target, by its hash only.
type commitRef struct {
	Type string `json:"type,omitempty"`
	Hash string `json:"hash"`
}

// targetJSON is a run's target: a branch, tag or bookmark (pipeline_ref_target), a commit
// (pipeline_commit_target), or a pull request (pipeline_pullrequest_target), with the
// pipeline it ran (selector). Only what a new run takes is kept: not the links.
type targetJSON struct {
	Type              string     `json:"type"`
	RefType           string     `json:"ref_type,omitempty"`
	RefName           string     `json:"ref_name,omitempty"`
	Source            string     `json:"source,omitempty"`
	Destination       string     `json:"destination,omitempty"`
	Commit            *commitRef `json:"commit,omitempty"`
	DestinationCommit *commitRef `json:"destination_commit,omitempty"`
	Selector          *struct {
		Type    string `json:"type"`
		Pattern string `json:"pattern,omitempty"`
	} `json:"selector,omitempty"`
	PullRequest *struct {
		ID int `json:"id"`
	} `json:"pullrequest,omitempty"`
}

type variableJSON struct {
	Key     string `json:"key"`
	Value   string `json:"value"`
	Secured bool   `json:"secured,omitempty"`
}

type pipelineJSON struct {
	UUID        string         `json:"uuid"`
	BuildNumber int            `json:"build_number"`
	Target      targetJSON     `json:"target"`
	Variables   []variableJSON `json:"variables"`
	State       struct {
		Name   string `json:"name"`
		Result struct {
			Name string `json:"name"`
		} `json:"result"`
	} `json:"state"`
}

// RetryPipeline starts a new run of the Pipelines run with build number run: the same
// pipeline, on the same commit, with the same variables. A run that has not ended is not
// retried, nor one with a secured variable, whose value Bitbucket never gives back.
func (b *RealBitbucket) RetryPipeline(ctx context.Context, repo string, run int) (map[string]any, error) {
	var old pipelineJSON
	if err := b.send(ctx, http.MethodGet, fmt.Sprintf("%s/pipelines/%d", repoPath(repo), run), nil, &old); err != nil {
		return nil, err
	}
	if old.State.Name != "COMPLETED" {
		return nil, &BitbucketError{Kind: Failed, Message: fmt.Sprintf("pipeline %d has not ended (%s): wait for it, or stop it on its page", run, old.State.Name)}
	}
	if old.Target.Commit == nil || old.Target.Commit.Hash == "" {
		return nil, &BitbucketError{Kind: Failed, Message: fmt.Sprintf("pipeline %d has no commit to run again", run)}
	}
	for _, v := range old.Variables {
		if v.Secured {
			return nil, &BitbucketError{Kind: Failed, Message: fmt.Sprintf("pipeline %d has a secured variable (%s), which Bitbucket does not give back: run it again from its page", run, v.Key)}
		}
	}
	target := old.Target
	target.Commit = &commitRef{Type: "commit", Hash: old.Target.Commit.Hash}
	if old.Target.DestinationCommit != nil {
		target.DestinationCommit = &commitRef{Hash: old.Target.DestinationCommit.Hash}
	}
	body := map[string]any{"target": target}
	if len(old.Variables) > 0 {
		body["variables"] = old.Variables
	}
	var started pipelineJSON
	if err := b.send(ctx, http.MethodPost, repoPath(repo)+"/pipelines/", body, &started); err != nil {
		return nil, err
	}
	return map[string]any{"retried": true, "pipelineId": run, "newPipelineId": started.BuildNumber, "state": started.State.Name,
		"commit": target.Commit.Hash, "url": fmt.Sprintf("https://%s/%s/pipelines/results/%d", Host, repo, started.BuildNumber)}, nil
}
