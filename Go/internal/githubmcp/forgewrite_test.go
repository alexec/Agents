package githubmcp

import (
	"context"
	"testing"
)

// #4403: Assign adds the logins on the issue's assignees.
func TestAssign(t *testing.T) {
	api := newFakeAPI(t, map[string]string{"repos/" + repo + "/issues/7/assignees": `{"number": 7}`})
	if err := api.github().Assign(context.Background(), repo, 7, []string{"kim"}); err != nil {
		t.Fatal(err)
	}
	equal(t, api.hits["repos/"+repo+"/issues/7/assignees"].Load(), int32(1), "one call")
}
