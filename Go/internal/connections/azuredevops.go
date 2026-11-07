package connections

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// AzureDevOps is the eighth provider (#3802): a personal access token on one organization of
// dev.azure.com, or one collection of an Azure DevOps Server, as the azuredevops and
// azureboards servers take it. Azure DevOps has no device flow for Agents, and a token has no
// refresh: it ends on the date the person gave it. Microsoft Entra sign-in comes later.
const AzureDevOps = "azuredevops"

// AzureDevOpsServices is Azure DevOps Services' root, the one a connection is on when the
// address names no other.
const AzureDevOpsServices = "https://dev.azure.com/"

// AzureDevOpsOrganization is the address the person typed as Azure DevOps's root (with a
// trailing slash) and the organization or collection under it:
//
//	acme, dev.azure.com/acme, https://dev.azure.com/acme/Web   → https://dev.azure.com/, acme
//	acme.visualstudio.com                                     → https://dev.azure.com/, acme
//	server/tfs/DefaultCollection                               → https://server/tfs/, DefaultCollection
//
// http is taken only for this machine (a fake Azure DevOps in a walk).
func AzureDevOpsOrganization(raw string) (root, org string, err error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", "", errors.New("give the organization, such as dev.azure.com/acme")
	}
	if !strings.ContainsAny(raw, "./:") {
		return AzureDevOpsServices, raw, nil
	}
	clean, err := forgeRoot(raw, AzureDevOpsServices, "Azure DevOps", "")
	if err != nil {
		return "", "", err
	}
	u, err := url.Parse(clean)
	if err != nil {
		return "", "", errors.New("that is not an Azure DevOps address")
	}
	host := strings.ToLower(u.Hostname())
	var parts []string
	for _, p := range strings.Split(strings.Trim(u.Path, "/"), "/") {
		if p != "" {
			parts = append(parts, p)
		}
	}
	switch {
	case strings.HasSuffix(host, ".visualstudio.com") && host != "vs-ssh.visualstudio.com":
		// The old address of an organization: acme.visualstudio.com is dev.azure.com/acme.
		return AzureDevOpsServices, strings.TrimSuffix(host, ".visualstudio.com"), nil
	case host == "dev.azure.com":
		// The organization comes first; a project or repository after it is left out.
		if len(parts) == 0 {
			return "", "", errors.New("give the organization too, such as dev.azure.com/acme")
		}
		return AzureDevOpsServices, parts[0], nil
	case len(parts) == 0:
		return "", "", errors.New("give the collection too, such as " + host + "/tfs/DefaultCollection")
	}
	// An Azure DevOps Server: the collection is the last part, its root what comes before.
	last := len(parts) - 1
	root = u.Scheme + "://" + u.Host + "/"
	if last > 0 {
		root += strings.Join(parts[:last], "/") + "/"
	}
	return root, parts[last], nil
}

// IsAzureDevOpsServices is root dev.azure.com's.
func IsAzureDevOpsServices(root string) bool { return root == "" || root == AzureDevOpsServices }

// CheckAzureDevOpsToken asks the organization org of the Azure DevOps at root whose token this
// is, and gives the account's display name. The token goes only in the Authorization header
// (Basic, as the password with no user); an error never holds it.
func CheckAzureDevOpsToken(ctx context.Context, client *http.Client, root, org, token string) (string, error) {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	// A sign-in page is Azure DevOps's answer to a token it does not take: never followed.
	c := *client
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, root+url.PathEscape(org)+"/_apis/connectionData", nil)
	if err != nil {
		return "", errors.New("the request to Azure DevOps could not be made")
	}
	req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(":"+token)))
	req.Header.Set("Accept", "application/json")
	res, err := c.Do(req)
	if err != nil {
		return "", errors.New("Azure DevOps could not be reached")
	}
	defer res.Body.Close()
	kind, _, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
	switch {
	case res.StatusCode == http.StatusUnauthorized || res.StatusCode == http.StatusNonAuthoritativeInfo ||
		(res.StatusCode >= 300 && res.StatusCode < 400) || (res.StatusCode == http.StatusOK && kind == "text/html"):
		return "", errors.New("Azure DevOps did not take the token for " + org + ". Make one in that organization's User settings ▸ Personal access tokens")
	case res.StatusCode == http.StatusNotFound:
		return "", errors.New("there is no organization " + org + " on " + hostOf(root))
	}
	var data struct {
		AuthenticatedUser struct {
			ID                  string `json:"id"`
			ProviderDisplayName string `json:"providerDisplayName"`
		} `json:"authenticatedUser"`
	}
	if res.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&data) != nil ||
		data.AuthenticatedUser.ID == "" {
		return "", fmt.Errorf("%s did not answer as Azure DevOps (%d for the account)", root+org, res.StatusCode)
	}
	return data.AuthenticatedUser.ProviderDisplayName, nil
}

// AzureDevOpsConnection is the connection a token makes on the organization org of the Azure
// DevOps at root. URL is the root when it is not dev.azure.com; Resource is the organization;
// Workspace is where it is, for the row to say which: dev.azure.com/acme.
func AzureDevOpsConnection(root, org, token, login string, at time.Time) Connection {
	c := Connection{Provider: AzureDevOps, Login: login, Access: token, Resource: org, ConnectedAt: at}
	if !IsAzureDevOpsServices(root) {
		c.URL = root
	}
	if u, err := url.Parse(root); err == nil {
		c.Workspace = u.Host + strings.TrimSuffix(u.Path, "/") + "/" + org
	}
	return c
}

func hostOf(root string) string {
	if u, err := url.Parse(root); err == nil && u.Host != "" {
		return u.Host
	}
	return root
}
