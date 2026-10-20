// email-mcp: the `email` MCP server (#1780), on stdio, in the gitlab server's shape
// (Go/cmd/gitlab-mcp): one IMAP mailbox's new mail as the polled event email.received, with
// IDLE so a quiet poll costs the mail server nothing, and tools that list, search, read,
// mark and move its messages. It never sends mail. As the person's email connection on the
// host (Connect Email: the IMAP server, the user and an app password, kept in the store
// connections.EnvName names), or as EMAIL_IMAP_URL, EMAIL_USER and EMAIL_PASSWORD, which
// `.agents/mcp.json` names as ${EMAIL_PASSWORD} so its value stays in
// ~/.agents-secrets/secrets.env. The variables, when EMAIL_PASSWORD is set, go first.
//
//	email-mcp                        serve on stdio
//	email-mcp --version
//
//	EMAIL_IMAP_URL                   the IMAP server: imaps://imap.example.com (993), imap://… (STARTTLS),
//	                                 imap+insecure://127.0.0.1:port (a fake on this machine)
//	EMAIL_USER                       the user to sign in as, usually the address
//	EMAIL_PASSWORD                   an app password
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
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/emailmcp"
)

func main() {
	version := flag.Bool("version", false, "say the version")
	flag.Parse()
	if *version {
		fmt.Println("email-mcp " + buildinfo.String())
		return
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	account := accountFromEnv()
	mailbox := &emailmcp.Mailbox{Account: account}
	front := &emailmcp.Front{
		Events:   &emailmcp.Events{Mailbox: mailbox, Watchers: emailmcp.NewWatchers(ctx, account)},
		Upstream: emailmcp.NewServer(buildinfo.Version, mailbox), Version: buildinfo.Version, Logger: logger,
	}
	// A signal ends it at once: the front would otherwise wait on stdin.
	go func() {
		<-ctx.Done()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "email-mcp %s on stdio\n", buildinfo.String())
	if err := front.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "email-mcp:", err)
		os.Exit(1)
	}
}

// accountFromEnv reads the account at each sign-in: the variables' when EMAIL_PASSWORD is
// set, else the host's email connection's, so one connected after the server started is used.
// With neither, each call says how to connect.
func accountFromEnv() func() (emailmcp.Account, error) {
	connected := connections.Reader(connections.FromEnv(), emailmcp.Provider)
	return func() (emailmcp.Account, error) {
		if password := strings.TrimSpace(os.Getenv("EMAIL_PASSWORD")); password != "" {
			address, security, err := emailmcp.ParseServer(os.Getenv("EMAIL_IMAP_URL"))
			if err != nil {
				return emailmcp.Account{}, err
			}
			return emailmcp.Account{Address: address, Security: security, User: strings.TrimSpace(os.Getenv("EMAIL_USER")),
				Password: password}, nil
		}
		c, ok := connected()
		if !ok {
			return emailmcp.Account{}, emailmcp.ErrNotConnected
		}
		address, security, err := emailmcp.ParseServer(c.URL)
		if err != nil {
			return emailmcp.Account{}, err
		}
		return emailmcp.Account{Address: address, Security: security, User: c.Login, Password: c.Access}, nil
	}
}
