package emailmcp

import (
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
)

// Threads, for the messaging contract (#4340, docs/reference/messaging-contract.md "Mail: a
// conversation is a thread"). A thread is made from References and In-Reply-To, and from the
// subject for a reply ("Re: …") that has neither. Many servers have no THREAD (RFC 5256), so
// the server makes them: list_conversations groups a window of a folder's newest mail, and
// read_messages finds a thread's mail by searching for its root's Message-ID, in its folder
// and in the Sent folder, so a thread has the person's own answers too.

// refsSection is the header a summary fetches for its thread, beside the envelope's
// Message-ID and In-Reply-To.
var refsSection = &imap.FetchItemBodySection{Specifier: imap.PartSpecifierHeader,
	HeaderFields: []string{"References"}, Peek: true}

const (
	// windowPer is how many of a folder's newest messages list_conversations groups for each
	// conversation asked for, and maxWindow the most.
	windowPer = 10
	maxWindow = 500
	// maxThread is the most of a thread's messages read_messages looks at in each folder:
	// the newest.
	maxThread = 500
	// maxThreadRaw is the most of one message read_messages reads.
	maxThreadRaw = 1 << 20
)

var msgIDs = regexp.MustCompile(`<([^<>\s]+)>`)

// references is the Message-IDs in a fetched References header, the thread's first first.
func references(header []byte) []string {
	_, value, ok := strings.Cut(string(header), ":")
	if !ok {
		return nil
	}
	var out []string
	for _, m := range msgIDs.FindAllStringSubmatch(value, -1) {
		out = append(out, m[1])
	}
	return out
}

var replyPrefix = regexp.MustCompile(`(?i)^\s*((re|fwd?|aw|sv|antw)\s*(\[\d+\])?\s*:\s*)+`)

// subjectKey is a subject without its Re: and Fwd:, in lower case.
func subjectKey(subject string) string {
	return strings.ToLower(strings.Join(strings.Fields(replyPrefix.ReplaceAllString(subject, "")), " "))
}

// joinsBySubject is a reply with no References and no In-Reply-To: it joins the thread of
// its subject.
func joinsBySubject(s Summary) bool {
	return len(s.refs) == 0 && len(s.inReplyTo) == 0 && replyPrefix.MatchString(s.Subject) && subjectKey(s.Subject) != ""
}

// threadID is what a conversation's id holds: its folder, and its root's Message-ID and
// subject, or one message's id for a mail that has no Message-ID and no thread.
type threadID struct {
	Folder  string `json:"f"`
	Root    string `json:"r,omitempty"`
	Subject string `json:"s,omitempty"`
	Message string `json:"m,omitempty"`
}

func (t threadID) String() string {
	b, _ := json.Marshal(t)
	return base64.RawURLEncoding.EncodeToString(b)
}

func parseThreadID(id string) (threadID, error) {
	var t threadID
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(id))
	if err != nil || json.Unmarshal(b, &t) != nil || t.Folder == "" || t.Root == "" && t.Message == "" {
		return threadID{}, &MailError{Kind: NotFound, Message: fmt.Sprintf("%q is not a conversation id: take one from list_conversations", id)}
	}
	return t, nil
}

// has is true when s is in the thread.
func (t threadID) has(s Summary) bool {
	if t.Message != "" {
		return s.ID == t.Message
	}
	if s.messageID == t.Root || slices.Contains(s.refs, t.Root) || slices.Contains(s.inReplyTo, t.Root) {
		return true
	}
	return t.Subject != "" && joinsBySubject(s) && subjectKey(s.Subject) == t.Subject
}

