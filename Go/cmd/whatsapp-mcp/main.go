// whatsapp-mcp: the `whatsapp` MCP server (#1352), on stdio, in the Google Chat server's shape
// (Go/cmd/googlechat-mcp): one WhatsApp Business number on Meta's Cloud API. What people send
// it comes by Meta's webhook, which the server serves itself (the Cloud API has no pull), and
// is raised as the polled events message.received and question.answered; tools send a text, a
// question with its options as buttons or a list, and an approved template, and read the last
// day's messages. Each event names its sender, so it acts only for a person who linked their
// WhatsApp number (#1762). Its secrets are named as ${WHATSAPP_TOKEN} and so on in
// `.agents/mcp.json`, so their values stay in ~/.agents-secrets/secrets.env.
//
//	whatsapp-mcp                     serve on stdio
//	whatsapp-mcp --version
//
//	WHATSAPP_TOKEN                   the access token: a system user's, with whatsapp_business_messaging
//	WHATSAPP_PHONE_NUMBER_ID         the business number's id, from the app's WhatsApp ▸ API Setup
//	WHATSAPP_APP_SECRET              the Meta app's secret, which signs each webhook call
//	WHATSAPP_VERIFY_TOKEN            a word of your own, given to Meta when the webhook is set up
//	WHATSAPP_WEBHOOK_ADDR            where the webhook listens; 127.0.0.1:8797 when left out
//	WHATSAPP_API_URL                 for a fake on this machine: where the Graph API is
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
	"github.com/alexec/agents/Go/internal/whatsappmcp"
)

func main() {
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("whatsapp-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// The account is read at each call, so a secret saved after the server started is used.
	account := func() (whatsappmcp.Account, error) { return whatsappmcp.AccountFrom(os.Getenv) }
	meta := &whatsappmcp.Meta{Account: account}
	inbox := whatsappmcp.NewInbox(account, logger)
	inbox.Seen = whatsappmcp.MarkRead(meta, logger)
	// The webhook listens from the start when the account is set, so Meta's check of it, when
	// it is set up, finds it; otherwise the first poll after the secrets are saved starts it.
	if _, err := account(); err == nil {
		inbox.Start(ctx)
	}
	front := &whatsappmcp.Front{
		Events:   &whatsappmcp.Events{Inbox: inbox, Context: ctx},
		Upstream: whatsappmcp.NewServer(buildinfo.Version, meta, inbox), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "whatsapp-mcp %s on stdio\n", buildinfo.String())
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "whatsapp-mcp:", err)
		os.Exit(1)
	}
}
