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

	"github.com/agentloops-dev/agents/Go/internal/controlplane"
	"github.com/agentloops-dev/agents/Go/internal/hosted"
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
  block <sign-in> [why]      refuse a sign-in and its account's email, and suspend its
                             account: provider:subject (apple:…, google:…, github:…), a
                             GitHub id or a GitHub login; or an email, from every provider
  unblock <sign-in>          let it sign up again: provider:subject, a GitHub id or an email
  plan <account> free|pro    put an account on a plan by hand
  backup [--keep N] <dir> [account…]
                             copy accounts (every one when none is named) into dir;
                             --keep N deletes all but the newest N backups beside it
                             (7 when not set; --keep 0 deletes none)
  restore <dir> <account>    put one suspended or deleted account back from dir
  delete <account>           delete a suspended account and everything it keeps

It reads AGENTS_STORE and AGENTS_HOSTED_DOMAIN, as serve does, and AGENTS_CONTROL_KMS
for a block by email.`

// backupKeepDefault is backup's --keep when none is given.
const backupKeepDefault = 7

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
	a := hosted.Admin{Store: st, Domain: strings.ToLower(os.Getenv("AGENTS_HOSTED_DOMAIN")), Keeper: os.Getenv("AGENTS_CONTROL_KMS")}
	limit := 2 * time.Minute
	if args[0] == "backup" || args[0] == "restore" {
		limit = 6 * time.Hour
	}
	ctx, cancel := context.WithTimeout(context.Background(), limit)
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
		fmt.Fprintln(tw, "PLACE\tSIGN-IN\tLOGIN\tSINCE\tWHY")
		for i, w := range list {
			fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%s\n", i+1, w.SignIn, w.SignIn.Login, w.At.Format(time.RFC3339), w.Why)
		}
		return tw.Flush()
	case "accounts":
		list, err := a.Accounts(ctx)
		if err != nil {
			return err
		}
		tw := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
		fmt.Fprintln(tw, "ACCOUNT\tSIGN-IN\tLOGIN\tPLAN\tSTATE\tCREATED")
		for _, acc := range list {
			plan, state := acc.Plan, "active"
			if plan == "" {
				plan = "free"
			}
			if acc.Suspended != nil {
				state = "suspended: " + acc.Suspended.Reason
			}
			fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\n", acc.ID, acc.SignIn, acc.SignIn.Login, plan, state, acc.Created.Format(time.RFC3339))
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
		user, err := a.Block(ctx, rest[0], strings.Join(rest[1:], " "))
		if err == nil && user.Provider == "" {
			fmt.Fprintln(out, "blocked that email")
		} else if err == nil {
			fmt.Fprintf(out, "blocked %s\n", user)
		}
		return err
	case "plan":
		if err := need(2); err != nil {
			return err
		}
		return a.SetPlan(ctx, rest[0], rest[1])
	case "backup":
		// Kept bounded unless the operator says otherwise (#3648).
		keep := backupKeepDefault
		if len(rest) > 0 && (rest[0] == "--keep" || strings.HasPrefix(rest[0], "--keep=")) {
			n := strings.TrimPrefix(rest[0], "--keep=")
			rest = rest[1:]
			if n == "--keep" {
				if len(rest) == 0 {
					return errUsage
				}
				n, rest = rest[0], rest[1:]
			}
			k, err := strconv.Atoi(n)
			if err != nil || k < 0 {
				return errUsage
			}
			keep = k
		}
		if err := need(1); err != nil {
			return err
		}
		done, err := a.Backup(ctx, rest[0], rest[1:])
		for _, id := range done {
			fmt.Fprintln(out, "backed up "+id)
		}
		if err != nil || keep == 0 {
			return err
		}
		// Only after a whole backup, so a failed one never costs an older one.
		gone, err := hosted.PruneBackups(rest[0], keep)
		for _, p := range gone {
			fmt.Fprintln(out, "deleted "+p)
		}
		return err
	case "delete":
		if err := need(1); err != nil {
			return err
		}
		return a.Delete(ctx, rest[0])
	case "restore":
		if err := need(2); err != nil {
			return err
		}
		n, err := a.Restore(ctx, rest[0], rest[1])
		if err == nil {
			fmt.Fprintf(out, "restored %s: %d records\n", rest[1], n)
		}
		return err
	case "unblock":
		if err := need(1); err != nil {
			return err
		}
		err := a.Unblock(ctx, rest[0])
		if errors.Is(err, hosted.ErrNotSignIn) {
			return errUsage
		}
		return err
	}
	return errUsage
}
