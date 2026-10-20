// Package emailmcp is the `email` MCP server (#1780): one IMAP mailbox, its new mail as the
// event email.received, and tools that list, search, read, mark and move its messages. It
// reads mail and never sends it. IMAP is github.com/emersion/go-imap v2; IDLE tells the
// server when mail comes, so a poll that finds nothing new costs the mail server nothing.
package emailmcp

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
)

// Provider is the email connection's name in the host's store (connections): URL is the
// IMAP server (imaps://imap.example.com), Login the user, Access the app password.
const Provider = connections.Email

// Security is how a connection to the IMAP server is kept private.
type Security string

const (
	// TLS is IMAP over TLS from the first byte (port 993): the default.
	TLS Security = "tls"
	// StartTLS is plain IMAP made private with STARTTLS before the sign-in (port 143).
	StartTLS Security = "starttls"
	// Insecure is plain IMAP with no TLS, for a fake on this machine (tests and walks) only.
	Insecure Security = "insecure"
)

// Account is where the mailbox is and who signs in. Password is an app password: never in an
// error or a log.
type Account struct {
	Address  string // host:port
	Security Security
	User     string
	Password string
}

// ErrNotConnected is a mailbox with no server, user or password yet.
var ErrNotConnected = errors.New("no mailbox is connected: Connect Email on Your Connectors, or set EMAIL_IMAP_URL, EMAIL_USER and EMAIL_PASSWORD")

// ParseServer reads the IMAP server's address: imaps://host[:993], imap://host[:143] (with
// STARTTLS), imap+insecure://127.0.0.1:port (no TLS, this machine only), or a bare host,
// as imaps.
func ParseServer(raw string) (address string, security Security, err error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", "", ErrNotConnected
	}
	if !strings.Contains(raw, "://") {
		raw = "imaps://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || (u.Path != "" && u.Path != "/") || u.User != nil || u.RawQuery != "" {
		return "", "", fmt.Errorf("the IMAP server must look like imaps://imap.example.com")
	}
	port := u.Port()
	switch u.Scheme {
	case "imaps":
		security, port = TLS, orDefault(port, "993")
	case "imap":
		security, port = StartTLS, orDefault(port, "143")
	case "imap+insecure":
		if !isLoopback(u.Hostname()) || port == "" {
			return "", "", fmt.Errorf("imap+insecure is for a server on this machine, with its port, only")
		}
		security = Insecure
	default:
		return "", "", fmt.Errorf("the IMAP server must start imaps:// or imap://")
	}
	return net.JoinHostPort(u.Hostname(), port), security, nil
}

// ServerURL is address and security as ParseServer reads them back: the form a connection keeps.
func ServerURL(address string, security Security) string {
	switch security {
	case StartTLS:
		return "imap://" + address
	case Insecure:
		return "imap+insecure://" + address
	}
	return "imaps://" + address
}

// Check signs in to a once and out again: the host's check before it keeps a connection.
// Its error says what failed, in words, and never holds the password.
func Check(ctx context.Context, a Account) error {
	m := &Mailbox{Account: func() (Account, error) { return a, nil }}
	defer m.Close()
	return m.with(ctx, func(c *imapclient.Client) error {
		_, err := c.Status("INBOX", &imap.StatusOptions{NumMessages: true}).Wait()
		return err
	})
}

func orDefault(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
