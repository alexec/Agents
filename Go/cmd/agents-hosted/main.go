// agents-hosted: the hosted service (#1807). A person signs up on the web with Apple,
// Google or GitHub (#3386) and
// gets a control plane of their own, at https://<account>.<accounts domain>, each a copy of
// the single-organisation control plane with its own store prefix and control key. It
// serves plain HTTP behind a proxy that ends TLS for the domain and every account's name
// (deploy/compose.hosted.yaml).
//
//	agents-hosted serve
//	agents-hosted admin <verb> …   the operator's tool, on the same store (admin.go)
//	agents-hosted version
//
// From the environment:
//
//	AGENTS_STORE                   file:///path, or s3://bucket/prefix, as agents-control reads it
//	AGENTS_CONTROL_KMS             the keeper that seals each account's control key: gcpkms://…,
//	                               or base64key://… for a local one
//	AGENTS_HOSTED_DOMAIN           where the sign-up and account pages are (agentloops.dev)
//	AGENTS_HOSTED_ACCOUNTS_DOMAIN  where each account's control plane is, as <id>.<this>; the
//	                               pages' domain when unset
//	AGENTS_HOSTED_GITHUB_CLIENT_ID the GitHub App's client id (the agents-loops App's when unset)
//	AGENTS_HOSTED_GITHUB_SECRET    its client secret; with none, GitHub is not offered
//	AGENTS_HOSTED_APPLE_SERVICES_ID  Sign in with Apple's Services ID; with the next three, Apple is offered
//	AGENTS_HOSTED_APPLE_TEAM_ID      the Apple Developer team that has it
//	AGENTS_HOSTED_APPLE_KEY_ID       the Sign in with Apple key's id
//	AGENTS_HOSTED_APPLE_KEY          that key: the .p8 file's text, or the base64 between its
//	                                 BEGIN and END lines, on one line
//	AGENTS_HOSTED_GOOGLE_CLIENT_ID   Google's OAuth client (web kind); with its secret, Google is offered
//	AGENTS_HOSTED_GOOGLE_SECRET      its client secret
//	AGENTS_HOSTED_WEB              the built web app (Web/dist) each control plane serves
//	AGENTS_HOSTED_VIEWS_DOMAIN     the views' sandbox proxy's name, or none
//	AGENTS_HOSTED_PORT             the port to listen on, 8795
//	AGENTS_CONTROL_TRUSTED_PROXIES the proxies in front, whose X-Forwarded-For is believed
//	AGENTS_WEBPUSH_KEY_FILE        the VAPID key every account's control plane sends Web Push
//	                               to a browser with (#1486, #3515); none, or an empty file, sends none
//	AGENTS_WEBPUSH_SUBJECT         the mailto: or https: address a push service may write to about it
//
// Who may sign up, and the limits that keep the service whole (#2152, spec 1003):
//
//	AGENTS_HOSTED_SIGNUP               invite (the default), open (a verified email, #3388) or closed
//	AGENTS_HOSTED_MAX_ACCOUNTS         the most accounts, 100; then a waitlist
//	AGENTS_HOSTED_MIN_GITHUB_AGE       the youngest GitHub account, in days, 30
//	AGENTS_HOSTED_SIGNUPS_PER_ADDRESS  new accounts and waitlist entries an hour from one address, 3
//	AGENTS_HOSTED_SIGNUPS_PER_HOUR     the same in all, 30
//	AGENTS_HOSTED_MAX_COPIES           control planes running at once, 50
//	AGENTS_HOSTED_CERTS_PER_HOUR       new certificates an hour, 10
//	AGENTS_HOSTED_CERTS_PER_WEEK       new certificates a week, 40
//	AGENTS_HOSTED_STORAGE_TOTAL_GB     the most the plans' storage may add up to over all
//	                                   accounts (#3121); a file store's disk to 90% when unset
//	AGENTS_HOSTED_TURNSTILE_SITE_KEY   Cloudflare Turnstile on the sign-up page (#3388), with
//	AGENTS_HOSTED_TURNSTILE_SECRET     its secret key; both or neither, and neither is off
//
// Billing (#2225), off without a key:
//
//	AGENTS_HOSTED_STRIPE_KEY            Stripe's secret (or restricted) key
//	AGENTS_HOSTED_STRIPE_PRICE          the Pro plan's price, price_…
//	AGENTS_HOSTED_STRIPE_WEBHOOK_SECRET the webhook endpoint's signing secret, whsec_…
//
// Metrics (#2226), on a port of their own that the proxy does not pass:
//
//	AGENTS_HOSTED_METRICS_PORT     Prometheus text at /metrics, 9795; off turns it off
//	AGENTS_HOSTED_METRICS_FROM     who else may read it, besides loopback (addresses or CIDRs)
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/buildinfo"
	"github.com/agentloops-dev/agents/Go/internal/connections"
	"github.com/agentloops-dev/agents/Go/internal/controlplane"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/kms"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/webpush"
	"github.com/agentloops-dev/agents/Go/internal/hosted"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(buildinfo.Version)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "admin" {
		os.Exit(admin(os.Args[2:], os.Stdout, os.Stderr))
	}
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, "usage: agents-hosted serve | admin <verb> … | version")
		os.Exit(2)
	}
	if err := serve(); err != nil {
		fmt.Fprintln(os.Stderr, "agents-hosted: "+err.Error())
		os.Exit(1)
	}
}