// criteria is a SEARCH for the thread's mail: a superset, which has then filters.
func (t threadID) criteria() *imap.SearchCriteria {
	header := func(key string) imap.SearchCriteria {
		return imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: key, Value: t.Root}}}
	}
	c := imap.SearchCriteria{Or: [][2]imap.SearchCriteria{{header("Message-ID"), header("References")}}}
	c = imap.SearchCriteria{Or: [][2]imap.SearchCriteria{{c, header("In-Reply-To")}}}
	if t.Subject != "" {
		subject := imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: "Subject", Value: t.Subject}}}
		c = imap.SearchCriteria{Or: [][2]imap.SearchCriteria{{c, subject}}}
	}
	return &c
}

// Thread is one conversation of a folder: its newest mail there, and how many of its mails
// in the window are unread.
type Thread struct {
	ID     string
	Title  string
	Newest Summary
	Unread int
}

// group puts list (newest first) into threads, the newest first.
func group(folder string, list []Summary) []Thread {
	parent := make([]int, len(list))
	for i := range parent {
		parent[i] = i
	}
	var find func(int) int
	find = func(i int) int {
		if parent[i] != i {
			parent[i] = find(parent[i])
		}
		return parent[i]
	}
	union := func(a, b int) {
		if ra, rb := find(a), find(b); ra != rb {
			parent[max(ra, rb)] = min(ra, rb)
		}
	}
	byID := map[string]int{}
	join := func(i int, id string) {
		if id == "" {
			return
		}
		if j, ok := byID[id]; ok {
			union(i, j)
		} else {
			byID[id] = i
		}
	}
	for i, s := range list {
		join(i, s.messageID)
		for _, r := range s.refs {
			join(i, r)
		}
		for _, r := range s.inReplyTo {
			join(i, r)
		}
	}
	bySubject := map[string]int{}
	for i, s := range list {
		if !joinsBySubject(s) {
			if k := subjectKey(s.Subject); k != "" {
				if _, ok := bySubject[k]; !ok {
					bySubject[k] = i
				}
			}
		}
	}
	for i, s := range list {
		if joinsBySubject(s) {
			k := subjectKey(s.Subject)
			if j, ok := bySubject[k]; ok {
				union(i, j)
			} else {
				bySubject[k] = i
			}
		}
	}
	members := map[int][]int{}
	var heads []int
	for i := range list {
		h := find(i)
		if _, ok := members[h]; !ok {
			heads = append(heads, h)
		}
		members[h] = append(members[h], i)
	}
	out := make([]Thread, 0, len(heads))
	for _, h := range heads {
		idx := members[h]
		newest, oldest := list[idx[0]], list[idx[len(idx)-1]]
		t := Thread{Newest: newest, Title: cmp.Or(newest.Subject, "(no subject)")}
		for _, i := range idx {
			if list[i].Unread {
				t.Unread++
			}
		}
		id := threadID{Folder: folder}
		switch {
		case len(oldest.refs) > 0:
			id.Root = oldest.refs[0]
		case len(oldest.inReplyTo) > 0:
			id.Root = oldest.inReplyTo[0]
		default:
			id.Root = oldest.messageID
		}
		if id.Root == "" {
			id.Message = oldest.ID
		}
		if k := subjectKey(oldest.Subject); k != "" && id.Root != "" {
			id.Subject = k
		}
		t.ID = id.String()
		out = append(out, t)
	}
	return out
}

// listCursor is a list_conversations cursor: the folder's UIDVALIDITY, and the UID below
// which the next page starts.
func listCursor(validity uint32, before imap.UID) string {
	return fmt.Sprintf("%d:%d", validity, before)
}

func badCursor(cursor string) error {
	return &MailError{Kind: NotFound, Message: fmt.Sprintf("the cursor %q is not one this server can read now: list again with no cursor", cursor)}
}

