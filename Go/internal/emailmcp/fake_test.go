package emailmcp

import (
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/emersion/go-imap/v2/imapserver/imapmemserver"
)

// The fake mailbox: go-imap's in-memory IMAP server on this machine, with no TLS, as
// imap+insecure:// allows on loopback only. There is no real mailbox in the tests (#1780).

const (
	fakeUser     = "agents@example.com"
	fakePassword = "app-password-123"
)

type fakeMail struct {
	t       *testing.T
	address string
}

// newFakeMail is a mailbox with INBOX and Archive. caps nil is IMAP4rev2 (IDLE and MOVE).
func newFakeMail(t *testing.T, caps imap.CapSet) *fakeMail {
	t.Helper()
	mem := imapmemserver.New()
	user := imapmemserver.NewUser(fakeUser, fakePassword)
	for _, name := range []string{"INBOX", "Archive"} {
		if err := user.Create(name, nil); err != nil {
			t.Fatal(err)
		}
	}
	mem.AddUser(user)
	if caps == nil {
		caps = imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}}
	}
	server := imapserver.New(&imapserver.Options{
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return mem.NewSession(), nil, nil
		},
		InsecureAuth: true,
		Caps:         caps,
		Logger:       log.New(io.Discard, "", 0),
	})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = server.Serve(ln) }()
	t.Cleanup(func() { _ = server.Close() })
	return &fakeMail{t: t, address: ln.Addr().String()}
}

func (f *fakeMail) account() (Account, error) {
	return Account{Address: f.address, Security: Insecure, User: fakeUser, Password: fakePassword}, nil
}

func (f *fakeMail) mailbox() *Mailbox {
	m := &Mailbox{Account: f.account}
	f.t.Cleanup(m.Close)
	return m
}

// deliver puts a message into folder, as the mail server does when mail comes.
func (f *fakeMail) deliver(folder, raw string) {
	f.t.Helper()
	c, err := imapclient.DialInsecure(f.address, nil)
	if err != nil {
		f.t.Fatal(err)
	}
	defer c.Close()
	if err := c.Login(fakeUser, fakePassword).Wait(); err != nil {
		f.t.Fatal(err)
	}
	raw = strings.ReplaceAll(raw, "\n", "\r\n")
	cmd := c.Append(folder, int64(len(raw)), nil)
	if _, err := cmd.Write([]byte(raw)); err != nil {
		f.t.Fatal(err)
	}
	if err := cmd.Close(); err != nil {
		f.t.Fatal(err)
	}
	if _, err := cmd.Wait(); err != nil {
		f.t.Fatal(err)
	}
}

// plain is a plain-text message.
func plain(from, to, subject, body string) string {
	return fmt.Sprintf("From: %s\nTo: %s\nSubject: %s\nDate: %s\nMessage-Id: <%d@example.com>\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n\n%s\n",
		from, to, subject, time.Date(2026, 10, 20, 9, 30, 0, 0, time.UTC).Format(time.RFC1123Z), time.Now().UnixNano(), body)
}
