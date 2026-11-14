// betterstack-mcp: the `betterstack` events MCP server (#3655), on stdio, in the sentry
// server's shape (Go/cmd/sentry-mcp): one Better Stack team's incidents as the polled events
// health.incident_started and health.incident_resolved, so a workflow can start when a
// deployed app goes down and its status page says so. It has no tools: Better Stack's own MCP
// server (mcp.betterstack.com, the catalogue's Better Stack) has them, status pages
// included. The token is BETTERSTACK_API_TOKEN, which `.agents/mcp.json` names as
// ${BETTERSTACK_API_TOKEN} so its value stays in ~/.agents-secrets/secrets.env.
// docs/how-to/use-better-stack.md sets it up.
//
//	betterstack-mcp                  serve on stdio
//	betterstack-mcp --version
//
//	BETTERSTACK_API_TOKEN            a team's Uptime API token, or a global one with BETTERSTACK_TEAM
//	BETTERSTACK_TEAM                 the team's name, for a global token
//	BETTERSTACK_URL                  https://incidents.betterstack.com when left out
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/agentloops-dev/agents/Go/internal/betterstackmcp"
	"github.com/agentloops-dev/agents/Go/internal/buildinfo"
)

func main() {
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("betterstack-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	account := &betterstackmcp.Account{Token: os.Getenv("BETTERSTACK_API_TOKEN"), Team: os.Getenv("BETTERSTACK_TEAM"), URL: os.Getenv("BETTERSTACK_URL")}
	front := &betterstackmcp.Front{
		Events:   &betterstackmcp.Events{Account: account},
		Upstream: betterstackmcp.NewServer(buildinfo.Version), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "betterstack-mcp %s on stdio\n", buildinfo.String())
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "betterstack-mcp:", err)
		os.Exit(1)
	}
}
