package emailmcp

import (
	"context"
	"errors"
	"fmt"
	"mime"
	"net"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-message/charset"
)

// The mailbox over IMAP: one connection, signed in when first needed and again after it
// drops, one command at a time. Reading a message never marks it read (BODY.PEEK);
// mark_read does that.

// Kind is what went wrong, as the events draft's errors need it.
type Kind int

const (
	Failed Kind = iota
	NotSignedIn
	NotFound
)

// MailError is a failure in words: never the password, never a message's text.
type MailError struct {
	Kind    Kind
	Message string
}

func (e *MailError) Error() string { return e.Message }

// Folder is one folder (an IMAP mailbox). Role is inbox, sent, drafts, trash, junk, archive
// or empty.
type Folder struct {
	Name   string `json:"name"`
	Role   string `json:"role,omitempty"`
	Total  uint32 `json:"total"`
	Unread uint32 `json:"unread"`
}

// Summary is a message without its body: what a list, a search and an event give.
type Summary struct {
	ID      string    `json:"id"`
	Folder  string    `json:"folder"`
	From    []string  `json:"from"`
	To      []string  `json:"to"`
	Subject string    `json:"subject"`
	Date    time.Time `json:"date"`
	Unread  bool      `json:"unread"`
	// Authenticated is true when the receiving server found the sender is who From says
	// (auth.go).
	Authenticated bool `json:"authenticated"`
	uid           imap.UID
}

// Message is a message with its text, which is outside content (body.go).
type Message struct {
	Summary
	Cc          []string     `json:"cc,omitempty"`
	ReplyTo     []string     `json:"replyTo,omitempty"`
	Text        string       `json:"-"`
	Cut         bool         `json:"cut,omitempty"`
	Attachments []Attachment `json:"attachments,omitempty"`
}

// Query is a search: every field given must match. From, To, Subject and Text are words in
// that header or anywhere in the message, as IMAP SEARCH matches them.
type Query struct {
	From, To, Subject, Text string
	Since                   time.Time
	UnreadOnly              bool
}

const (
	maxListed  = 100
	maxFolders = 200
	// maxRaw is the most of one message read: a larger one is read in part and says so.
	maxRaw = 4 << 20
	// foldersFor is how long the folders and their counts are kept (#1847).
	foldersFor = 30 * time.Second
	// callTimeout bounds one call: a server that stops answering closes the connection.
	callTimeout = 60 * time.Second
)

// Mailbox is one IMAP account. Account is read at each sign-in, so an account connected,
// changed or removed while the server runs is the one used.
type Mailbox struct {
	Account func() (Account, error)

	mu       sync.Mutex
	c        *imapclient.Client
	selected string
	validity uint32
	// folders is the last Folders, from foldersAt; nil when it is to be asked again.
	folders   []Folder
	foldersAt time.Time
}

func clientOptions(handler *imapclient.UnilateralDataHandler) *imapclient.Options {
	return &imapclient.Options{
		Dialer:                &net.Dialer{Timeout: 20 * time.Second},
		WordDecoder:           &mime.WordDecoder{CharsetReader: charset.Reader},
		UnilateralDataHandler: handler,
	}
}

// dial connects and signs in.
func dial(a Account, handler *imapclient.UnilateralDataHandler) (*imapclient.Client, error) {
	password := a.Password
	if a.Address == "" || a.User == "" || password == "" {
		return nil, &MailError{Kind: NotSignedIn, Message: ErrNotConnected.Error()}
	}
	var (
		c   *imapclient.Client
		err error
	)
	opts := clientOptions(handler)
	switch a.Security {
	case Insecure:
		c, err = imapclient.DialInsecure(a.Address, opts)
	case StartTLS:
		c, err = imapclient.DialStartTLS(a.Address, opts)
	default:
		c, err = imapclient.DialTLS(a.Address, opts)
	}
	if err != nil {
		return nil, &MailError{Kind: Failed, Message: fmt.Sprintf("could not reach the mail server %s", a.Address)}
	}
	if err := c.Login(a.User, password).Wait(); err != nil {
		_ = c.Close()
		var refused *imap.Error
		if errors.As(err, &refused) {
			return nil, &MailError{Kind: NotSignedIn, Message: fmt.Sprintf("the mail server refused the sign-in for %s: check the app password", a.User)}
		}
		return nil, &MailError{Kind: Failed, Message: fmt.Sprintf("the mail server %s closed the connection while signing in", a.Address)}
	}
	return c, nil
}

