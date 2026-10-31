package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane"
	"github.com/alexec/agents/Go/internal/hosted"
)

const adminUsage = `usage: agents-hosted admin <verb> …

  invite [days]              a new invite link, usable once (14 days)
  allow <login>              let a GitHub login sign up, whatever its age
  disallow <login>           take it off the allowlist
  waitlist                   everyone waiting, in order
  admit <login>              let someone on the waitlist sign up
  accounts                   every account
  suspend <account> <why>    stop its control plane; the person reads why
  unsuspend <account>        let it start again
  block <github id|login> [why]  refuse a GitHub user, and suspend their account
  unblock <github id>        let them sign up again

It reads AGENTS_STORE and AGENTS_HOSTED_DOMAIN, as serve does.`

// admin runs one admin verb, and is the exit status.
func admin(args []string, out, errOut io.Writer) int {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprintln(errOut, adminUsage)
		return 2
	}
	where := os.Getenv("AGENTS_STORE")
	if where == "" {
		fmt.Fprintln(errOut, "agents-hosted admin: say where the store is: AGENTS_STORE")
		return 1
	}
	st, err := controlplane.OpenStore(where, os.Getenv, nil)
	if err != nil {
		fmt.Fprintln(errOut, "agents-hosted admin: "+err.Error())
		return 1
	}
	a := hosted.Admin{Store: st, Domain: strings.ToLower(os.Getenv("AGENTS_HOSTED_DOMAIN"))}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if err := runAdmin(ctx, a, args, out); err != nil {
		fmt.Fprintln(errOut, "agents-hosted admin: "+err.Error())
		if errors.Is(err, errUsage) {
			fmt.Fprintln(errOut, adminUsage)
			return 2
		}
		return 1
	}
	return 0
}

var errUsage = errors.New("not a verb with those arguments")

func runAdmin(ctx context.Context, a hosted.Admin, args []string, out io.Writer) error {
	verb, rest := args[0], args[1:]
	need := func(n int) error {
		if len(rest) < n {
			return errUsage
		}
		return nil
	}
	switch verb {
	case "invite":
		days := 0
		if len(rest) > 0 {
			n, err := strconv.Atoi(rest[0])
			if err != nil || n <= 0 {
				return errUsage
			}
			days = n
		}
		if a.Domain == "" {
			return errors.New("say where the pages are: AGENTS_HOSTED_DOMAIN")
		}
		link, err := a.Invite(ctx, time.Duration(days)*24*time.Hour)
		if err == nil {
			fmt.Fprintln(out, link)
		}
		return err
	case "allow", "admit":
		if err := need(1); err != nil {
			return err
		}
		return a.Allow(ctx, rest[0])
	case "disallow":
		if err := need(1); err != nil {
			return err
		}
		return a.Disallow(ctx, rest[0])
	case "waitlist":
		list, err := a.Waitlist(ctx)
		if err != nil {
			return err
		}
		tw := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
		fmt.Fprintln(tw, "PLACE\tLOGIN\tGITHUB ID\tSINCE\tWHY")
		for i, w := range list {
			fmt.Fprintf(tw, "%d\t%s\t%d\t%s\t%s\n", i+1, w.GitHub.Login, w.GitHub.ID, w.At.Format(time.RFC3339), w.Why)
		}
		return tw.Flush()
	case "accounts":
		list, err := a.Accounts(ctx)
		if err != nil {
			return err
		}
		tw := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
		fmt.Fprintln(tw, "ACCOUNT\tLOGIN\tGITHUB ID\tPLAN\tSTATE\tCREATED")
		for _, acc := range list {
			plan, state := acc.Plan, "active"
			if plan == "" {
				plan = "free"
			}
			if acc.Suspended != nil {
				state = "suspended: " + acc.Suspended.Reason
			}
			fmt.Fprintf(tw, "%s\t%s\t%d\t%s\t%s\t%s\n", acc.ID, acc.GitHub.Login, acc.GitHub.ID, plan, state, acc.Created.Format(time.RFC3339))
		}
		return tw.Flush()
	case "suspend":
		if err := need(2); err != nil {
			return err
		}
		return a.Suspend(ctx, rest[0], strings.Join(rest[1:], " "))
	case "unsuspend":
		if err := need(1); err != nil {
			return err
		}
		return a.Unsuspend(ctx, rest[0])
	case "block":
		if err := need(1); err != nil {
			return err
		}
		id, err := a.Block(ctx, rest[0], strings.Join(rest[1:], " "))
		if err == nil {
			fmt.Fprintf(out, "blocked GitHub id %d\n", id)
		}
		return err
	case "unblock":
		if err := need(1); err != nil {
			return err
		}
		id, err := strconv.ParseInt(rest[0], 10, 64)
		if err != nil || id <= 0 {
			return errUsage
		}
		return a.Unblock(ctx, id)
	}
	return errUsage
}
