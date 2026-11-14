// bitbucket-mcp: the `bitbucket` MCP server (#2828), on stdio, in the gitlab server's shape
// (Go/cmd/gitlab-mcp): polled events of a Bitbucket Cloud folder's pull requests, their checks
// and its issues (checks.failed, pr.opened, pr.merged, pr.closed, pr.conflicted, pr.blocked,
// review.requested, review.comment, issue.opened, issue.labelled, issue.commented,
// issue.closed, issue.assigned), and tools that read them and comment, over the REST API 2.0.
// As the person who connected Bitbucket (#3785, in the store connections.EnvName names), or
// whose token is in BITBUCKET_TOKEN, which `.agents/mcp.json` names as ${BITBUCKET_TOKEN} so
// its value stays in ~/.agents-secrets/secrets.env. The connection's token goes only to the
// API it was made on: with --api naming another, only BITBUCKET_TOKEN is used.
//
//	bitbucket-mcp                    serve on stdio
//	bitbucket-mcp --version
//
//	BITBUCKET_TOKEN                  an Atlassian API token with the Bitbucket scopes, or an access token
//	BITBUCKET_EMAIL                  the Atlassian account's email, for an API token; left out for an access token
//	BITBUCKET_API_URL                as --api: the connection's API, else Bitbucket Cloud's, a fake in tests and walks
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

	"github.com/agentloops-dev/agent-loops/Go/internal/bitbucketmcp"
	"github.com/agentloops-dev/agent-loops/Go/internal/buildinfo"
	"github.com/agentloops-dev/agent-loops/Go/internal/connections"
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

	connected := connections.Reader(connections.FromEnv(), connections.Bitbucket)
	if *api == "" {
		if c, ok := connected(); ok {
			*api = c.URL
		}
	}
	root := bitbucketmcp.BaseURL(*api)
	// The token and its email come together: BITBUCKET_TOKEN's, else the connection's.
	pair := func() (token, email string) {
		if t := strings.TrimSpace(os.Getenv("BITBUCKET_TOKEN")); t != "" {
			return t, strings.TrimSpace(os.Getenv("BITBUCKET_EMAIL"))
		}
		if c, ok := connected(); ok && bitbucketmcp.BaseURL(c.URL) == root {
			return c.Access, c.User
		}
		return "", ""
	}
	token := func() string { t, _ := pair(); return t }
	email := func() string { _, e := pair(); return e }
	bb := bitbucketmcp.NewRealBitbucket(root, token, email, bitbucketmcp.GitRepo())
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
