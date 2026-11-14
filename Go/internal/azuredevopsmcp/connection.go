package azuredevopsmcp

import (
	"os"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/connections"
)

// Connected is the Azure DevOps a server reads and the token it reads it with, for the
// azuredevops and azureboards servers alike (#3802): base (--url, or AZURE_DEVOPS_URL), else
// the Azure DevOps connection's (in the store connections.EnvName names), else dev.azure.com;
// and AZURE_DEVOPS_TOKEN, else the connection's token. The connection's token goes only to the
// Azure DevOps it was made on: with base naming another, only AZURE_DEVOPS_TOKEN is used.
func Connected(base string) (root string, token func() string) {
	connected := connections.Reader(connections.FromEnv(), connections.AzureDevOps)
	if strings.TrimSpace(base) == "" {
		if c, ok := connected(); ok {
			base = c.URL
		}
	}
	root = BaseURL(base)
	return root, func() string {
		if t := strings.TrimSpace(os.Getenv("AZURE_DEVOPS_TOKEN")); t != "" {
			return t
		}
		if c, ok := connected(); ok && BaseURL(c.URL) == root {
			return c.Access
		}
		return ""
	}
}
