package emailmcp

import (
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
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
	user    *imapmemserver.User

	mu sync.Mutex
	// What the server was asked for, so a test can prove a bound: the numbers every SEARCH
	// answered with and the messages every FETCH named.
	searched, fetched int
	// And how many LIST and STATUS commands came.
	lists, statuses int
}

// countingSession is the in-memory session, counting what SEARCH and FETCH give.
type countingSession struct {
	*imapmemserver.UserSession
	f *fakeMail
}

func (s *countingSession) Login(username, password string) error {
	if err := s.f.user.Login(username, password); err != nil {
		return err
	}
	s.UserSession = imapmemserver.NewUserSession(s.f.user)
	return nil
}

func (s *countingSession) Search(kind imapserver.NumKind, criteria *imap.SearchCriteria, options *imap.SearchOptions) (*imap.SearchData, error) {
	data, err := s.UserSession.Search(kind, criteria, options)
	// An ESEARCH that asks for MIN, MAX or COUNT alone answers with no list.
	listed := options == nil || options.ReturnAll || !options.ReturnMin && !options.ReturnMax && !options.ReturnCount && !options.ReturnSave
	if err == nil && listed {
		s.f.mu.Lock()
		s.f.searched += numbers(data.All)
		s.f.mu.Unlock()
	}
	return data, err
}

func (s *countingSession) Fetch(w *imapserver.FetchWriter, numSet imap.NumSet, options *imap.FetchOptions) error {
	s.f.mu.Lock()
	s.f.fetched += numbers(numSet)
	s.f.mu.Unlock()
	return s.UserSession.Fetch(w, numSet, options)
}

func (s *countingSession) List(w *imapserver.ListWriter, ref string, patterns []string, options *imap.ListOptions) error {
	s.f.mu.Lock()
	s.f.lists++
	s.f.mu.Unlock()
	return s.UserSession.List(w, ref, patterns, options)
}

func (s *countingSession) Status(name string, options *imap.StatusOptions) (*imap.StatusData, error) {
	s.f.mu.Lock()
	s.f.statuses++
	s.f.mu.Unlock()
	return s.UserSession.Status(name, options)
}

// numbers is how many numbers set names; "*" counts as one.
func numbers(set imap.NumSet) int {
	n := 0
	add := func(start, stop uint32) {
		if stop == 0 || start == 0 {
			n++
			return
		}
		n += int(max(start, stop)-min(start, stop)) + 1
	}
	switch s := set.(type) {
	case imap.SeqSet:
		for _, r := range s {
			add(r.Start, r.Stop)
		}
	case imap.UIDSet:
		for _, r := range s {
			add(uint32(r.Start), uint32(r.Stop))
		}
	}
	return n
}

// asked is what the server gave since the last call, and starts the count again.
func (f *fakeMail) asked() (searched, fetched int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	searched, fetched = f.searched, f.fetched
	f.searched, f.fetched = 0, 0
	return
}

// newFakeMail is a mailbox with INBOX and Archive. caps nil is IMAP4rev2 (IDLE and MOVE).
func newFakeMail(t *testing.T, caps imap.CapSet) *fakeMail {
	t.Helper()
	user := imapmemserver.NewUser(fakeUser, fakePassword)
	for _, name := range []string{"INBOX", "Archive"} {
		if err := user.Create(name, nil); err != nil {
			t.Fatal(err)
		}
	}
	if caps == nil {
		caps = imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}}
	}
	f := &fakeMail{t: t, user: user}
	server := imapserver.New(&imapserver.Options{
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return &countingSession{f: f}, nil, nil
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
	f.address = ln.Addr().String()
	return f
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

// deliverMany puts n messages into folder, numbered in their subjects from 1, straight into
// the in-memory server.
func (f *fakeMail) deliverMany(folder string, n int) {
	f.t.Helper()
	for i := 1; i <= n; i++ {
		raw := strings.ReplaceAll(plain("news@example.org", fakeUser, fmt.Sprintf("Message %d", i), "Nothing much."), "\n", "\r\n")
		if _, err := f.user.Append(folder, literal{strings.NewReader(raw), int64(len(raw))}, &imap.AppendOptions{}); err != nil {
			f.t.Fatal(err)
		}
	}
}

type literal struct {
	*strings.Reader
	size int64
}

func (l literal) Size() int64 { return l.size }

// commands is how many LIST and STATUS commands came since the last call, and starts the
// count again.
func (f *fakeMail) commands() (lists, statuses int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	lists, statuses = f.lists, f.statuses
	f.lists, f.statuses = 0, 0
	return
}

// plain is a plain-text message.
func plain(from, to, subject, body string) string {
	return fmt.Sprintf("From: %s\nTo: %s\nSubject: %s\nDate: %s\nMessage-Id: <%d@example.com>\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n\n%s\n",
		from, to, subject, time.Date(2026, 10, 20, 9, 30, 0, 0, time.UTC).Format(time.RFC1123Z), time.Now().UnixNano(), body)
}