// Threads is a folder's conversations, the newest first: the threads of a window of its
// newest mail, older than cursor when it is given, and the cursor of the next page.
func (m *Mailbox) Threads(ctx context.Context, folder, cursor string, unreadOnly bool, limit int) ([]Thread, string, error) {
	n := int(limited(limit))
	window := min(maxWindow, limited(limit)*windowPer)
	var out []Thread
	next := ""
	err := m.with(ctx, func(c *imapclient.Client) error {
		out, next = []Thread{}, ""
		if err := m.open(c, folder); err != nil {
			return err
		}
		var before imap.UID
		if cursor != "" {
			v, b, ok := strings.Cut(cursor, ":")
			vn, err1 := strconv.ParseUint(v, 10, 32)
			bn, err2 := strconv.ParseUint(b, 10, 32)
			if !ok || err1 != nil || err2 != nil || bn == 0 || uint32(vn) != m.validity {
				return badCursor(cursor)
			}
			before = imap.UID(bn)
		}
		total, err := count(c, folder)
		if err != nil {
			return err
		}
		var list []Summary
		if before == 0 {
			var newest imap.SeqSet
			if total > 0 {
				newest.AddRange(total-min(total, window)+1, total)
			}
			list, err = m.summaries(c, folder, newest)
		} else {
			var older imap.UIDSet
			older.AddRange(1, before-1)
			var uids []imap.UID
			if before > 1 {
				uids, err = newestMatching(c, &imap.SearchCriteria{UID: []imap.UIDSet{older}}, total, window)
			}
			if err == nil {
				list, err = m.summaries(c, folder, imap.UIDSetNum(uids...))
			}
		}
		if err != nil {
			return err
		}
		var kept []Thread
		for _, t := range group(folder, list) {
			if unreadOnly && t.Unread == 0 {
				continue
			}
			if before != 0 {
				// A thread with newer mail was on an earlier page.
				shown, err := m.newerInThread(c, t.ID, before)
				if err != nil {
					return err
				}
				if shown {
					continue
				}
			}
			kept = append(kept, t)
			if len(kept) > n {
				break
			}
		}
		switch {
		case len(kept) > n:
			next = listCursor(m.validity, kept[n].Newest.uid+1)
			kept = kept[:n]
		case len(list) == int(window) && list[len(list)-1].uid > 1:
			next = listCursor(m.validity, list[len(list)-1].uid)
		}
		out = kept
		return nil
	})
	return out, next, err
}

// newerInThread is true when the selected folder has a mail of the thread id at or above
// the UID from.
func (m *Mailbox) newerInThread(c *imapclient.Client, id string, from imap.UID) (bool, error) {
	t, _ := parseThreadID(id)
	if t.Message != "" {
		return false, nil
	}
	var newer imap.UIDSet
	newer.AddRange(from, 0)
	criteria := t.criteria()
	criteria.UID = []imap.UIDSet{newer}
	found, err := c.UIDSearch(criteria, nil).Wait()
	if err != nil {
		return false, err
	}
	uids := found.AllUIDs()
	if len(uids) == 0 {
		return false, nil
	}
	list, err := m.summaries(c, t.Folder, imap.UIDSetNum(uids[max(0, len(uids)-maxThread):]...))
	if err != nil {
		return false, err
	}
	return slices.ContainsFunc(list, func(s Summary) bool { return s.uid >= from && t.has(s) }), nil
}

// readCursor is a read_messages cursor: the oldest message given, by its date and id.
func readCursor(s Summary) string { return fmt.Sprintf("%d %s", s.Date.UnixNano(), s.ID) }

// older is true when s comes after the message of cursor, newest first.
func older(s Summary, at time.Time, id string) bool {
	if !s.Date.Equal(at) {
		return s.Date.Before(at)
	}
	return s.ID < id
}

