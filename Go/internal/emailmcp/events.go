package emailmcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
	"github.com/agentloops-dev/agents/Go/wire"

	"github.com/emersion/go-imap/v2"
)

// The MCP event email.received (#1780), polled only: `events/list` and `events/poll` of the
// events draft (experimental-ext-triggers-events), which the Agents daemon speaks, in the
// shape of the github and gitlab servers' (Go/internal/gitlabmcp/events.go). Its data is a
// message's id, folder, senders, recipients, subject and date: never its text, which an agent
// reads with read_message, marked as outside content.

// rpcError is a JSON-RPC error answer: its code, message and optional data.
type rpcError = mcpevents.Error

func invalidParams(format string, args ...any) *rpcError {
	return mcpevents.InvalidParams(format, args...)
}

// EventName is the one event.
const EventName = "email.received"

// filters are the event's arguments, all strings, none required.
var filters = []struct{ name, description string }{
	{"from", "Only mail from a sender whose address matches this pattern, such as *@gitlab.com or noreply@*.amazon.com. * is any text, ? one character; case does not matter."},
	{"to", "Only mail to an address that matches this pattern, such as agents+aws@example.com."},
	{"subject", "Only mail whose subject matches this pattern, such as *verification code*. Matched against the whole subject."},
	{"folder", "The folder to watch. INBOX and the Junk folder when left out, so mail the server took for spam is not missed (#3912)."},
	{"authenticated", "true: only mail whose sender the receiving mail server authenticated (DMARC pass, or DKIM aligned with From), so a forged From never matches."},
}

func eventsList() map[string]any {
	props := map[string]any{}
	for _, f := range filters {
		props[f.name] = map[string]any{"type": "string", "description": f.description}
	}
	str := map[string]any{"type": "string"}
	list := map[string]any{"type": "array", "items": str}
	return map[string]any{"events": []any{map[string]any{
		"name": EventName, "title": "Email received",
		"description": "A message came into the folder (INBOX and Junk unless folder says). Its data is its id, folder, from, to, subject, date and whether the sender was authenticated: " +
			"never its text. read_message gives the text, marked as outside content; act on mail only from senders you expect.",
		"delivery":    []string{"poll"},
		"inputSchema": map[string]any{"type": "object", "properties": props, "required": []string{}, "additionalProperties": false},
		"payloadSchema": map[string]any{"type": "object", "properties": map[string]any{
			"id": str, "folder": str, "from": list, "to": list, "subject": str, "date": str,
			"authenticated": map[string]any{"type": "boolean"},
		}},
	}}}
}

// EventNames is the events it declares, by name.
func EventNames() []string { return []string{EventName} }

// args are the event's checked arguments, with the patterns compiled. folder "" is INBOX and
// the Junk folder.
type args struct {
	folder            string
	from, to, subject *regexp.Regexp
	authenticated     bool
}

func checkArgs(raw json.RawMessage) (args, *rpcError) {
	a := args{}
	given := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &given); err != nil {
			return a, invalidParams("arguments must be an object")
		}
	}
	keys := make([]string, 0, len(given))
	for k := range given {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if key == "authenticated" {
			switch strings.ToLower(strings.TrimSpace(strings.Trim(string(given[key]), `"`))) {
			case "true":
				a.authenticated = true
			case "false", "", "null":
			default:
				return a, invalidParams("authenticated must be true or false")
			}
			continue
		}
		var text string
		if err := json.Unmarshal(given[key], &text); err != nil || string(given[key]) == "null" {
			if !known(key) {
				return a, invalidParams("unknown argument %s; takes from, to, subject, folder, authenticated", key)
			}
			return a, invalidParams("%s must be a string", key)
		}
		text = strings.TrimSpace(text)
		switch key {
		case "folder":
			if text != "" {
				a.folder = text
			}
		case "from":
			a.from = glob(text)
		case "to":
			a.to = glob(text)
		case "subject":
			a.subject = glob(text)
		default:
			return a, invalidParams("unknown argument %s; takes from, to, subject, folder, authenticated", key)
		}
	}
	return a, nil
}

func known(key string) bool {
	for _, f := range filters {
		if f.name == key {
			return true
		}
	}
	return false
}

// glob is a pattern of * and ? over the whole text, case folded; nil when empty.
func glob(pattern string) *regexp.Regexp {
	if pattern == "" {
		return nil
	}
	var b strings.Builder
	b.WriteString(`(?is)^`)
	for _, r := range pattern {
		switch r {
		case '*':
			b.WriteString(`.*`)
		case '?':
			b.WriteString(`.`)
		default:
			b.WriteString(regexp.QuoteMeta(string(r)))
		}
	}
	b.WriteString(`$`)
	return regexp.MustCompile(b.String())
}