// dialAccount is dial with the account read now.
func dialAccount(account func() (Account, error), handler *imapclient.UnilateralDataHandler) (*imapclient.Client, error) {
	if account == nil {
		return nil, &MailError{Kind: NotSignedIn, Message: ErrNotConnected.Error()}
	}
	a, err := account()
	if err != nil {
		return nil, &MailError{Kind: NotSignedIn, Message: err.Error()}
	}
	return dial(a, handler)
}

// with runs f on a signed-in connection. When the connection fails (not a refusal from the
// server), it signs in again and runs f once more.
func (m *Mailbox) with(ctx context.Context, f func(c *imapclient.Client) error) error {
	ctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	m.mu.Lock()
	defer m.mu.Unlock()
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		if m.c == nil {
			c, derr := dialAccount(m.Account, nil)
			if derr != nil {
				return derr
			}
			m.c, m.selected, m.folders = c, "", nil
		}
		c := m.c
		stop := context.AfterFunc(ctx, func() { _ = c.Close() })
		err = f(c)
		stop()
		if err == nil || ctx.Err() != nil {
			break
		}
		var answered *imap.Error
		var mail *MailError
		if errors.As(err, &answered) || errors.As(err, &mail) {
			return err
		}
		_ = c.Close()
		m.c = nil
	}
	if ctx.Err() != nil {
		if m.c != nil {
			_ = m.c.Close()
			m.c = nil
		}
		return &MailError{Kind: Failed, Message: "the mail server did not answer in time"}
	}
	if err != nil {
		return &MailError{Kind: Failed, Message: "the connection to the mail server failed"}
	}
	return nil
}

// Close signs out.
func (m *Mailbox) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.folders = nil
	if m.c != nil {
		_ = m.c.Close()
		m.c = nil
	}
}

// open selects folder on c, once; a refusal is a folder that is not there.
func (m *Mailbox) open(c *imapclient.Client, folder string) error {
	if m.selected == folder {
		// What came since the folder was selected.
		return c.Noop().Wait()
	}
	data, err := c.Select(folder, nil).Wait()
	if err != nil {
		var refused *imap.Error
		if errors.As(err, &refused) {
			m.selected = ""
			return &MailError{Kind: NotFound, Message: fmt.Sprintf("no folder %q: list_folders says which there are", folder)}
		}
		return err
	}
	m.selected, m.validity = folder, data.UIDValidity
	return nil
}

// MARK: Ids

// A message's id is its folder, the folder's UIDVALIDITY and its UID: Archive:1700000000:42.
// The folder comes first and may hold colons, so the id is read from its end.
func messageID(folder string, validity uint32, uid imap.UID) string {
	return fmt.Sprintf("%s:%d:%d", folder, validity, uid)
}

func parseID(id string) (folder string, validity uint32, uid imap.UID, err error) {
	bad := &MailError{Kind: NotFound, Message: fmt.Sprintf("%q is not a message id: take one from list_messages, search_messages or an email.received event", id)}
	rest, u, ok := cutLast(id)
	if !ok {
		return "", 0, 0, bad
	}
	folder, v, ok := cutLast(rest)
	if !ok || folder == "" {
		return "", 0, 0, bad
	}
	vn, err1 := strconv.ParseUint(v, 10, 32)
	un, err2 := strconv.ParseUint(u, 10, 32)
	if err1 != nil || err2 != nil || un == 0 {
		return "", 0, 0, bad
	}
	return folder, uint32(vn), imap.UID(un), nil
}

