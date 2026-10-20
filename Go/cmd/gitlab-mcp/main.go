// gitlab-mcp: the `gitlab` MCP server (#1629), on stdio, in the github server's shape
// (Go/cmd/github-mcp): polled events of a GitLab project's merge requests, pipelines and
// issues (checks.failed, pr.opened, pr.merged, pr.closed, pr.conflicted, review.comment,
// issue.opened, issue.commented, issue.closed), and tools that read them and comment, over
// GitLab's REST API v4. GitLab's own MCP server is not behind it: it takes no classic access
// token and needs a setting turned on for the group or instance (see the PR of #1629). For
// gitlab.com and a self-managed GitLab alike. As the person whose token is in GITLAB_TOKEN
// (the sign-in comes with #1630), which `.agents/mcp.json` names as ${GITLAB_TOKEN} so its
// value stays in ~/.agents-secrets/secrets.env.
//
//	gitlab-mcp                       serve on stdio
//	gitlab-mcp --url https://gitlab.example.com
//	gitlab-mcp --version
//
//	GITLAB_TOKEN                     an access token with the api scope
//	GITLAB_URL                       as --url: the GitLab (https://gitlab.com when empty), a fake in tests and walks
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

	token := func() string { return strings.TrimSpace(os.Getenv("GITLAB_TOKEN")) }
	gl := gitlabmcp.NewRealGitLab(*base, token, gitlabmcp.GitProject(*base))
	front := &gitlabmcp.Front{
		Events:   &gitlabmcp.Events{GitLab: gl},
		Upstream: gitlabmcp.NewServer(buildinfo.Version, gl), Version: buildinfo.Version, Logger: logger,
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