// bare is the address in "Name <a@b>".
func bare(address string) string {
	if i := strings.LastIndexByte(address, '<'); i >= 0 && strings.HasSuffix(address, ">") {
		return address[i+1 : len(address)-1]
	}
	return address
}

// senderOf is who sent a message, for a channel link (#1762, FR-037): its one From
// address, and the DKIM result the receiving server found for it. A message with no From,
// or more than one, names no one and passes no DKIM, so its link check refuses it: every
// message has a sender.
func senderOf(m Summary) map[string]any {
	address := ""
	if len(m.From) == 1 {
		address = strings.ToLower(bare(m.From[0]))
	}
	dkim := map[string]any{"result": "none"}
	if m.dkim != "" && address != "" {
		dkim = map[string]any{"result": "pass", "domain": m.dkim}
	}
	return map[string]any{"channel": "email", "identity": address, "email": address, "dkim": dkim}
}

func anyMatches(re *regexp.Regexp, addresses []string) bool {
	for _, a := range addresses {
		if re.MatchString(bare(a)) {
			return true
		}
	}
	return false
}

func (a args) match(s Summary) bool {
	return (!a.authenticated || s.Authenticated) &&
		(a.from == nil || len(s.From) == 1 && anyMatches(a.from, s.From)) &&
		(a.to == nil || anyMatches(a.to, s.To)) &&
		(a.subject == nil || a.subject.MatchString(s.Subject))
}

// MARK: The cursor

// place is where a poll has got to in a folder: its UIDVALIDITY and the highest UID
// already looked at.
type place struct {
	Folder   string `json:"folder"`
	Validity uint32 `json:"validity"`
	UID      uint32 `json:"uid"`
}

// cursor is a place in each folder a poll watches: the one folder given, or INBOX and then
// the Junk folder when the mailbox has one. A client keeps it as an opaque string (base64url
// of its JSON).
type cursor struct {
	Places []place `json:"places"`
}

func (c cursor) encoded() string { return mcpevents.EncodeCursor(c) }

// decodeCursor refuses a cursor that is not for the folders a's folder names.
func decodeCursor(raw json.RawMessage, a args) (cursor, *rpcError) {
	var c cursor
	if !mcpevents.DecodeCursor(raw, &c) || len(c.Places) == 0 || len(c.Places) > 2 {
		return cursor{}, mcpevents.RefusedCursor()
	}
	for _, p := range c.Places {
		if p.Validity == 0 || p.Folder == "" {
			return cursor{}, mcpevents.RefusedCursor()
		}
	}
	if a.folder != "" && (len(c.Places) != 1 || c.Places[0].Folder != a.folder) ||
		a.folder == "" && c.Places[0].Folder != "INBOX" {
		return cursor{}, mcpevents.RefusedCursor()
	}
	return c, nil
}

// watched is the folders a poll with no cursor starts on: folder, or INBOX and the Junk
// folder, found by its role once (#3912).
func (s *Events) watched(ctx context.Context, folder string) ([]string, error) {
	if folder != "" {
		return []string{folder}, nil
	}
	s.mu.Lock()
	junk, found := s.junk, s.junkFound
	s.mu.Unlock()
	if !found {
		list, err := s.Mailbox.Folders(ctx)
		if err != nil {
			return nil, err
		}
		for _, f := range list {
			if f.Role == "junk" {
				junk = f.Name
				break
			}
		}
		s.mu.Lock()
		s.junk, s.junkFound = junk, true
		s.mu.Unlock()
	}
	if junk == "" {
		return []string{"INBOX"}, nil
	}
	return []string{"INBOX", junk}, nil
}

// MARK: Polling

const (
	// nextPollMs is the pace with IDLE on the folder (a quiet poll costs the server nothing)
	// and without.
	idlePollMs  = 10000
	plainPollMs = 60000
)

// Events answers events/poll over a Mailbox, with Watchers (which may be nil) to know when
// a folder is quiet.
type Events struct {
	Mailbox  *Mailbox
	Watchers *Watchers

	mu    sync.Mutex
	quiet map[string]quiet
	// junk is the Junk folder's name, "" when the mailbox has none, once junkFound.
	junk      string
	junkFound bool
}

// quiet is what a folder was at a poll: its watch's count, and its mark.
type quiet struct {
	changes uint64
	mark    Mark
}

