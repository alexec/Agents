// bitbucket-mcp: the `bitbucket` MCP server (#2828), on stdio, in the gitlab server's shape
// (Go/cmd/gitlab-mcp): polled events of a Bitbucket Cloud folder's pull requests, their checks
// and its issues (checks.failed, pr.opened, pr.merged, pr.closed, pr.conflicted,
// review.requested, review.comment, issue.opened, issue.labelled, issue.commented,
// issue.closed, issue.assigned), and tools that read them and comment, over the REST API 2.0.
// As the person whose token is in BITBUCKET_TOKEN, which `.agents/mcp.json` names as
// ${BITBUCKET_TOKEN} so its value stays in ~/.agents-secrets/secrets.env.
//
//	bitbucket-mcp                    serve on stdio
//	bitbucket-mcp --version
//
//	BITBUCKET_TOKEN                  an Atlassian API token with the Bitbucket scopes, or an access token
//	BITBUCKET_EMAIL                  the Atlassian account's email, for an API token; left out for an access token
//	BITBUCKET_API_URL                as --api: Bitbucket Cloud's API when empty, a fake in tests and walks
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

	"github.com/alexec/agents/Go/internal/bitbucketmcp"
	"github.com/alexec/agents/Go/internal/buildinfo"
)

func main() {
	api := flag.String("api", os.Getenv("BITBUCKET_API_URL"), "the API: https://api.bitbucket.org/2.0 when empty")
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("bitbucket-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	token := func() string { return strings.TrimSpace(os.Getenv("BITBUCKET_TOKEN")) }
	email := func() string { return strings.TrimSpace(os.Getenv("BITBUCKET_EMAIL")) }
	bb := bitbucketmcp.NewRealBitbucket(*api, token, email, bitbucketmcp.GitRepo())
	front := &bitbucketmcp.Front{
		Events:   &bitbucketmcp.Events{Bitbucket: bb},
		Upstream: bitbucketmcp.NewServer(buildinfo.Version, bb, os.Getenv(bitbucketmcp.HostedEnv) == "1"), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "bitbucket-mcp %s on stdio, %s\n", buildinfo.String(), bb.Base)
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "bitbucket-mcp:", err)
		os.Exit(1)
	}
}
