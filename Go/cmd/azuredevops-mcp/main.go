// azuredevops-mcp: the `azuredevops` MCP server (#2829), on stdio, in the gitlab server's
// shape (Go/cmd/gitlab-mcp): polled events of an Azure DevOps folder's pull requests and their
// Azure Pipelines builds (checks.failed, pr.opened, pr.merged, pr.closed, pr.conflicted,
// review.requested, review.comment), and tools that read them and comment, over Azure
// DevOps's REST API. For dev.azure.com and an Azure DevOps Server alike. As the person who
// connected Azure DevOps (#3802, in the store connections.EnvName names), or whose personal
// access token is in AZURE_DEVOPS_TOKEN, which `.agents/mcp.json` names as ${AZURE_DEVOPS_TOKEN}
// so its value stays in ~/.agents-secrets/secrets.env. Work items are the tracker's, not this
// server's.
//
//	azuredevops-mcp                      serve on stdio
//	azuredevops-mcp --url https://server/tfs
//	azuredevops-mcp --version
//
//	AZURE_DEVOPS_TOKEN                   a personal access token with Code (read and write) and Build (read)
//	AZURE_DEVOPS_URL                     as --url: an Azure DevOps Server's collections (the connection's, else https://dev.azure.com, when empty), a fake in tests
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/internal/buildinfo"
)

func main() {
	base := flag.String("url", os.Getenv("AZURE_DEVOPS_URL"), "Azure DevOps: https://dev.azure.com, or an Azure DevOps Server's https://server/tfs")
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("azuredevops-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	root, token := azuredevopsmcp.Connected(*base)
	ado := azuredevopsmcp.NewRealAzureDevOps(root, token, azuredevopsmcp.GitRepo(root))
	front := &azuredevopsmcp.Front{
		Events:   &azuredevopsmcp.Events{AzureDevOps: ado},
		Upstream: azuredevopsmcp.NewServer(buildinfo.Version, ado, os.Getenv(azuredevopsmcp.HostedEnv) == "1"), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "azuredevops-mcp %s on stdio, %s\n", buildinfo.String(), ado.Base)
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "azuredevops-mcp:", err)
		os.Exit(1)
	}
}
