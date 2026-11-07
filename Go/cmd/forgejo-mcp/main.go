// forgejo-mcp: the `forgejo` MCP server (#1753), on stdio, in the gitlab server's shape
// (Go/cmd/gitlab-mcp): polled events of a Forgejo or Gitea folder's pull requests, their
// checks and its issues (checks.failed, pr.opened, pr.merged, pr.closed, pr.conflicted,
// review.requested, review.comment, issue.opened, issue.labelled, issue.commented,
// issue.closed, issue.assigned), and tools that read them and comment, over the REST API v1
// that Forgejo and Gitea share. For codeberg.org and a Forgejo or Gitea of one's own alike. As
// the person whose token is in FORGEJO_TOKEN, which `.agents/mcp.json` names as
// ${FORGEJO_TOKEN} so its value stays in ~/.agents-secrets/secrets.env.
//
//	forgejo-mcp                      serve on stdio
//	forgejo-mcp --url https://git.example.com
//	forgejo-mcp --version
//
//	FORGEJO_TOKEN                    an access token with read and write on repository and issue
//	FORGEJO_URL                      as --url: the Forgejo or Gitea (https://codeberg.org when empty), a fake in tests and walks
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
	"github.com/alexec/agents/Go/internal/forgejomcp"
)

func main() {
	base := flag.String("url", os.Getenv("FORGEJO_URL"), "the Forgejo or Gitea: https://codeberg.org or one of your own")
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("forgejo-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	root := forgejomcp.BaseURL(*base)
	token := func() string { return strings.TrimSpace(os.Getenv("FORGEJO_TOKEN")) }
	fj := forgejomcp.NewRealForgejo(root, token, forgejomcp.GitRepo(root))
	front := &forgejomcp.Front{
		Events:   &forgejomcp.Events{Forgejo: fj},
		Upstream: forgejomcp.NewServer(buildinfo.Version, fj, os.Getenv(forgejomcp.HostedEnv) == "1"), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "forgejo-mcp %s on stdio, %s\n", buildinfo.String(), fj.Base)
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "forgejo-mcp:", err)
		os.Exit(1)
	}
}
