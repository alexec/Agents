// jira-mcp: the `jira` MCP server (#3247), on stdio, in the linear server's shape
// (Go/cmd/linear-mcp), with the events issue.opened, issue.labelled, issue.commented and
// issue.assigned, polled (Jira's webhooks need a Jira admin); and the tools show_issues and
// show_issue_details, with their page. Atlassian's own MCP server (mcp.atlassian.com), added
// from the marketplace, changes issues. It reads the person's Atlassian connection (Connect
// Jira, #3304), as the linear server reads Linear's. A token set by hand still goes first: it
// reads the site in JIRA_URL with a token that
// `.agents/mcp.json` names as ${JIRA_API_TOKEN}, so its value stays in
// ~/.agents-secrets/secrets.env: on Jira Cloud an API token (id.atlassian.com ▸ Security ▸
// API tokens) with the account's email in JIRA_EMAIL; on Jira Data Center a personal access
// token, with no JIRA_EMAIL.
//
//	jira-mcp                         serve on stdio
//	jira-mcp --version
//
//	JIRA_URL                         the site, as https://example.atlassian.net
//	JIRA_EMAIL                       the Atlassian account's email (Jira Cloud only)
//	JIRA_API_TOKEN                   the API token, or the Data Center personal access token
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/agentloops-dev/agents/Go/internal/buildinfo"
	"github.com/agentloops-dev/agents/Go/internal/connections"
	"github.com/agentloops-dev/agents/Go/internal/jiramcp"
)

func main() {
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("jira-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	connected := connections.Reader(connections.FromEnv(), connections.Atlassian)
	auth := func() jiramcp.Auth {
		if os.Getenv("JIRA_API_TOKEN") != "" {
			return jiramcp.TokenAuth(os.Getenv("JIRA_URL"), os.Getenv("JIRA_EMAIL"), os.Getenv("JIRA_API_TOKEN"))
		}
		c, _ := connected()
		return jiramcp.ConnectionAuth(c)
	}
	jira := jiramcp.NewRealJira(auth)
	upstream := jiramcp.NewServer(buildinfo.Version)
	jiramcp.AddViews(upstream, jira)
	front := &jiramcp.Front{
		Events:   &jiramcp.Events{Jira: jira, SignedIn: func() bool { return auth().Header != "" }},
		Upstream: upstream, Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "jira-mcp %s on stdio\n", buildinfo.String())
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "jira-mcp:", err)
		os.Exit(1)
	}
}