func serve() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	kms.NoCredentialsFile()
	where := os.Getenv("AGENTS_STORE")
	if where == "" {
		return errors.New("say where the store is: AGENTS_STORE")
	}
	st, err := controlplane.OpenStore(where, os.Getenv, nil)
	if err != nil {
		return err
	}
	trusted, err := controlplane.ParseTrustedProxies(os.Getenv("AGENTS_CONTROL_TRUSTED_PROXIES"))
	if err != nil {
		return err
	}
	client := os.Getenv("AGENTS_HOSTED_GITHUB_CLIENT_ID")
	if client == "" {
		client = connections.GitHubClientID
	}
	logf := func(line string) { fmt.Fprintln(os.Stderr, time.Now().UTC().Format(time.RFC3339)+" "+line) }
	cfg := hosted.Config{Store: st, Keeper: os.Getenv("AGENTS_CONTROL_KMS"),
		Domain: strings.ToLower(os.Getenv("AGENTS_HOSTED_DOMAIN")), AccountsDomain: strings.ToLower(os.Getenv("AGENTS_HOSTED_ACCOUNTS_DOMAIN")),
		GitHubClientID: client, GitHubSecret: os.Getenv("AGENTS_HOSTED_GITHUB_SECRET"), Web: os.Getenv("AGENTS_HOSTED_WEB"),
		AppleServicesID: os.Getenv("AGENTS_HOSTED_APPLE_SERVICES_ID"), AppleTeamID: os.Getenv("AGENTS_HOSTED_APPLE_TEAM_ID"),
		AppleKeyID: os.Getenv("AGENTS_HOSTED_APPLE_KEY_ID"), AppleKey: []byte(os.Getenv("AGENTS_HOSTED_APPLE_KEY")),
		GoogleClientID: os.Getenv("AGENTS_HOSTED_GOOGLE_CLIENT_ID"), GoogleSecret: os.Getenv("AGENTS_HOSTED_GOOGLE_SECRET"),
		ViewsDomain: os.Getenv("AGENTS_HOSTED_VIEWS_DOMAIN"), TrustedProxies: trusted, Log: logf,
		SignUp:    strings.ToLower(os.Getenv("AGENTS_HOSTED_SIGNUP")),
		StripeKey: os.Getenv("AGENTS_HOSTED_STRIPE_KEY"), StripePrice: os.Getenv("AGENTS_HOSTED_STRIPE_PRICE"),
		StripeWebhookSecret: os.Getenv("AGENTS_HOSTED_STRIPE_WEBHOOK_SECRET"),
		TurnstileSiteKey:    os.Getenv("AGENTS_HOSTED_TURNSTILE_SITE_KEY"), TurnstileSecret: os.Getenv("AGENTS_HOSTED_TURNSTILE_SECRET")}
	for name, into := range map[string]*int{"AGENTS_HOSTED_MAX_ACCOUNTS": &cfg.MaxAccounts,
		"AGENTS_HOSTED_SIGNUPS_PER_ADDRESS": &cfg.SignUpsPerAddress, "AGENTS_HOSTED_SIGNUPS_PER_HOUR": &cfg.SignUpsPerHour,
		"AGENTS_HOSTED_MAX_COPIES": &cfg.MaxCopies, "AGENTS_HOSTED_CERTS_PER_HOUR": &cfg.CertsPerHour,
		"AGENTS_HOSTED_CERTS_PER_WEEK": &cfg.CertsPerWeek} {
		if *into, err = number(name); err != nil {
			return err
		}
	}
	// The disk a file store is on is watched (#3121); a bucket's is not this machine's.
	if u, err := url.Parse(where); err == nil && u.Scheme == "file" && u.Path != "" {
		cfg.Disk = hosted.DiskOf(u.Path)
	}
	gb, err := number("AGENTS_HOSTED_STORAGE_TOTAL_GB")
	if err != nil {
		return err
	}
	cfg.StorageTotal = int64(gb) << 30
	days, err := number("AGENTS_HOSTED_MIN_GITHUB_AGE")
	if err != nil {
		return err
	}
	if days > 0 {
		cfg.MinGitHubAge = time.Duration(days) * 24 * time.Hour
	} else if os.Getenv("AGENTS_HOSTED_MIN_GITHUB_AGE") == "0" {
		cfg.MinGitHubAge = -1
	}
	if p := webPusher(logf); p != nil {
		cfg.WebPush = p
	}
	if cfg.MetricsFrom, err = controlplane.ParseTrustedProxies(os.Getenv("AGENTS_HOSTED_METRICS_FROM")); err != nil {
		return fmt.Errorf("AGENTS_HOSTED_METRICS_FROM: %w", err)
	}
	service, err := hosted.New(ctx, cfg)
	if err != nil {
		return err
	}
	defer service.Stop()
	port := os.Getenv("AGENTS_HOSTED_PORT")
	if port == "" {
		port = "8795"
	}
	server := &http.Server{Addr: ":" + port, Handler: service, ReadHeaderTimeout: 20 * time.Second}
	metricsPort := os.Getenv("AGENTS_HOSTED_METRICS_PORT")
	if metricsPort == "" {
		metricsPort = "9795"
	}
	var metrics *http.Server
	if metricsPort != "off" {
		if metricsPort == port {
			return errors.New("AGENTS_HOSTED_METRICS_PORT is the service's own port: the proxy would pass it")
		}
		metrics = &http.Server{Addr: ":" + metricsPort, Handler: service.Metrics(), ReadHeaderTimeout: 20 * time.Second}
		go func() {
			if err := metrics.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				logf("metrics: " + err.Error())
			}
		}()
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if metrics != nil {
			_ = metrics.Shutdown(shutdown)
		}
		_ = server.Shutdown(shutdown)
	}()
	billing := "off"
	if cfg.StripeKey != "" {
		billing = "on"
	}
	webPush := "off"
	if cfg.WebPush != nil {
		webPush = "on"
	}
	logf("agents-hosted " + buildinfo.Version + " listening on :" + port + ", billing " + billing + ", Web Push " + webPush)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// webPusher is the VAPID key, a compose secret as agents-control's is: nil when there is
// none. One key for the service: every account's copy sends with it.
func webPusher(logf func(string)) controlplane.WebPusher {
	file := os.Getenv("AGENTS_WEBPUSH_KEY_FILE")
	if file == "" {
		return nil
	}
	if info, err := os.Stat(file); err != nil || info.Size() == 0 {
		return nil
	}
	client, err := webpush.New(webpush.Config{KeyFile: file, Subject: strings.TrimSpace(os.Getenv("AGENTS_WEBPUSH_SUBJECT"))})
	if err != nil {
		logf("no Web Push: " + err.Error())
		return nil
	}
	return client
}

// number is a whole number from the environment, 0 when unset.
func number(name string) (int, error) {
	v := os.Getenv(name)
	if v == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("%s is a whole number, not %q", name, v)
	}
	return n, nil
}
