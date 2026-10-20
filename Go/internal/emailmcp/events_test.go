package emailmcp

import (
	"context"
	"encoding/json"
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
