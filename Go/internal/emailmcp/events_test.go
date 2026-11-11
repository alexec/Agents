package emailmcp

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
)

// poll is one events/poll; cursor "" is the first.
func poll(t *testing.T, s *Events, args map[string]any, cursor string) (map[string]any, *rpcError) {
	t.Helper()
	p := map[string]any{"name": EventName, "arguments": args}
	if cursor != "" {
		p["cursor"] = cursor
	}
	raw, _ := json.Marshal(p)
	return s.Poll(context.Background(), raw)
}

func mustPoll(t *testing.T, s *Events, args map[string]any, cursor string) ([]any, string) {
	t.Helper()
	r, err := poll(t, s, args, cursor)
	if err != nil {
		t.Fatalf("poll: %v", err)
	}
	return r["events"].([]any), r["cursor"].(string)
}

func TestReceivedStartsFromNowAndFilters(t *testing.T) {
	f := newFakeMail(t, nil)
	f.deliver("INBOX", plain("old@example.com", fakeUser, "Before", "old"))
	s := &Events{Mailbox: f.mailbox()}

	all := map[string]any{}
	gitlab := map[string]any{"from": "*@*gitlab.com", "subject": "*CODE*"}
	events, allCursor := mustPoll(t, s, all, "")
	if len(events) != 0 {
		t.Fatalf("a first poll raises nothing: %v", events)
	}
	_, gitlabCursor := mustPoll(t, s, gitlab, "")

	f.deliver("INBOX", plain("GitLab <gitlab@mg.gitlab.com>", "Agents <"+fakeUser+">", "Your sign-in code", "Your code is 482913."))
	f.deliver("INBOX", plain("news@example.org", fakeUser, "Weekly news", "Nothing much."))

	events, allCursor = mustPoll(t, s, all, allCursor)
	if len(events) != 2 {
		t.Fatalf("all: %v", events)
	}
	first := events[0].(map[string]any)
	data := first["data"].(map[string]any)
	if data["subject"] != "Your sign-in code" || data["folder"] != "INBOX" || data["date"] != "2026-10-20T09:30:00Z" ||
		first["name"] != EventName || first["eventId"] != EventName+":"+data["id"].(string) {
		t.Fatalf("event: %v", first)
	}
	for _, key := range []string{"body", "text"} {
		if _, ok := data[key]; ok {
			t.Fatalf("the event carries the mail's %s: %v", key, data)
		}
	}
	if events, _ := mustPoll(t, s, all, allCursor); len(events) != 0 {
		t.Fatalf("raised twice: %v", events)
	}

	events, _ = mustPoll(t, s, gitlab, gitlabCursor)
	if len(events) != 1 || events[0].(map[string]any)["data"].(map[string]any)["subject"] != "Your sign-in code" {
		t.Fatalf("from and subject: %v", events)
	}
	_, toCursor := mustPoll(t, s, map[string]any{"to": "nobody@*"}, "")
	f.deliver("INBOX", plain("a@example.com", fakeUser, "Third", "3"))
	if events, _ := mustPoll(t, s, map[string]any{"to": "nobody@*"}, toCursor); len(events) != 0 {
		t.Fatalf("to: %v", events)
	}
}

func TestReceivedInAnotherFolderAndPages(t *testing.T) {
	f := newFakeMail(t, nil)
	s := &Events{Mailbox: f.mailbox()}
	args := map[string]any{"folder": "Archive"}
	_, c := mustPoll(t, s, args, "")
	for _, subject := range []string{"one", "two", "three"} {
		f.deliver("Archive", plain("a@example.com", fakeUser, subject, subject))
	}
	f.deliver("INBOX", plain("a@example.com", fakeUser, "inbox", "inbox"))
	raw, _ := json.Marshal(map[string]any{"name": EventName, "arguments": args, "cursor": c, "maxEvents": 2})
	r, err := s.Poll(context.Background(), raw)
	if err != nil {
		t.Fatal(err)
	}
	if events := r["events"].([]any); len(events) != 2 || r["hasMore"] != true {
		t.Fatalf("page one: %v", r)
	}
	events, _ := mustPoll(t, s, args, r["cursor"].(string))
	if len(events) != 1 || events[0].(map[string]any)["data"].(map[string]any)["subject"] != "three" {
		t.Fatalf("page two: %v", events)
	}
	// A cursor is for its own folder.
	if _, err := poll(t, s, map[string]any{}, c); err == nil || err.Code != -32602 {
		t.Fatalf("another folder's cursor: %v", err)
	}
}

