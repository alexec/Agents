package githubmcp

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/github/github-mcp-server/v2/pkg/github"
	"github.com/github/github-mcp-server/v2/pkg/http/transport"
	"github.com/github/github-mcp-server/v2/pkg/observability"
	"github.com/github/github-mcp-server/v2/pkg/observability/metrics"
	"github.com/github/github-mcp-server/v2/pkg/raw"
	"github.com/github/github-mcp-server/v2/pkg/translations"
	"github.com/github/github-mcp-server/v2/pkg/utils"
	gogithub "github.com/google/go-github/v92/github"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/shurcooL/githubv4"
)

// The official GitHub MCP server's tools (github/github-mcp-server, as a library), built as
// its own stdio server builds them (internal/ghmcp), with the token from the gh sign-in.

// DefaultToolsets are the toolsets offered when none are named (#1232).
var DefaultToolsets = []string{"context", "repos", "issues", "pull_requests", "actions", "labels"}

// HiddenTools are never offered to the model: in the ci server they were the views' only, so
// a person merges and reviews, not an agent (#837, #1232). Names a release does not have are
// ignored.
var HiddenTools = []string{
	"merge_pull_request",
	"pull_request_review_write",
	"create_pull_request_review",
	"submit_pending_pull_request_review",
	"delete_pending_pull_request_review",
	"add_comment_to_pending_review",
	"hide_pull_request_review",
	"unhide_pull_request_review",
}

// UpstreamConfig is what the official server is built with.
type UpstreamConfig struct {
	Version  string
	Token    func() string
	Toolsets []string
	ReadOnly bool
	Logger   *slog.Logger
}

// NewUpstream is the official server with cfg's toolsets and without HiddenTools.
func NewUpstream(ctx context.Context, cfg UpstreamConfig) (*mcp.Server, error) {
	apiHost, err := utils.NewAPIHost("")
	if err != nil {
		return nil, err
	}
	hostType, err := utils.ParseHostType("")
	if err != nil {
		return nil, err
	}
	restURL, _ := apiHost.BaseRESTURL(ctx)
	uploadURL, _ := apiHost.UploadURL(ctx)
	graphQLURL, _ := apiHost.GraphqlURL(ctx)
	rawURL, _ := apiHost.RawURL(ctx)
	// The token goes to GitHub's own hosts only, never to a redirect off them.
	allowed := []string{restURL.Host, uploadURL.Host, graphQLURL.Host, rawURL.Host}
	agent := "agents-github-mcp/" + cfg.Version
	auth := func(next http.RoundTripper) http.RoundTripper {
		return &transport.BearerAuthTransport{Transport: next, TokenProvider: cfg.Token, AllowedHosts: allowed}
	}
	rest, err := gogithub.NewClient(
		gogithub.WithHTTPClient(&http.Client{Transport: auth(&transport.UserAgentTransport{
			Transport: &transport.ETagTransport{Transport: http.DefaultTransport}, Agent: agent})}),
		gogithub.WithEnterpriseURLs(restURL.String(), uploadURL.String()))
	if err != nil {
		return nil, fmt.Errorf("REST client: %w", err)
	}
	gql := githubv4.NewEnterpriseClient(graphQLURL.String(), &http.Client{Transport: auth(&transport.GraphQLFeaturesTransport{
		Transport: &transport.UserAgentTransport{Transport: http.DefaultTransport, Agent: agent}})})
	rawREST, err := gogithub.NewClient(
		gogithub.WithHTTPClient(&http.Client{Transport: auth(&transport.UserAgentTransport{Transport: http.DefaultTransport, Agent: agent})}),
		gogithub.WithEnterpriseURLs(restURL.String(), uploadURL.String()))
	if err != nil {
		return nil, fmt.Errorf("raw REST client: %w", err)
	}
	rawClient, err := raw.NewClient(rawREST, rawURL)
	if err != nil {
		return nil, fmt.Errorf("raw client: %w", err)
	}

	features := github.ResolveFeatureFlags(nil, false)
	checker := func(_ context.Context, flag string) (bool, error) { return features[flag], nil }
	obs, err := observability.NewExporters(cfg.Logger, metrics.NewNoopMetrics())
	if err != nil {
		return nil, err
	}
	t := translations.NullTranslationHelper
	// No request-state sealer: the one tool that needs it, delete_repository, then refuses.
	deps := github.NewBaseDeps(rest, gql, rawClient, nil, t, github.FeatureFlags{}, 5000, checker, obs)

	toolsets := cfg.Toolsets
	if len(toolsets) == 0 {
		toolsets = DefaultToolsets
	}
	inv, err := github.NewInventory(t, github.WithHost(hostType)).
		WithDeprecatedAliases(github.DeprecatedToolAliases).
		WithReadOnly(cfg.ReadOnly).
		WithToolsets(github.ResolvedEnabledToolsets(toolsets, nil)).
		WithExcludeTools(HiddenTools).
		WithServerInstructions().
		WithFeatureChecker(checker).
		Build()
	if err != nil {
		return nil, fmt.Errorf("inventory: %w", err)
	}
	return github.NewMCPServer(ctx, &github.MCPServerConfig{
		Version: cfg.Version, Translator: t, ContentWindowSize: 5000, ReadOnly: cfg.ReadOnly,
		Logger: cfg.Logger, TokenProvider: cfg.Token, ExcludeTools: HiddenTools,
	}, deps, inv)
}
