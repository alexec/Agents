// googlechat-mcp: the `googlechat` MCP server (#1016), on stdio, in the email server's shape
// (Go/cmd/email-mcp): one Google Chat app's messages and answers as the polled events
// message.received and question.answered, pulled from the app's Pub/Sub subscription (outbound, so
// the machine needs no public address), and tools that list the app's spaces, post as it, and
// ask a question with a button per option. Each event names its sender, so it acts only for a
// person who linked their Google Chat user (#1762). The app's service account key is
// GOOGLE_CHAT_CREDENTIALS, which `.agents/mcp.json` names as ${GOOGLE_CHAT_CREDENTIALS} so its
// value stays in ~/.agents-secrets/secrets.env.
//
//	googlechat-mcp                   serve on stdio
//	googlechat-mcp --version
//
//	GOOGLE_CHAT_CREDENTIALS          the service account key: its JSON, or the path of its file
//	GOOGLE_CHAT_SUBSCRIPTION         the Pub/Sub subscription: projects/<p>/subscriptions/<s>, or a name in
//	                                 the key's project; agents-chat when left out
//	GOOGLE_CHAT_API_URL              for a fake on this machine: where the Chat API is, with
//	GOOGLE_CHAT_PUBSUB_URL           where Pub/Sub is; no key is then needed or sent
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
	"github.com/agentloops-dev/agents/Go/internal/googlechatmcp"
)

func main() {
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("googlechat-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// The account is read at each call, so a key saved after the server started is used.
	google := &googlechatmcp.Google{Account: func() (googlechatmcp.Account, error) { return googlechatmcp.AccountFrom(os.Getenv) }}
	inbox := googlechatmcp.NewInbox(google, logger)
	inbox.Answered = googlechatmcp.MarkAnswered(google, logger)
	events := &googlechatmcp.Events{Inbox: inbox, Context: ctx}
	front := &googlechatmcp.Front{
		Events:   events,
		Upstream: googlechatmcp.NewServer(buildinfo.Version, events), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "googlechat-mcp %s on stdio\n", buildinfo.String())
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "googlechat-mcp:", err)
		os.Exit(1)
	}
}