func cutLast(s string) (before, after string, ok bool) {
	i := strings.LastIndexByte(s, ':')
	if i < 0 {
		return "", "", false
	}
	return s[:i], s[i+1:], true
}

// openMessage selects id's folder and checks the folder was not rebuilt since the id was given.
func (m *Mailbox) openMessage(c *imapclient.Client, id string) (imap.UID, error) {
	folder, validity, uid, err := parseID(id)
	if err != nil {
		return 0, err
	}
	if err := m.open(c, folder); err != nil {
		return 0, err
	}
	if m.validity != validity {
		return 0, &MailError{Kind: NotFound, Message: fmt.Sprintf("message %s is gone: the server renumbered %q; list it again", id, folder)}
	}
	return uid, nil
}

// MARK: Reading

var roles = map[imap.MailboxAttr]string{
	imap.MailboxAttrSent: "sent", imap.MailboxAttrDrafts: "drafts", imap.MailboxAttrTrash: "trash",
	imap.MailboxAttrJunk: "junk", imap.MailboxAttrArchive: "archive",
}

// Folders is every folder that holds messages, with its counts. It is kept for foldersFor,
// and dropped when a message is marked or moved, so show_mail on every Back, folder change
// and Refresh does not ask the server again (#1847).
func (m *Mailbox) Folders(ctx context.Context) ([]Folder, error) {
	m.mu.Lock()
	if m.folders != nil && time.Since(m.foldersAt) < foldersFor {
		out := slices.Clone(m.folders)
		m.mu.Unlock()
		return out, nil
	}
	m.mu.Unlock()
	var out []Folder
	err := m.with(ctx, func(c *imapclient.Client) error {
		var err error
		if out, err = folders(c); err != nil {
			return err
		}
		m.folders, m.foldersAt = out, time.Now()
		return nil
	})
	return slices.Clone(out), err
}

// folders asks the server for the folders and their counts: in one LIST when it offers
// LIST-STATUS (RFC 5819, in IMAP4rev2), or else a STATUS for each.
func folders(c *imapclient.Client) ([]Folder, error) {
	counts := &imap.StatusOptions{NumMessages: true, NumUnseen: true}
	var options *imap.ListOptions
	if c.Caps().Has(imap.CapListStatus) || c.Caps().Has(imap.CapIMAP4rev2) {
		options = &imap.ListOptions{ReturnStatus: counts}
	}
	list, err := c.List("", "*", options).Collect()
	if err != nil {
		return nil, err
	}
	out := []Folder{}
	for _, l := range list {
		if len(out) == maxFolders {
			break
		}
		if slices.Contains(l.Attrs, imap.MailboxAttrNoSelect) || slices.Contains(l.Attrs, imap.MailboxAttrNonExistent) {
			continue
		}
		f := Folder{Name: l.Mailbox}
		if strings.EqualFold(l.Mailbox, "INBOX") {
			f.Role = "inbox"
		}
		for _, a := range l.Attrs {
			if r, ok := roles[a]; ok {
				f.Role = r
			}
		}
		status := l.Status
		if status == nil {
			if status, err = c.Status(l.Mailbox, counts).Wait(); err != nil {
				return nil, err
			}
		}
		if status.NumMessages != nil {
			f.Total = *status.NumMessages
		}
		if status.NumUnseen != nil {
			f.Unread = *status.NumUnseen
		}
		out = append(out, f)
	}
	return out, nil
}

func limited(limit int) uint32 {
	switch {
	case limit <= 0:
		return 20
	case limit >= maxListed:
		return maxListed
	}
	return uint32(limit)
}

// List is a folder's newest messages, newest first.
func (m *Mailbox) List(ctx context.Context, folder string, unreadOnly bool, limit int) ([]Summary, error) {
	return m.Search(ctx, folder, Query{UnreadOnly: unreadOnly}, limit)
}