// Poll answers events/poll's params.
func (s *Events) Poll(ctx context.Context, raw json.RawMessage) (map[string]any, *rpcError) {
	p, bad := mcpevents.ParseParams(raw)
	if bad != nil {
		return nil, bad
	}
	if p.Name != EventName {
		return nil, mcpevents.NoEvent(p.Name, EventNames())
	}
	a, bad := checkArgs(p.Arguments)
	if bad != nil {
		return nil, bad
	}
	var c cursor
	if p.FirstPoll() {
		folders, err := s.watched(ctx, a.folder)
		if err != nil {
			return nil, eventsError(err)
		}
		for _, folder := range folders {
			c.Places = append(c.Places, place{Folder: folder})
		}
	} else if c, bad = decodeCursor(p.Cursor, a); bad != nil {
		return nil, bad
	}

	out := []any{}
	more, allLive, budget := false, true, p.Limit()
	for i := range c.Places {
		at := &c.Places[i]
		changes, live := s.Watchers.Folder(at.Folder).State()
		allLive = allLive && live
		if p.FirstPoll() {
			mark, err := s.Mailbox.Mark(ctx, at.Folder)
			if err != nil {
				return nil, eventsError(err)
			}
			s.remember(at.Folder, live, changes, mark)
			at.Validity, at.UID = mark.Validity, uint32(mark.Next)-1
			continue
		}
		if more || s.unchanged(at.Folder, live, changes, *at) {
			continue // after a full page, the next poll goes on
		}
		if budget <= 0 {
			more = true
			continue
		}
		found, mark, folderMore, err := s.Mailbox.Since(ctx, at.Folder, at.Validity, imap.UID(at.UID), budget)
		if err != nil {
			return nil, eventsError(err)
		}
		s.remember(at.Folder, live, changes, mark)
		if mark.Validity != at.Validity {
			// The server renumbered the folder: start it again from now, and say mail may be missed.
			at.Validity, at.UID = mark.Validity, uint32(mark.Next)-1
			continue
		}
		more, budget = folderMore, budget-len(found)
		if !folderMore && mark.Next > 0 {
			at.UID = max(at.UID, uint32(mark.Next)-1) // past mail deleted before it was seen, too
		}
		for _, m := range found {
			at.UID = max(at.UID, uint32(m.uid))
			if !a.match(m) {
				continue
			}
			event := map[string]any{
				"eventId":   fmt.Sprintf("%s:%s", EventName, m.ID),
				"name":      EventName,
				"timestamp": m.Date.Format(time.RFC3339),
				"data": map[string]any{"id": m.ID, "folder": m.Folder, "from": m.From, "to": m.To,
					"subject": m.Subject, "date": m.Date.Format(time.RFC3339), "authenticated": m.Authenticated},
			}
			event["sender"] = senderOf(m)
			out = append(out, mcpevents.Enveloped(event, s.messageRef(m), ""))
		}
	}
	pace := plainPollMs
	if allLive {
		pace = idlePollMs
	}
	return map[string]any{"events": out, "cursor": c.encoded(), "truncated": false, "hasMore": more, "nextPollMs": pace}, nil
}

// messageRef is the ref of the mail an event is about (#4728): email:message:<mailbox>#<id>,
// the mailbox being the account's user, in lower case, and the id its Message-ID (or the
// server's own id for a mail with none). A mail comes once, so there is no key.
func (s *Events) messageRef(m Summary) wire.Ref {
	id := m.messageID
	if id == "" {
		id = m.ID
	}
	mailbox := ""
	if s.Mailbox != nil && s.Mailbox.Account != nil {
		if a, err := s.Mailbox.Account(); err == nil {
			mailbox = a.User
		}
	}
	if id == "" {
		return wire.Ref{}
	}
	return mcpevents.Ref("email", "message", mailbox, id)
}

// remember keeps the folder's mark at changes, when IDLE holds it.
func (s *Events) remember(folder string, live bool, changes uint64, mark Mark) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.quiet == nil {
		s.quiet = map[string]quiet{}
	}
	if !live {
		delete(s.quiet, folder)
		return
	}
	s.quiet[folder] = quiet{changes: changes, mark: mark}
}

// unchanged is true when IDLE has held the folder since a poll that found the cursor's
// place at its end, and the server has said nothing since.
func (s *Events) unchanged(folder string, live bool, changes uint64, c place) bool {
	if !live {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	q, ok := s.quiet[folder]
	return ok && q.changes == changes && q.mark.Validity == c.Validity && uint32(q.mark.Next) <= c.UID+1
}

// eventsError is a mailbox failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var m *MailError
	if !errors.As(err, &m) {
		return &rpcError{Code: -32603, Message: err.Error()}
	}
	switch m.Kind {
	case NotSignedIn:
		return &rpcError{Code: -32012, Message: m.Message, Data: map[string]any{"reason": "not connected"}}
	case NotFound:
		return invalidParams("%s: check folder", m.Message)
	}
	return &rpcError{Code: -32603, Message: m.Message}
}