// With no folder, the event hears the Junk folder too (#3912): a sign-up code the server
// took for spam still comes, and a cursor goes on in both folders.
func TestReceivedHearsJunkByDefault(t *testing.T) {
	f := newFakeMail(t, nil)
	// The in-memory server keeps no role, so this is found by its name; a real server says \Junk.
	if err := f.user.Create("Spam", nil); err != nil {
		t.Fatal(err)
	}
	f.deliver("Spam", plain("old@example.com", fakeUser, "Before", "old"))
	s := &Events{Mailbox: f.mailbox()}
	_, c := mustPoll(t, s, nil, "")
	_, inboxOnly := mustPoll(t, s, map[string]any{"folder": "INBOX"}, "")

	f.deliver("Spam", plain("noreply@example.com", fakeUser, "Your code", "Your code is 482913."))
	f.deliver("INBOX", plain("a@example.com", fakeUser, "Inbox", "inbox"))
	events, c := mustPoll(t, s, nil, c)
	if len(events) != 2 {
		t.Fatalf("INBOX and Junk: %v", events)
	}
	if data := events[1].(map[string]any)["data"].(map[string]any); data["folder"] != "Spam" || data["subject"] != "Your code" {
		t.Fatalf("the Junk mail: %v", data)
	}
	if events, _ := mustPoll(t, s, nil, c); len(events) != 0 {
		t.Fatalf("raised twice: %v", events)
	}
	if events, _ := mustPoll(t, s, map[string]any{"folder": "INBOX"}, inboxOnly); len(events) != 1 {
		t.Fatalf("folder INBOX leaves Junk out: %v", events)
	}
	// A full page in INBOX leaves Junk for the next poll.
	f.deliver("INBOX", plain("a@example.com", fakeUser, "one", "1"))
	f.deliver("INBOX", plain("a@example.com", fakeUser, "two", "2"))
	f.deliver("Spam", plain("a@example.com", fakeUser, "three", "3"))
	raw, _ := json.Marshal(map[string]any{"name": EventName, "cursor": c, "maxEvents": 2})
	r, err := s.Poll(context.Background(), raw)
	if err != nil || len(r["events"].([]any)) != 2 || r["hasMore"] != true {
		t.Fatalf("page one: %v %v", r, err)
	}
	events, _ = mustPoll(t, s, nil, r["cursor"].(string))
	if len(events) != 1 || events[0].(map[string]any)["data"].(map[string]any)["subject"] != "three" {
		t.Fatalf("page two: %v", events)
	}
}

func TestIDLETellsAQuietPollToAskNothing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := newFakeMail(t, nil)
	s := &Events{Mailbox: f.mailbox(), Watchers: NewWatchers(ctx, f.account)}
	s.Watchers.Retry = 50 * time.Millisecond
	w := s.Watchers.Folder("INBOX")
	waitFor(t, "IDLE", func() bool { _, live := w.State(); return live })

	r, err := poll(t, s, nil, "")
	if err != nil || r["nextPollMs"] != idlePollMs {
		t.Fatalf("first poll: %v %v", r, err)
	}
	c := r["cursor"].(string)
	// Quiet: the answer comes from what IDLE said, with the server out of reach.
	s.Mailbox.Account = func() (Account, error) { return Account{}, ErrNotConnected }
	s.Mailbox.Close()
	if events, again := mustPoll(t, s, nil, c); len(events) != 0 || again != c {
		t.Fatalf("quiet poll: %v %s", events, again)
	}

	s.Mailbox.Account = f.account
	before, _ := w.State()
	f.deliver("INBOX", plain("a@example.com", fakeUser, "New", "new"))
	waitFor(t, "IDLE to see the new mail", func() bool { n, _ := w.State(); return n > before })
	if events, _ := mustPoll(t, s, nil, c); len(events) != 1 {
		t.Fatalf("after new mail: %v", events)
	}
}

