// linear-mcp: the `linear` MCP server (#839), on stdio, in the github server's shape
// (Go/cmd/github-mcp). Read-only tools (list_issues, get_issue, list_teams) and the events of
// the workspace's issues: issue.opened, issue.labelled, issue.commented and issue.closed,
// polled. As the personal API key in LINEAR_API_KEY (Linear ▸ Settings ▸ Security & access ▸
// Personal API keys), which `.agents/mcp.json` names as ${LINEAR_API_KEY} so its value stays
// in ~/.agents-secrets/secrets.env.
//
//	linear-mcp                       serve on stdio
//	linear-mcp --version
//
//	LINEAR_API_KEY                   the personal API key
//	LINEAR_MCP_API_URL               the GraphQL API (https://api.linear.app/graphql), for a fake in tests and walks
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
	"github.com/alexec/agents/Go/internal/linearmcp"
)

func main() {
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("linear-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	key := func() string { return strings.TrimSpace(os.Getenv("LINEAR_API_KEY")) }
	linear := linearmcp.NewRealLinear(os.Getenv("LINEAR_MCP_API_URL"), key)
	front := &linearmcp.Front{
		Events:   &linearmcp.Events{Linear: linear, SignedIn: func() bool { return key() != "" }},
		Upstream: linearmcp.NewServer(linear, buildinfo.Version), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "linear-mcp %s on stdio\n", buildinfo.String())
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "linear-mcp:", err)
		os.Exit(1)
	}
}