// Search is a folder's newest messages that match q, newest first.
func (m *Mailbox) Search(ctx context.Context, folder string, q Query, limit int) ([]Summary, error) {
	criteria := &imap.SearchCriteria{}
	for _, h := range []struct{ key, value string }{{"From", q.From}, {"To", q.To}, {"Subject", q.Subject}} {
		if v := strings.TrimSpace(h.value); v != "" {
			criteria.Header = append(criteria.Header, imap.SearchCriteriaHeaderField{Key: h.key, Value: v})
		}
	}
	if v := strings.TrimSpace(q.Text); v != "" {
		criteria.Text = []string{v}
	}
	criteria.Since = q.Since
	if q.UnreadOnly {
		criteria.NotFlag = []imap.Flag{imap.FlagSeen}
	}
	filtered := len(criteria.Header) > 0 || len(criteria.Text) > 0 || !criteria.Since.IsZero() || q.UnreadOnly
	var out []Summary
	err := m.with(ctx, func(c *imapclient.Client) error {
		if err := m.open(c, folder); err != nil {
			return err
		}
		total, err := count(c, folder)
		if err != nil {
			return err
		}
		if !filtered {
			// The newest by sequence number: no SEARCH, so no UID of the rest (#1846).
			var newest imap.SeqSet
			if total > 0 {
				newest.AddRange(total-min(total, limited(limit))+1, total)
			}
			out, err = m.summaries(c, folder, newest)
			return err
		}
		uids, err := newestMatching(c, criteria, total, limited(limit))
		if err != nil {
			return err
		}
		out, err = m.summaries(c, folder, imap.UIDSetNum(uids...))
		return err
	})
	return out, err
}

// count is how many messages the selected folder holds, asked of the server: the client's
// own count can be off after a move (#1846). ESEARCH answers with the number alone; without
// it, STATUS on the selected folder does.
func count(c *imapclient.Client, folder string) (uint32, error) {
	if c.Caps().Has(imap.CapESearch) || c.Caps().Has(imap.CapIMAP4rev2) {
		data, err := c.Search(&imap.SearchCriteria{}, &imap.SearchOptions{ReturnCount: true}).Wait()
		if err != nil {
			return 0, err
		}
		return data.Count, nil
	}
	s, err := c.Status(folder, &imap.StatusOptions{NumMessages: true}).Wait()
	if err != nil || s.NumMessages == nil {
		return 0, err
	}
	return *s.NumMessages, nil
}

// newestMatching is the UIDs of the newest limit of a folder's total messages that match
// criteria. It searches the newest 10×limit messages, then the 4× as many before them, and so
// on until limit match or the folder is done, so a search answers with the UIDs of a window,
// not of the folder (#1846). go-imap has no PARTIAL (RFC 9394), which would do it in one.
func newestMatching(c *imapclient.Client, criteria *imap.SearchCriteria, total uint32, limit uint32) ([]imap.UID, error) {
	var uids []imap.UID
	size := limit * 10
	for top := total; top > 0; {
		low := top - min(top, size) + 1
		window := *criteria
		var seq imap.SeqSet
		seq.AddRange(low, top)
		window.SeqNum = []imap.SeqSet{seq}
		found, err := c.UIDSearch(&window, nil).Wait()
		if err != nil {
			return nil, err
		}
		uids = append(uids, found.AllUIDs()...)
		if len(uids) >= int(limit) {
			break
		}
		top = low - 1
		if size < top {
			size *= 4
		}
	}
	slices.Sort(uids)
	return uids[max(0, len(uids)-int(limit)):], nil
}

// summaries fetches the envelopes of set (UIDs or sequence numbers), newest (highest UID) first.
func (m *Mailbox) summaries(c *imapclient.Client, folder string, set imap.NumSet) ([]Summary, error) {
	out := []Summary{}
	if isEmpty(set) {
		return out, nil
	}
	msgs, err := c.Fetch(set, &imap.FetchOptions{UID: true, Envelope: true, Flags: true, InternalDate: true,
		BodySection: []*imap.FetchItemBodySection{authSection}}).Collect()
	if err != nil {
		return nil, err
	}
	for _, msg := range msgs {
		out = append(out, m.summary(folder, msg))
	}
	slices.SortFunc(out, func(a, b Summary) int { return int(b.uid) - int(a.uid) })
	return out, nil
}

