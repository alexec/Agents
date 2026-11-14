// azureboards-mcp: the `azureboards` MCP server (#3804), on stdio, in the jira server's shape
// (Go/cmd/jira-mcp): polled events of an Azure DevOps project's work items (issue.opened,
// issue.labelled, issue.commented, issue.closed, issue.assigned), and tools that read them and
// comment, over Azure DevOps's REST API, for the tracker slot. For dev.azure.com and an Azure
// DevOps Server alike. As the person who connected Azure DevOps (#3802), or whose personal
// access token is in AZURE_DEVOPS_TOKEN, the azuredevops server's, which `.agents/mcp.json`
// names as ${AZURE_DEVOPS_TOKEN} so its value stays in ~/.agents-secrets/secrets.env. Pull requests and builds are the azuredevops
// server's.
//
//	azureboards-mcp                      serve on stdio
//	azureboards-mcp --url https://server/tfs --project acme/Web
//	azureboards-mcp --version
//
//	AZURE_DEVOPS_TOKEN                   a personal access token with Work Items (read and write)
//	AZURE_DEVOPS_URL                     as --url: an Azure DevOps Server's collections (the connection's, else https://dev.azure.com, when empty), a fake in tests
//	AZURE_BOARDS_PROJECT                 as --project: organization/project; the folder's Azure Repos remote's when empty
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/agentloops-dev/agent-loops/Go/internal/azureboardsmcp"
	"github.com/agentloops-dev/agent-loops/Go/internal/azuredevopsmcp"
	"github.com/agentloops-dev/agent-loops/Go/internal/buildinfo"
)

func main() {
	base := flag.String("url", os.Getenv("AZURE_DEVOPS_URL"), "Azure DevOps: https://dev.azure.com, or an Azure DevOps Server's https://server/tfs")
	project := flag.String("project", os.Getenv("AZURE_BOARDS_PROJECT"), "organization/project; the folder's Azure Repos remote's when empty")
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("azureboards-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	root, token := azuredevopsmcp.Connected(*base)
	boards := azureboardsmcp.NewRealBoards(root, token, azureboardsmcp.ProjectOf(root, *project))
	front := &azureboardsmcp.Front{
		Events:   &azureboardsmcp.Events{Boards: boards, SignedIn: func() bool { return token() != "" }},
		Upstream: azureboardsmcp.NewServer(buildinfo.Version, boards), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "azureboards-mcp %s on stdio, %s\n", buildinfo.String(), boards.Base)
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "azureboards-mcp:", err)
		os.Exit(1)
	}
}
