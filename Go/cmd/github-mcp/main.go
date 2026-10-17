// github-mcp: the `github` MCP server (#1232), on stdio. The official GitHub MCP server's
// tools (github/github-mcp-server, as a library) and the events the ci server had (#383):
// checks.failed, pr.opened, pr.merged, pr.closed, pr.conflicted, issue.opened,
// issue.labelled, issue.commented and issue.closed, polled. As the signed-in gh user: its
// token is `gh auth token`'s, so there is no account of its own. The Agents daemon starts it
// from `.agents/mcp.json` by bare name; Agents Host and a Linux host carry it beside agentsd.
//
//	github-mcp                       serve on stdio
//	github-mcp --toolsets a,b        the official toolsets offered (default context,repos,issues,pull_requests,actions,labels)
//	github-mcp --read-only           the read-only tools only
//	github-mcp --version
//
//	GITHUB_TOOLSETS                  as --toolsets
//	GITHUB_MCP_API_URL               the REST API the events read (https://api.github.com/), for a fake in tests and walks
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
	"github.com/alexec/agents/Go/internal/githubmcp"
)

func main() {
	toolsets := flag.String("toolsets", os.Getenv("GITHUB_TOOLSETS"), "the official toolsets offered, comma-separated")
	readOnly := flag.Bool("read-only", false, "the read-only tools only")
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("github-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	token := githubmcp.GhToken()
	var sets []string
	for _, s := range strings.Split(*toolsets, ",") {
		if s = strings.TrimSpace(s); s != "" {
			sets = append(sets, s)
		}
	}
	upstream, err := githubmcp.NewUpstream(ctx, githubmcp.UpstreamConfig{
		Version: buildinfo.Version, Token: token, Toolsets: sets, ReadOnly: *readOnly, Logger: logger,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "github-mcp:", err)
		os.Exit(1)
	}
	front := &githubmcp.Front{
		Events:   &githubmcp.Events{GitHub: githubmcp.NewRealGitHub(os.Getenv("GITHUB_MCP_API_URL"), token, githubmcp.GhRepo())},
		Upstream: upstream, Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "github-mcp %s on stdio\n", buildinfo.String())
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "github-mcp:", err)
		os.Exit(1)
	}
}