func isEmpty(set imap.NumSet) bool {
	switch s := set.(type) {
	case imap.SeqSet:
		return len(s) == 0
	case imap.UIDSet:
		return len(s) == 0
	}
	return set == nil
}

func (m *Mailbox) summary(folder string, msg *imapclient.FetchMessageBuffer) Summary {
	s := Summary{ID: messageID(folder, m.validity, msg.UID), Folder: folder, uid: msg.UID, From: []string{}, To: []string{},
		Unread: !slices.Contains(msg.Flags, imap.FlagSeen), Date: msg.InternalDate.UTC()}
	if e := msg.Envelope; e != nil {
		s.From, s.To, s.Subject = addresses(e.From), addresses(e.To), e.Subject
		if !e.Date.IsZero() {
			s.Date = e.Date.UTC()
		}
	}
	s.Authenticated = authenticated(msg.FindBodySection(authSection), s.From)
	return s
}

// addresses are "Name <a@b>", or "a@b" with no name.
func addresses(list []imap.Address) []string {
	out := []string{}
	for _, a := range list {
		addr := a.Addr()
		switch {
		case addr == "":
		case a.Name != "":
			out = append(out, fmt.Sprintf("%s <%s>", a.Name, addr))
		default:
			out = append(out, addr)
		}
	}
	return out
}

// Read is one message with its text. It stays unread.
func (m *Mailbox) Read(ctx context.Context, id string) (Message, error) {
	var out Message
	err := m.with(ctx, func(c *imapclient.Client) error {
		uid, err := m.openMessage(c, id)
		if err != nil {
			return err
		}
		folder, _, _, _ := parseID(id)
		section := &imap.FetchItemBodySection{Peek: true, Partial: &imap.SectionPartial{Offset: 0, Size: maxRaw}}
		msgs, err := c.Fetch(imap.UIDSetNum(uid), &imap.FetchOptions{UID: true, Envelope: true, Flags: true,
			InternalDate: true, RFC822Size: true, BodySection: []*imap.FetchItemBodySection{section, authSection}}).Collect()
		if err != nil {
			return err
		}
		if len(msgs) == 0 {
			return &MailError{Kind: NotFound, Message: fmt.Sprintf("no message %s: it was moved or deleted", id)}
		}
		msg := msgs[0]
		out = Message{Summary: m.summary(folder, msg)}
		if e := msg.Envelope; e != nil {
			out.Cc, out.ReplyTo = addresses(e.Cc), addresses(e.ReplyTo)
		}
		raw := msg.FindBodySection(section)
		out.Text, out.Attachments = readBody(raw)
		out.Cut = msg.RFC822Size > int64(len(raw))
		return nil
	})
	return out, err
}

// MARK: Changing

// MarkRead marks a message read, or unread with read false.
func (m *Mailbox) MarkRead(ctx context.Context, id string, read bool) error {
	return m.with(ctx, func(c *imapclient.Client) error {
		m.folders = nil
		uid, err := m.openMessage(c, id)
		if err != nil {
			return err
		}
		op := imap.StoreFlagsAdd
		if !read {
			op = imap.StoreFlagsDel
		}
		return c.Store(imap.UIDSetNum(uid), &imap.StoreFlags{Op: op, Silent: true, Flags: []imap.Flag{imap.FlagSeen}}, nil).Close()
	})
}

