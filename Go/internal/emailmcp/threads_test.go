package emailmcp

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
)

// Threads for the messaging contract (#4340), over the fake mailbox.

// threaded is a plain-text message with its own Message-Id (none when id is ""), minutes
// after 9:00, and extra headers.
func threaded(from, id, subject string, minute int, headers ...string) string {
	h := ""
	if id != "" {
		h = "Message-Id: <" + id + ">\n"
	}
	for _, x := range headers {
		h += x + "\n"
	}
	return fmt.Sprintf("From: %s\nTo: %s\nSubject: %s\nDate: %s\n%sMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n\nAbout %s.\n",
		from, fakeUser, subject, time.Date(2026, 11, 9, 9, minute, 0, 0, time.UTC).Format(time.RFC1123Z), h, subject)
}

func TestThreadsGroupByReferencesAndSubject(t *testing.T) {
	ctx := context.Background()
	f := newFakeMail(t, nil)
	if err := f.user.Create("Sent", nil); err != nil {
		t.Fatal(err)
	}
	f.deliver("INBOX", threaded("Ann <ann@example.com>", "plan@example.com", "Plan", 1))
	f.deliver("INBOX", threaded("bob@example.com", "lunch@example.com", "Lunch", 2))
	f.deliver("INBOX", threaded("Cy <cy@example.com>", "plan-2@example.com", "Re: Plan", 3,
		"In-Reply-To: <plan@example.com>", "References: <plan@example.com>"))
	f.deliver("INBOX", threaded("dee@example.com", "", "RE: lunch", 4))
	f.deliver("INBOX", threaded("eve@example.com", "", "Hello", 5))
	f.deliver("Sent", threaded(fakeUser, "plan-3@example.com", "Re: Plan", 6,
		"In-Reply-To: <plan-2@example.com>", "References: <plan@example.com> <plan-2@example.com>"))
	m := f.mailbox()

	threads, next, err := m.Threads(ctx, "INBOX", "", false, 0)
	if err != nil || next != "" {
		t.Fatalf("threads: %v %q", err, next)
	}
	var titles []string
	for _, th := range threads {
		titles = append(titles, fmt.Sprintf("%s/%d", th.Title, th.Unread))
	}
	if want := []string{"Hello/1", "RE: lunch/2", "Re: Plan/2"}; !slices.Equal(titles, want) {
		t.Fatalf("threads, newest first: %v", titles)
	}

	plan, _, err := m.ThreadMessages(ctx, threads[2].ID, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	var from []string
	for _, msg := range plan {
		from = append(from, msg.Folder+" "+bare(msg.From[0]))
	}
	if want := []string{"Sent " + fakeUser, "INBOX cy@example.com", "INBOX ann@example.com"}; !slices.Equal(from, want) {
		t.Fatalf("the thread, newest first, with its answer in Sent: %v", from)
	}
	if plan[2].Text != "About Plan." || !plan[2].Unread {
		t.Fatalf("its text, and still unread: %+v", plan[2])
	}

	lunch, _, err := m.ThreadMessages(ctx, threads[1].ID, "", 0)
	if err != nil || len(lunch) != 2 || lunch[0].Subject != "RE: lunch" || lunch[1].Subject != "Lunch" {
		t.Fatalf("a reply with no References joins by its subject: %+v %v", lunch, err)
	}
	hello, _, err := m.ThreadMessages(ctx, threads[0].ID, "", 0)
	if err != nil || len(hello) != 1 || hello[0].Subject != "Hello" {
		t.Fatalf("a mail with no Message-Id is a thread of its own: %+v %v", hello, err)
	}

	// A page at a time, the newest first.
	var pages []string
	cursor := ""
	for range 4 {
		page, after, err := m.ThreadMessages(ctx, threads[2].ID, cursor, 1)
		if err != nil {
			t.Fatal(err)
		}
		for _, msg := range page {
			pages = append(pages, bare(msg.From[0]))
		}
		if cursor = after; cursor == "" {
			break
		}
	}
	if want := []string{fakeUser, "cy@example.com", "ann@example.com"}; !slices.Equal(pages, want) {
		t.Fatalf("pages: %v", pages)
	}

	if unread, _, err := m.Threads(ctx, "INBOX", "", true, 0); err != nil || len(unread) != 3 {
		t.Fatalf("unread: %+v %v", unread, err)
	}
	if err := m.MarkRead(ctx, hello[0].ID, true); err != nil {
		t.Fatal(err)
	}
	if unread, _, err := m.Threads(ctx, "INBOX", "", true, 0); err != nil || len(unread) != 2 {
		t.Fatalf("unread after one is read: %+v %v", unread, err)
	}

	for _, bad := range []string{"nope", "0:2"} {
		if _, _, err := m.Threads(ctx, "INBOX", bad, false, 0); err == nil || !strings.Contains(err.Error(), "no cursor") {
			t.Fatalf("cursor %q: %v", bad, err)
		}
		if _, _, err := m.ThreadMessages(ctx, threads[2].ID, bad, 0); err == nil || !strings.Contains(err.Error(), "no cursor") {
			t.Fatalf("read cursor %q: %v", bad, err)
		}
	}
	if _, _, err := m.ThreadMessages(ctx, "INBOX:1:1", "", 0); err == nil || !strings.Contains(err.Error(), "list_conversations") {
		t.Fatalf("a message id as a conversation: %v", err)
	}
}

func TestThreadsPageWithoutListingAThreadTwice(t *testing.T) {
	ctx := context.Background()
	f := newFakeMail(t, nil)
	f.deliver("INBOX", threaded("ann@example.com", "root@example.com", "Plan", 0))
	for i := 1; i <= 13; i++ {
		f.deliver("INBOX", threaded("news@example.org", fmt.Sprintf("n%d@example.org", i), fmt.Sprintf("News %d", i), i))
	}
	f.deliver("INBOX", threaded("cy@example.com", "reply@example.com", "Re: Plan", 20,
		"In-Reply-To: <root@example.com>", "References: <root@example.com>"))
	m := f.mailbox()

	seen := map[string]bool{}
	var titles []string
	cursor := ""
	for page := 0; ; page++ {
		if page > 20 {
			t.Fatal("the pages do not end")
		}
		// limit 1 groups a window of 10 mails: the thread's first mail is in a later window
		// than its reply.
		threads, next, err := m.Threads(ctx, "INBOX", cursor, false, 1+page%2)
		if err != nil {
			t.Fatal(err)
		}
		for _, th := range threads {
			if seen[th.ID] {
				t.Fatalf("%s listed twice", th.Title)
			}
			seen[th.ID] = true
			titles = append(titles, th.Title)
		}
		if cursor = next; cursor == "" {
			break
		}
	}
	if len(titles) != 14 || titles[0] != "Re: Plan" || titles[1] != "News 13" || titles[13] != "News 1" {
		t.Fatalf("every thread once, the newest first: %v", titles)
	}
}

// mark_conversation_read (#5137): a thread's unread mail is marked read, and the others stay
// unread; all marks the folder's.
func TestMarkThreadAndFolderRead(t *testing.T) {
	ctx := context.Background()
	f := newFakeMail(t, nil)
	f.deliver("INBOX", threaded("ann@example.com", "plan@example.com", "Plan", 1))
	f.deliver("INBOX", threaded("cy@example.com", "plan-2@example.com", "Re: Plan", 2,
		"In-Reply-To: <plan@example.com>", "References: <plan@example.com>"))
	f.deliver("INBOX", threaded("bob@example.com", "lunch@example.com", "Lunch", 3))
	f.deliver("INBOX", threaded("eve@example.com", "hi@example.com", "Hello", 4))
	m := f.mailbox()
	unread := func() []string {
		threads, _, err := m.Threads(ctx, "INBOX", "", true, 0)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, th := range threads {
			out = append(out, fmt.Sprintf("%s/%d", th.Title, th.Unread))
		}
		return out
	}
	threads, _, err := m.Threads(ctx, "INBOX", "", false, 0)
	if err != nil || len(threads) != 3 || threads[2].Title != "Re: Plan" {
		t.Fatalf("threads: %+v %v", threads, err)
	}
	if n, err := m.MarkThreadRead(ctx, threads[2].ID); err != nil || n != 2 {
		t.Fatalf("marked the thread: %d %v", n, err)
	}
	if got := unread(); !slices.Equal(got, []string{"Hello/1", "Lunch/1"}) {
		t.Fatalf("unread after the thread: %v", got)
	}
	if n, err := m.MarkThreadRead(ctx, threads[2].ID); err != nil || n != 0 {
		t.Fatalf("marked again: %d %v", n, err)
	}
	if n, err := m.MarkFolderRead(ctx, "INBOX"); err != nil || n != 2 {
		t.Fatalf("marked the folder: %d %v", n, err)
	}
	if got := unread(); len(got) != 0 {
		t.Fatalf("unread after all: %v", got)
	}
	if _, err := m.MarkThreadRead(ctx, "nope"); err == nil || !strings.Contains(err.Error(), "list_conversations") {
		t.Fatalf("not a conversation: %v", err)
	}
}
