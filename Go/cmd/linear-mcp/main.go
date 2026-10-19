// linear-mcp: the `linear` MCP server (#839), on stdio, in the github server's shape
// (Go/cmd/github-mcp), with the events issue.opened, issue.labelled, issue.commented and
// issue.closed, polled; and one tool, show_issues, with its page (#1343). Linear's own MCP
// server (mcp.linear.app), added from the marketplace, changes issues. As the person's Linear connection on the host
// (#1343: Connect Linear, kept by the host, read again after each renewal), or as the personal
// API key in LINEAR_API_KEY (Linear ▸ Settings ▸ Security & access ▸ Personal API keys), which
// `.agents/mcp.json` names as ${LINEAR_API_KEY} so its value stays in
// ~/.agents-secrets/secrets.env. The key, when set, goes first.
//
//	linear-mcp                       serve on stdio
//	linear-mcp --version
//
//	LINEAR_API_KEY                   the personal API key
//	AGENTS_CONNECTIONS               where the host keeps the Linear connection (set by the host)
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
	"github.com/alexec/agents/Go/internal/connections"
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

	// A personal API key goes as it is; an OAuth token says Bearer.
	connected := connections.TokenReader(connections.FromEnv(), connections.Linear)
	key := func() string {
		if k := strings.TrimSpace(os.Getenv("LINEAR_API_KEY")); k != "" {
			return k
		}
		if t := connected(); t != "" {
			return "Bearer " + t
		}
		return ""
	}
	linear := linearmcp.NewRealLinear(os.Getenv("LINEAR_MCP_API_URL"), key)
	upstream := linearmcp.NewServer(buildinfo.Version)
	linearmcp.AddViews(upstream, linear)
	front := &linearmcp.Front{
		Events:   &linearmcp.Events{Linear: linear, SignedIn: func() bool { return key() != "" }},
		Upstream: upstream, Version: buildinfo.Version, Logger: logger,
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
