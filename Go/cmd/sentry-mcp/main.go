// sentry-mcp: the `sentry` events MCP server (#3583), on stdio, in the slack server's shape
// (Go/cmd/slack-mcp): one Sentry organization's issues as the polled events
// health.issue_new and health.issue_regressed, so a workflow can start on a crash or an
// error. It has no tools: Sentry's own MCP server (getsentry/sentry-mcp, the catalogue's
// Sentry, signed in by OAuth) has them. The token is SENTRY_AUTH_TOKEN, which
// `.agents/mcp.json` names as ${SENTRY_AUTH_TOKEN} so its value stays in
// ~/.agents-secrets/secrets.env. docs/how-to/use-sentry.md sets it up.
//
//	sentry-mcp                       serve on stdio
//	sentry-mcp --version
//
//	SENTRY_AUTH_TOKEN                a personal token with event:read, org:read and project:read
//	SENTRY_ORG                       the organization's slug
//	SENTRY_URL                       https://sentry.io when left out; https://de.sentry.io, or a self-hosted Sentry
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/sentrymcp"
)

func main() {
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("sentry-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	account := &sentrymcp.Account{Token: os.Getenv("SENTRY_AUTH_TOKEN"), Org: os.Getenv("SENTRY_ORG"), URL: os.Getenv("SENTRY_URL")}
	front := &sentrymcp.Front{
		Events:   &sentrymcp.Events{Account: account},
		Upstream: sentrymcp.NewServer(buildinfo.Version), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "sentry-mcp %s on stdio\n", buildinfo.String())
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "sentry-mcp:", err)
		os.Exit(1)
	}
}