// ThreadMessages is a thread's messages with their text, the newest first, older than cursor
// when it is given, and the cursor of the older page. It reads them in the thread's folder
// and in the Sent folder.
func (m *Mailbox) ThreadMessages(ctx context.Context, id, cursor string, limit int) ([]Message, string, error) {
	t, err := parseThreadID(id)
	if err != nil {
		return nil, "", err
	}
	var at time.Time
	var atID string
	if cursor != "" {
		nanos, rest, ok := strings.Cut(cursor, " ")
		n, err := strconv.ParseInt(nanos, 10, 64)
		if !ok || err != nil || rest == "" {
			return nil, "", badCursor(cursor)
		}
		at, atID = time.Unix(0, n).UTC(), rest
	}
	folders := []string{t.Folder}
	if t.Message == "" {
		if list, err := m.Folders(ctx); err == nil {
			for _, f := range list {
				if f.Role == "sent" && f.Name != t.Folder {
					folders = append(folders, f.Name)
				}
			}
		}
	}
	n := int(limited(limit))
	var out []Message
	next := ""
	err = m.with(ctx, func(c *imapclient.Client) error {
		out, next = []Message{}, ""
		var all []Summary
		for i, folder := range folders {
			list, err := m.threadIn(c, t, folder)
			if err != nil {
				if i > 0 {
					continue // the Sent folder is extra
				}
				return err
			}
			all = append(all, list...)
		}
		slices.SortFunc(all, func(a, b Summary) int {
			if c := b.Date.Compare(a.Date); c != 0 {
				return c
			}
			return strings.Compare(b.ID, a.ID)
		})
		if atID != "" {
			all = slices.DeleteFunc(all, func(s Summary) bool { return !older(s, at, atID) })
		}
		if len(all) > n {
			next = readCursor(all[n-1])
			all = all[:n]
		}
		var err error
		out, err = m.texts(c, all)
		return err
	})
	return out, next, err
}

// threadIn is the thread's newest mail in folder, without text.
func (m *Mailbox) threadIn(c *imapclient.Client, t threadID, folder string) ([]Summary, error) {
	if err := m.open(c, folder); err != nil {
		return nil, err
	}
	if t.Message != "" {
		uid, err := m.openMessage(c, t.Message)
		if err != nil {
			return nil, err
		}
		return m.summaries(c, folder, imap.UIDSetNum(uid))
	}
	found, err := c.UIDSearch(t.criteria(), nil).Wait()
	if err != nil {
		return nil, err
	}
	uids := found.AllUIDs()
	slices.Sort(uids)
	list, err := m.summaries(c, folder, imap.UIDSetNum(uids[max(0, len(uids)-maxThread):]...))
	if err != nil {
		return nil, err
	}
	return slices.DeleteFunc(list, func(s Summary) bool { return !t.has(s) }), nil
}

// texts is each of list (in their folders) with its text, in list's order. A message gone
// since it was listed is left out.
func (m *Mailbox) texts(c *imapclient.Client, list []Summary) ([]Message, error) {
	byFolder := map[string][]imap.UID{}
	for _, s := range list {
		byFolder[s.Folder] = append(byFolder[s.Folder], s.uid)
	}
	type key struct {
		folder string
		uid    imap.UID
	}
	read := map[key]Message{}
	section := &imap.FetchItemBodySection{Peek: true, Partial: &imap.SectionPartial{Offset: 0, Size: maxThreadRaw}}
	for folder, uids := range byFolder {
		if err := m.open(c, folder); err != nil {
			return nil, err
		}
		msgs, err := c.Fetch(imap.UIDSetNum(uids...), &imap.FetchOptions{UID: true, RFC822Size: true,
			BodySection: []*imap.FetchItemBodySection{section}}).Collect()
		if err != nil {
			return nil, err
		}
		for _, msg := range msgs {
			raw := msg.FindBodySection(section)
			var one Message
			one.Text, one.Attachments = readBody(raw)
			one.Cut = msg.RFC822Size > int64(len(raw))
			read[key{folder, msg.UID}] = one
		}
	}
	out := []Message{}
	for _, s := range list {
		if one, ok := read[key{s.Folder, s.uid}]; ok {
			one.Summary = s
			out = append(out, one)
		}
	}
	return out, nil
}
