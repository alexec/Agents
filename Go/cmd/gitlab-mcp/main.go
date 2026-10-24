// gitlab-mcp: the `gitlab` MCP server (#1629), on stdio, in the github server's shape
// (Go/cmd/github-mcp): polled events of a GitLab folder's merge requests, pipelines and
// issues (checks.failed, pr.opened, pr.merged, pr.closed, pr.conflicted, review.comment,
// issue.opened, issue.commented, issue.closed), and tools that read them and comment, over
// GitLab's REST API v4. GitLab's own MCP server is not behind it: it takes no classic access
// token and needs a setting turned on for the group or instance (see the PR of #1629). For
// gitlab.com and a self-managed GitLab alike. As the person who connected GitLab (#1630, in
// the store connections.EnvName names), or whose token is in GITLAB_TOKEN, which
// `.agents/mcp.json` names as ${GITLAB_TOKEN} so its value stays in
// ~/.agents-secrets/secrets.env. The connection's token goes only to the GitLab it was made
// on: with --url naming another, only GITLAB_TOKEN is used.
//
//	gitlab-mcp                       serve on stdio
//	gitlab-mcp --url https://gitlab.example.com
//	gitlab-mcp --version
//
//	GITLAB_TOKEN                     an access token with the api scope
//	GITLAB_URL                       as --url: the GitLab (the connection's, else https://gitlab.com), a fake in tests and walks
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
)

func main() {
	base := flag.String("url", os.Getenv("GITLAB_URL"), "the GitLab: https://gitlab.com or a self-managed one")
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("gitlab-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	connected := connections.Reader(connections.FromEnv(), connections.GitLab)
	if *base == "" {
		if c, ok := connected(); ok {
			*base = c.URL
		}
	}
	root := gitlabmcp.BaseURL(*base)
	token := func() string {
		if t := strings.TrimSpace(os.Getenv("GITLAB_TOKEN")); t != "" {
			return t
		}
		if c, ok := connected(); ok && gitlabmcp.BaseURL(c.URL) == root {
			return c.Access
		}
		return ""
	}
	gl := gitlabmcp.NewRealGitLab(root, token, gitlabmcp.GitProject(root))
	front := &gitlabmcp.Front{
		Events:   &gitlabmcp.Events{GitLab: gl},
		Upstream: gitlabmcp.NewServer(buildinfo.Version, gl, os.Getenv(gitlabmcp.HostedEnv) == "1"), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "gitlab-mcp %s on stdio, %s\n", buildinfo.String(), gl.Base)
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "gitlab-mcp:", err)
		os.Exit(1)
	}
}