func TestWithoutIDLEEveryPollAsks(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := newFakeMail(t, imap.CapSet{imap.CapIMAP4rev1: {}})
	s := &Events{Mailbox: f.mailbox(), Watchers: NewWatchers(ctx, f.account)}
	r, err := poll(t, s, nil, "")
	if err != nil || r["nextPollMs"] != plainPollMs {
		t.Fatalf("first poll: %v %v", r, err)
	}
	time.Sleep(200 * time.Millisecond) // time for a watcher to reach IDLE, were there one
	if _, live := s.Watchers.Folder("INBOX").State(); live {
		t.Fatal("IDLE on a server without it")
	}
	f.deliver("INBOX", plain("a@example.com", fakeUser, "New", "new"))
	if events, _ := mustPoll(t, s, nil, r["cursor"].(string)); len(events) != 1 {
		t.Fatalf("after new mail: %v", events)
	}
}

func TestPollRefusals(t *testing.T) {
	f := newFakeMail(t, nil)
	s := &Events{Mailbox: f.mailbox()}
	for name, tc := range map[string]struct {
		params string
		code   int
	}{
		"unknown event":    {`{"name":"email.sent"}`, -32011},
		"unknown argument": {`{"name":"email.received","arguments":{"body":"x"}}`, -32602},
		"not a string":     {`{"name":"email.received","arguments":{"from":3}}`, -32602},
		"bad cursor":       {`{"name":"email.received","cursor":"nope"}`, -32602},
		"no folder":        {`{"name":"email.received","arguments":{"folder":"Nowhere"}}`, -32602},
	} {
		if _, err := s.Poll(context.Background(), json.RawMessage(tc.params)); err == nil || err.Code != tc.code {
			t.Errorf("%s: %v", name, err)
		}
	}
	none := &Events{Mailbox: &Mailbox{Account: func() (Account, error) { return Account{}, ErrNotConnected }}}
	if _, err := poll(t, none, nil, ""); err == nil || err.Code != -32012 || err.Data["reason"] != "not connected" {
		t.Fatalf("not connected: %v", err)
	}
}

