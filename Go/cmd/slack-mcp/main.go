// slack-mcp: the `slack` MCP server (#1351), on stdio, in the email server's shape
// (Go/cmd/email-mcp): one Slack workspace, as a Slack app's bot. Socket Mode brings its
// messages and the answers to its questions in as the polled events message.received and
// question.answered, with no public address; tools list the bot's channels, read messages,
// send a message and ask a question with options as buttons. The tokens are SLACK_BOT_TOKEN
// and SLACK_APP_TOKEN, which `.agents/mcp.json` names as ${SLACK_BOT_TOKEN} so their values
// stay in ~/.agents-secrets/secrets.env. docs/how-to/reach-agents-from-slack.md sets the app up.
//
//	slack-mcp                        serve on stdio
//	slack-mcp --version
//
//	SLACK_BOT_TOKEN                  the app's bot token, xoxb-…
//	SLACK_APP_TOKEN                  an app-level token with connections:write, xapp-…
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
	"github.com/agentloops-dev/agents/Go/internal/slackmcp"
)

func main() {
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("slack-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	workspace := &slackmcp.Workspace{BotToken: os.Getenv("SLACK_BOT_TOKEN"), AppToken: os.Getenv("SLACK_APP_TOKEN")}
	inbox := slackmcp.NewInbox()
	listener := &slackmcp.Listener{Workspace: workspace, Inbox: inbox, Logger: logger}
	go listener.Run(ctx)
	front := &slackmcp.Front{
		Events:   &slackmcp.Events{Workspace: workspace, Inbox: inbox, Listener: listener},
		Upstream: slackmcp.NewServer(buildinfo.Version, workspace), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "slack-mcp %s on stdio\n", buildinfo.String())
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "slack-mcp:", err)
		os.Exit(1)
	}
}
