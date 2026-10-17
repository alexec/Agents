package signin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Claude is ClaudeKeychainSignIn: the Keychain item `claude` keeps on this Mac (056), read
// the way `claude` writes it, with /usr/bin/security, so no prompt is raised. Only ever
// read: never written, renewed or deleted here (R6). A token is kept until a minute before
// it expires; a failed read is remembered for five seconds.
type Claude struct {
	read  func() ([]byte, error)
	renew func(ctx context.Context)
	now   func() time.Time

	mu       sync.Mutex
	cached   *Token
	expires  time.Time
	failedAt time.Time
	failure  error
	renewing chan struct{}
}

// ClaudeStandInPrefix begins every Claude stand-in: shaped like a subscription token, so
// Claude sends the subscription's headers, and worth nothing but through the relay.
const ClaudeStandInPrefix = "sk-ant-oat01-agents-relay-"

// NewClaude reads the item at service, and renews by running the Mac's own claude; a
// walk's stand-in item (testService) is never renewed, which would spend a real turn.
func NewClaude(service string, test bool) *Claude {
	c := &Claude{read: func() ([]byte, error) { return readKeychain(service) }, now: time.Now}
	if test {
		c.renew = func(context.Context) {}
	} else {
		c.renew = func(ctx context.Context) { askTheMacsClaude(ctx, service) }
	}
	return c
}

func (c *Claude) Current() (Token, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.cached != nil && now.Before(c.expires.Add(-time.Minute)) {
		return *c.cached, nil
	}
	if c.failure != nil && now.Sub(c.failedAt) < 5*time.Second {
		return Token{}, c.failure
	}
	return c.fresh(now)
}

// Renew reads the item afresh: if the Mac's own Claude renewed it already, that is used.
// Otherwise the Mac's Claude is asked to, once however many requests wait, and it is read
// again.
func (c *Claude) Renew(ctx context.Context, stale Token) (Token, error) {
	c.mu.Lock()
	if t, err := c.fresh(c.now()); err == nil && t.Access != stale.Access {
		c.mu.Unlock()
		return t, nil
	}
	wait := c.renewing
	if wait == nil {
		wait = make(chan struct{})
		c.renewing = wait
		go func() {
			c.renew(ctx)
			c.mu.Lock()
			c.renewing = nil
			c.mu.Unlock()
			close(wait)
		}()
	}
	c.mu.Unlock()
	<-wait
	c.mu.Lock()
	defer c.mu.Unlock()
	t, err := c.fresh(c.now())
	if err != nil {
		return Token{}, err
	}
	if t.Access == stale.Access {
		return Token{}, ErrRenewalRefused
	}
	return t, nil
}

// StandIn is fresh for each grant (security review S4): the one in source is never enough.
func (c *Claude) StandIn() (string, error) { return ClaudeStandInPrefix + randomHex(32), nil }

// fresh is read, parse and remember, with the lock held.
func (c *Claude) fresh(now time.Time) (Token, error) {
	data, err := c.read()
	var t Token
	var expires time.Time
	if err == nil {
		t, expires, err = parseClaude(data)
	}
	if err != nil {
		c.cached, c.failure, c.failedAt = nil, err, now
		return Token{}, err
	}
	c.cached, c.expires, c.failure = &t, expires, nil
	return t, nil
}

// parseClaude is the item as claude writes it: claudeAiOauth.accessToken, expiresAt in
// milliseconds, and scopes, which must include inference.
func parseClaude(data []byte) (Token, time.Time, error) {
	var item struct {
		OAuth *struct {
			AccessToken string   `json:"accessToken"`
			ExpiresAt   *float64 `json:"expiresAt"`
			Scopes      []string `json:"scopes"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(data, &item) != nil {
		return Token{}, time.Time{}, ErrUnreadable
	}
	if item.OAuth == nil || item.OAuth.AccessToken == "" || !contains(item.OAuth.Scopes, "user:inference") {
		return Token{}, time.Time{}, ErrNotSignedIn
	}
	expires := time.Date(9999, 1, 1, 0, 0, 0, 0, time.UTC)
	if item.OAuth.ExpiresAt != nil {
		expires = time.UnixMilli(int64(*item.OAuth.ExpiresAt))
	}
	return Token{Access: item.OAuth.AccessToken}, expires, nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// readKeychain is `security find-generic-password -s <service> -w`: 44 is no such item.
// Ten seconds, then stopped: a read waiting on a prompt nobody answers must not hang (#207).
func readKeychain(service string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/security", "find-generic-password", "-s", service, "-w")
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	var exit *exec.ExitError
	switch {
	case err == nil:
		return out.Bytes(), nil
	case errors.As(err, &exit) && exit.ExitCode() == 44:
		return nil, ErrNotSignedIn
	}
	return nil, ErrUnreadable
}

// claudeRenewCommands are what the Mac's own Claude is asked to run, in order, until its
// sign-in has changed (R6): `auth status` costs nothing; a one-word turn on the smallest
// model certainly renews, for a few tokens.
var claudeRenewCommands = [][]string{{"auth", "status"}, {"-p", ".", "--max-turns", "1", "--model", "haiku"}}

// askTheMacsClaude runs the Mac's own claude, found on the login shell's PATH, with each
// of claudeRenewCommands until the item holds another token, 30 seconds each.
func askTheMacsClaude(ctx context.Context, service string) {
	path := loginPath()
	var claude string
	for _, dir := range filepath.SplitList(path) {
		if p := filepath.Join(dir, "claude"); isExecutable(p) {
			claude = p
			break
		}
	}
	if claude == "" {
		return
	}
	access := func() string {
		b, err := readKeychain(service)
		if err != nil {
			return ""
		}
		t, _, err := parseClaude(b)
		if err != nil {
			return ""
		}
		return t.Access
	}
	before := access()
	for _, args := range claudeRenewCommands {
		run, cancel := context.WithTimeout(ctx, 30*time.Second)
		cmd := exec.CommandContext(run, claude, args...)
		cmd.Env = append(os.Environ(), "PATH="+path)
		_ = cmd.Run()
		cancel()
		if after := access(); after != "" && after != before {
			return
		}
	}
}

func isExecutable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0
}

// loginPath is the PATH a login shell gives (LoginShellPath), so a claude installed where
// the person's shell finds it is found; launchd's own PATH is bare.
func loginPath() string {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, shell, "-l", "-c", "printf %s \"$PATH\"").Output()
	if err != nil || len(out) == 0 {
		return os.Getenv("PATH")
	}
	return strings.TrimSpace(string(out))
}