func TestGlobs(t *testing.T) {
	for pattern, cases := range map[string]map[string]bool{
		"*@gitlab.com":      {"noreply@gitlab.com": true, "NoReply@GitLab.com": true, "a@gitlab.com.evil.org": false},
		"*verification*":    {"Your verification code": true, "Verify": false},
		"code ?":            {"code 1": true, "code 12": false},
		"a.b@example.com":   {"a.b@example.com": true, "axb@example.com": false},
		"[x]*":              {"[x] hi": true, "x hi": false},
		"noreply@*.aws.com": {"noreply@signin.aws.com": true, "noreply@aws.com": false},
	} {
		re := glob(pattern)
		for text, want := range cases {
			if re.MatchString(text) != want {
				t.Errorf("%q on %q: want %v", pattern, text, want)
			}
		}
	}
	if !anyMatches(glob("*@gitlab.com"), []string{"GitLab <gitlab@gitlab.com>"}) {
		t.Fatal("a named address is matched on its address")
	}
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("no %s in 10s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// authenticated: "true" hears only mail the receiving server authenticated: a forged From
// with no pass, or with a pass the sender wrote itself below the server's, raises nothing.
func TestReceivedAuthenticatedOnly(t *testing.T) {
	f := newFakeMail(t, nil)
	s := &Events{Mailbox: f.mailbox()}
	only := map[string]any{"from": "noreply@github.com", "authenticated": "true"}
	_, cursor := mustPoll(t, s, only, "")
	_, allCursor := mustPoll(t, s, map[string]any{"from": "noreply@github.com"}, "")

	f.deliver("INBOX", plain("GitHub <noreply@github.com>", fakeUser, "Forged", "Your code is 111111."))
	f.deliver("INBOX", "Authentication-Results: mx.example.com; dmarc=fail header.from=github.com\n"+
		"Authentication-Results: mx.example.com; dmarc=pass header.from=github.com\n"+
		plain("GitHub <noreply@github.com>", fakeUser, "Forged too", "Your code is 222222."))
	f.deliver("INBOX", "Authentication-Results: mx.example.com; dkim=pass header.d=github.com; dmarc=pass header.from=github.com\n"+
		plain("GitHub <noreply@github.com>", fakeUser, "Your code", "Your code is 333333."))

	events, _ := mustPoll(t, s, only, cursor)
	if len(events) != 1 {
		t.Fatalf("authenticated: %v", events)
	}
	data := events[0].(map[string]any)["data"].(map[string]any)
	if data["subject"] != "Your code" || data["authenticated"] != true {
		t.Fatalf("event: %v", data)
	}
	// Its sender, for a channel link (#1762): the address, and the aligned DKIM pass.
	sender := events[0].(map[string]any)["sender"].(map[string]any)
	if sender["channel"] != "email" || sender["identity"] != "noreply@github.com" ||
		sender["dkim"].(map[string]any)["result"] != "pass" || sender["dkim"].(map[string]any)["domain"] != "github.com" {
		t.Fatalf("sender: %v", sender)
	}
	events, _ = mustPoll(t, s, map[string]any{"from": "noreply@github.com"}, allCursor)
	if len(events) != 3 || events[0].(map[string]any)["data"].(map[string]any)["authenticated"] != false {
		t.Fatalf("without the filter: %v", events)
	}
	// A forged From has no DKIM pass, whatever the sender wrote below the server's line.
	for _, e := range events[:2] {
		if dkim := e.(map[string]any)["sender"].(map[string]any)["dkim"].(map[string]any); dkim["result"] != "none" {
			t.Fatalf("forged: %v", e)
		}
	}
	if _, err := poll(t, s, map[string]any{"authenticated": "maybe"}, ""); err == nil {
		t.Fatal("authenticated takes true or false")
	}
}

// The Microsoft sign-up mail that mail-code.py missed (#4322): its receiving server split its
// results into four headers, and authenticated: "true" with a glob on the display-name
// address hears it.
func TestReceivedHearsSplitResults(t *testing.T) {
	raw, err := os.ReadFile("testdata/split-results.eml")
	if err != nil {
		t.Fatal(err)
	}
	f := newFakeMail(t, nil)
	s := &Events{Mailbox: f.mailbox()}
	args := map[string]any{"from": "*microsoft*", "authenticated": "true"}
	_, cursor := mustPoll(t, s, args, "")
	f.deliver("INBOX", string(raw))
	events, _ := mustPoll(t, s, args, cursor)
	if len(events) != 1 {
		t.Fatalf("events: %v", events)
	}
	if data := events[0].(map[string]any)["data"].(map[string]any); data["subject"] != "Verify your email address" || data["authenticated"] != true {
		t.Fatalf("event: %v", data)
	}
}

// A mail with no From, or with two, still has a sender, one that names no one and passes no
// DKIM, so its link check refuses it; a from filter hears only a mail with one From.
func TestAMailWithoutOneFromNamesNoOne(t *testing.T) {
	f := newFakeMail(t, nil)
	s := &Events{Mailbox: f.mailbox()}
	_, cursor := mustPoll(t, s, map[string]any{}, "")
	_, fromCursor := mustPoll(t, s, map[string]any{"from": "noreply@github.com"}, "")

	signed := "Authentication-Results: mx.example.com; dkim=pass header.d=github.com; dmarc=pass header.from=github.com\n"
	f.deliver("INBOX", signed+plain("noreply@github.com, x@example.net", fakeUser, "Two", "two"))
	f.deliver("INBOX", signed+plain("undisclosed:;", fakeUser, "None", "none"))

	events, _ := mustPoll(t, s, map[string]any{}, cursor)
	if len(events) != 2 {
		t.Fatalf("events: %v", events)
	}
	for _, e := range events {
		sender, ok := e.(map[string]any)["sender"].(map[string]any)
		if !ok || sender["channel"] != "email" || sender["identity"] != "" ||
			sender["dkim"].(map[string]any)["result"] != "none" {
			t.Fatalf("sender: %v", e)
		}
	}
	if events, _ := mustPoll(t, s, map[string]any{"from": "noreply@github.com"}, fromCursor); len(events) != 0 {
		t.Fatalf("from filter: %v", events)
	}
}