// Move moves a message to folder, and says its new id when the server tells it.
func (m *Mailbox) Move(ctx context.Context, id, folder string) (string, error) {
	var moved string
	err := m.with(ctx, func(c *imapclient.Client) error {
		m.folders = nil
		uid, err := m.openMessage(c, id)
		if err != nil {
			return err
		}
		set := imap.UIDSetNum(uid)
		var validity uint32
		var dest imap.NumSet
		switch {
		case c.Caps().Has(imap.CapMove):
			data, err := c.Move(set, folder).Wait()
			if err != nil {
				return refusedMove(err, folder)
			}
			validity, dest = data.UIDValidity, data.DestUIDs
		case c.Caps().Has(imap.CapUIDPlus):
			data, err := c.Copy(set, folder).Wait()
			if err != nil {
				return refusedMove(err, folder)
			}
			if err := c.Store(set, &imap.StoreFlags{Op: imap.StoreFlagsAdd, Silent: true, Flags: []imap.Flag{imap.FlagDeleted}}, nil).Close(); err != nil {
				return err
			}
			if err := c.UIDExpunge(set).Close(); err != nil {
				return err
			}
			validity, dest = data.UIDValidity, data.DestUIDs
		default:
			return &MailError{Kind: Failed, Message: "this mail server cannot move one message (it has neither MOVE nor UIDPLUS)"}
		}
		if uids, ok := dest.(imap.UIDSet); ok && validity != 0 {
			if list, ok := uids.Nums(); ok && len(list) == 1 {
				moved = messageID(folder, validity, list[0])
			}
		}
		return nil
	})
	return moved, err
}

func refusedMove(err error, folder string) error {
	var refused *imap.Error
	if errors.As(err, &refused) {
		return &MailError{Kind: NotFound, Message: fmt.Sprintf("the server did not move it to %q: list_folders says which folders there are", folder)}
	}
	return err
}

// MARK: New mail

// Mark is where a folder's new mail starts: its UIDVALIDITY and the next UID it will give.
type Mark struct {
	Validity uint32
	Next     imap.UID
}

// Mark is the folder's mark now.
func (m *Mailbox) Mark(ctx context.Context, folder string) (Mark, error) {
	var out Mark
	err := m.with(ctx, func(c *imapclient.Client) error {
		var err error
		out, err = status(c, folder)
		return err
	})
	return out, err
}

func status(c *imapclient.Client, folder string) (Mark, error) {
	s, err := c.Status(folder, &imap.StatusOptions{UIDNext: true, UIDValidity: true}).Wait()
	if err != nil {
		var refused *imap.Error
		if errors.As(err, &refused) {
			return Mark{}, &MailError{Kind: NotFound, Message: fmt.Sprintf("no folder %q", folder)}
		}
		return Mark{}, err
	}
	return Mark{Validity: s.UIDValidity, Next: max(s.UIDNext, 1)}, nil
}

// Since is the folder's messages with a UID above after, oldest first, at most limit, and
// the folder's mark now. When the folder's UIDVALIDITY is not validity, it gives none: the
// caller starts again from the mark.
func (m *Mailbox) Since(ctx context.Context, folder string, validity uint32, after imap.UID, limit int) ([]Summary, Mark, bool, error) {
	var out []Summary
	var mark Mark
	more := false
	err := m.with(ctx, func(c *imapclient.Client) error {
		out, more = nil, false
		var err error
		if mark, err = status(c, folder); err != nil {
			return err
		}
		if mark.Validity != validity || mark.Next <= after+1 {
			return nil
		}
		if m.selected == folder && m.validity != mark.Validity {
			m.selected = "" // renumbered since it was selected: select it again
		}
		if err := m.open(c, folder); err != nil {
			return err
		}
		var range_ imap.UIDSet
		range_.AddRange(after+1, 0) // after+1:*
		found, err := c.UIDSearch(&imap.SearchCriteria{UID: []imap.UIDSet{range_}}, nil).Wait()
		if err != nil {
			return err
		}
		var uids []imap.UID
		for _, u := range found.AllUIDs() {
			if u > after {
				uids = append(uids, u)
			}
		}
		slices.Sort(uids)
		if len(uids) > limit {
			uids, more = uids[:limit], true
		}
		if out, err = m.summaries(c, folder, imap.UIDSetNum(uids...)); err != nil {
			return err
		}
		slices.Reverse(out)
		return nil
	})
	return out, mark, more, err
}
