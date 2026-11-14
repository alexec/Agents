package azureboardsmcp

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/azuredevopsmcp"
)

// The Tasks read of an Azure DevOps set-up (#3802): the project's newest changed work item,
// nil for none, and a refusal as the azuredevops server's error.
func TestTheSetUpsNewestItem(t *testing.T) {
	f := newFake(t)
	b := f.boards()
	ctx := context.Background()
	if n, err := b.NewestItem(ctx, project); n != nil || err != nil {
		t.Fatalf("an empty project: %+v %v", n, err)
	}
	f.item(3, "Old", "Task", "To Do", alex, 1, nil)
	f.item(7, "Walk the sheet", "Bug", "Doing", dev, 5, nil)
	if n, err := b.NewestItem(ctx, project); err != nil || n.Number != 7 || n.Title != "Walk the sheet" ||
		n.URL != f.server.URL+"/acme/Web%20App/_workitems/edit/7" || n.At != at(5) {
		t.Fatalf("newest: %+v %v", n, err)
	}
	f.set(func() { f.status = http.StatusForbidden })
	var ado *azuredevopsmcp.AzureDevOpsError
	if _, err := b.NewestItem(ctx, project); !errors.As(err, &ado) || !azuredevopsmcp.Refused(err) {
		t.Fatalf("a refusal: %v", err)
	}
}
