//go:build live

package agentsd

import (
	"context"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The cost comment (#2352) on a real merged pull request and merge request (#3412), posted and
// then edited with the person's own gh and glab, run by hand, never by CI:
//
//	GH_TOKEN=$(gh auth token) AGENTS_LIVE_GITHUB_PR=21 \
//	GITLAB_TOKEN=$(cat ~/.agents/secrets/gitlab-token) AGENTS_LIVE_GITLAB_MR=6 \
//	go test -tags live -run Live -v ./internal/agentsd/
//
// gh and glab are on the search path. AGENTS_LIVE_GITHUB_REPO and AGENTS_LIVE_GITLAB_PROJECT are
// the test repos (alexec/agents-walk and agentstest-group/agents-walk when empty); the forge
// live tests (githubmcp, gitlabmcp) merge one each and log its number.

func TestLiveCostComment(t *testing.T) {
	for _, c := range []struct{ forge, cli, token, number, path, fallback string }{
		{"github", "gh", "GH_TOKEN", "AGENTS_LIVE_GITHUB_PR", "AGENTS_LIVE_GITHUB_REPO", "alexec/agents-walk"},
		{"gitlab", "glab", "GITLAB_TOKEN", "AGENTS_LIVE_GITLAB_MR", "AGENTS_LIVE_GITLAB_PROJECT", "agentstest-group/agents-walk"},
	} {
		t.Run(c.forge, func(t *testing.T) {
			n, _ := strconv.Atoi(os.Getenv(c.number))
			if n < 1 || os.Getenv(c.token) == "" {
				t.Skipf("%s and %s are not set", c.number, c.token)
			}
			if forgeCLI(c.cli) == "" {
				t.Skipf("%s is not on the search path", c.cli)
			}
			path := os.Getenv(c.path)
			if path == "" {
				path = c.fallback
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			r := prCommentRecord{Folder: t.TempDir(), Forge: c.forge, Path: path, Number: n, MergedAt: time.Now()}
			cost := wire.LineageCost{Cost: map[string]float64{"USD": 0.42}, InputTokens: 120_000, OutputTokens: 8_000,
				WorkingSeconds: 540, WaitingSeconds: 60}
			first := prCostText(cost, 1, 0, wire.PRCostCommentCost, wire.LineageNode{}, nil)
			id, err := prCommenter(ctx, r, first)
			if err != nil || id == "" {
				t.Fatalf("post: %q, %v", id, err)
			}
			// More cost: the same comment, edited, by its id and again by its mark.
			cost.Cost["USD"], cost.OutputTokens = 0.61, 11_000
			more := prCostText(cost, 2, 1, wire.PRCostCommentCost, wire.LineageNode{}, nil)
			r.ID = id
			if again, err := prCommenter(ctx, r, more); err != nil || again != id {
				t.Fatalf("edit by id: %q, %v; want %q", again, err, id)
			}
			r.ID = ""
			if again, err := prCommenter(ctx, r, more); err != nil || again != id {
				t.Fatalf("edit by its mark: %q, %v; want %q", again, err, id)
			}
			if !strings.Contains(more, "| Sessions | 2 |") {
				t.Fatalf("the body = %q", more)
			}
			t.Logf("%s %s #%d: comment %s", c.forge, path, n, id)
		})
	}
}
