package azureboardsmcp

import (
	"context"
	"errors"

	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
)

// NewestItem is the project's (organization/project) newest changed work item, the read that
// proves an Azure DevOps folder's Tasks slot (#3802), or nil when it has none. Its error is the
// azuredevops server's, so a set-up says both servers' failures alike.
func (f *RealBoards) NewestItem(ctx context.Context, project string) (*azuredevopsmcp.Newest, error) {
	ids, _, err := f.query(ctx, project, "", 1, false)
	if err != nil || len(ids) == 0 {
		return nil, asAzureDevOps(err)
	}
	items, err := f.items(ctx, project, ids, []string{fieldTitle, fieldChanged}, false)
	if err != nil || len(items) == 0 {
		return nil, asAzureDevOps(err)
	}
	w := items[0]
	return &azuredevopsmcp.Newest{Number: w.ID, Title: w.text(fieldTitle), URL: f.webURL(project, w.ID), At: w.text(fieldChanged)}, nil
}

// asAzureDevOps is a BoardsError as the azuredevops server's error.
func asAzureDevOps(err error) error {
	var e *BoardsError
	if !errors.As(err, &e) {
		return err
	}
	kinds := map[ErrorKind]azuredevopsmcp.ErrorKind{NotSignedIn: azuredevopsmcp.NotSignedIn, RateLimited: azuredevopsmcp.RateLimited,
		NotFound: azuredevopsmcp.NotFound, Failed: azuredevopsmcp.Failed}
	return &azuredevopsmcp.AzureDevOpsError{Kind: kinds[e.Kind], Message: e.Message, RetryAfterMs: e.RetryAfterMs}
}
