package agentsd

import (
	"context"
	"fmt"
	"log"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Forge requests (#3865, spec 3862 §4): a GitHub issue labelled alex-todo or needs-account,
// with its "## What Alex does" checklist, or a pull request labelled needs-approval, with its
// screenshots, is a request like an agent's question. A sweep every forgeRequestEvery lists
// the open items with each label (forge/issues and forge/pulls, so one search for every folder)
// and opens, updates or ends their records. Answered in the app, the answer goes back to
// GitHub as the person: a ticked line ticks the issue's line, the last one takes the label and
// the person off and says so in a comment; an approval comments and sets approved or
// changes-wanted. The labels then only mirror the request, and a label set by hand still
// opens or ends it at the next sweep.

// forgeRequestLabel is a label that makes a request, on an issue or a pull request.
type forgeRequestLabel struct {
	label string
	pr    bool
	kind  wire.RequestKind
}

// forgeRequestLabels are the three labels (spec 3862 §4: a fixed set, not a setting).
var forgeRequestLabels = []forgeRequestLabel{
	{"alex-todo", false, wire.RequestKindStep},
	{"needs-account", false, wire.RequestKindAccount},
	{reviewLabel, true, wire.RequestKindApprove},
}

var (
	// forgeRequestEvery is the sweep; forgeRequestFirst is how long after the start the first is.
	forgeRequestEvery = 5 * time.Minute
	forgeRequestFirst = 20 * time.Second
)

// checklistHeading starts the checklist: "## What Alex does", whoever's name it says.
var (
	checklistHeading = regexp.MustCompile(`^##\s+What\s+.+\s+does\s*$`)
	checklistLine    = regexp.MustCompile(`^(\s*[-*]\s+\[)([ xX])(\]\s+)(.*)$`)
	screenshotsHead  = regexp.MustCompile(`^##\s+Screenshots\s*$`)
	imageLink        = regexp.MustCompile(`!\[[^\]]*\]\(([^)\s]+)|<img[^>]+src="([^"]+)"`)
)

// checklistOf is the lines under the body's first "## What <name> does" heading, up to the
// next heading.
func checklistOf(body string) []wire.RequestChecklistLine {
	out := []wire.RequestChecklistLine{}
	in := false
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimRight(line, "\r")
		switch {
		case !in && checklistHeading.MatchString(line):
			in = true
		case in && strings.HasPrefix(line, "#"):
			return out
		case in:
			if m := checklistLine.FindStringSubmatch(line); m != nil {
				out = append(out, wire.RequestChecklistLine{Text: strings.TrimSpace(m[4]), Done: m[2] != " "})
			}
		}
	}
	return out
}

// tickChecklist ticks the checklist's lines at done (by index) in the body; the others stay
// as they are, so a line ticked on the forge meanwhile is not taken back.
func tickChecklist(body string, done []int64) string {
	lines := strings.Split(body, "\n")
	in, i := false, 0
	for n, line := range lines {
		switch {
		case !in && checklistHeading.MatchString(strings.TrimRight(line, "\r")):
			in = true
		case in && strings.HasPrefix(line, "#"):
			return strings.Join(lines, "\n")
		case in:
			if m := checklistLine.FindStringSubmatchIndex(line); m != nil {
				if slices.Contains(done, int64(i)) {
					lines[n] = line[:m[4]] + "x" + line[m[5]:]
				}
				i++
			}
		}
	}
	return strings.Join(lines, "\n")
}

// screenshotsOf is the image links under the body's "## Screenshots" heading.
func screenshotsOf(body string) []string {
	var out []string
	in := false
	for _, line := range strings.Split(body, "\n") {
		switch {
		case !in && screenshotsHead.MatchString(strings.TrimRight(line, "\r")):
			in = true
		case in && strings.HasPrefix(line, "## "):
			return out
		case in:
			for _, m := range imageLink.FindAllStringSubmatch(line, -1) {
				out = append(out, m[1]+m[2])
			}
		}
	}
	return out
}

func allDone(lines []wire.RequestChecklistLine) bool {
	for _, l := range lines {
		if !l.Done {
			return false
		}
	}
	return true
}

// sweepForgeRequests lists each label's open items once and brings the records in step.
func (d *Daemon) sweepForgeRequests(ctx context.Context) {
	for _, l := range forgeRequestLabels {
		list, err := d.forgeList(ctx, l.pr, wire.ForgeListRequest{State: new("open"), Label: new(l.label), Limit: new(int64(forgeListMost))})
		if err != nil {
			continue
		}
		seen := map[string]bool{}
		for _, i := range list.Items {
			repo, number, ok := nodeOfRepo(i.Node)
			if !ok || repo.forge != "github" || i.URL == nil || i.Folder == nil || i.State != "open" {
				continue
			}
			if l.pr && slices.ContainsFunc(i.Labels, func(x wire.ForgeLabel) bool { return slices.Contains(reviewAnswered, x.Name) }) {
				continue
			}
			seen[*i.URL] = true
			d.forgeRequestSeen(ctx, l, i, repo, number)
		}
		// Only a whole list says an item lost its label: a forge that could not be read, or a
		// list cut at its page, ends nothing.
		if len(list.Errors) > 0 || list.Cursor != nil {
			continue
		}
		for _, r := range d.listRequests(wire.RequestsListStateOpen, "") {
			if r.Forge != nil && r.Forge.Label == l.label && !seen[r.Forge.URL] {
				d.forgeRequestGone(ctx, r)
			}
		}
	}
}

// openForgeRequest is the open request for an item and label, or nil.
func (d *Daemon) openForgeRequest(url, label string) *wire.Request {
	d.requests.mu.Lock()
	defer d.requests.mu.Unlock()
	for _, r := range d.requests.byID {
		if r.State == wire.RequestStateOpen && r.Forge != nil && r.Forge.URL == url && r.Forge.Label == label {
			c := copyRequest(r)
			return &c
		}
	}
	return nil
}

// forgeRequestSeen opens the request for an item the sweep saw, or reads it again when the
// item changed since.
func (d *Daemon) forgeRequestSeen(ctx context.Context, l forgeRequestLabel, i wire.ForgeItem, repo forgeRepo, number int) {
	at := now()
	old := d.openForgeRequest(*i.URL, l.label)
	if old != nil && old.Forge.UpdatedAt != nil && *old.Forge.UpdatedAt == i.UpdatedAt {
		d.requests.mu.Lock()
		if r := d.requests.byID[old.ID]; r != nil && r.Forge != nil {
			r.Forge.SeenAt = at
			d.saveRequestLocked(r)
		}
		d.requests.mu.Unlock()
		return
	}
	if old == nil && len(d.listRequests(wire.RequestsListStateOpen, "")) >= requestFileLimit {
		log.Printf("requests: %d open already, so %s is not a request yet", requestFileLimit, *i.URL)
		return
	}
	kind := lineage.KindIssue
	if l.pr {
		kind = lineage.KindPR
	}
	detail, err := d.forgeItem(ctx, kind, wire.ForgeItemRequest{Node: i.Node})
	if err != nil {
		log.Printf("requests: %s: %v", *i.URL, err)
		return
	}
	updated := i.UpdatedAt
	f := &wire.RequestForge{Provider: repo.forge, Repo: repo.path, Item: kind, Number: int64(number), URL: *i.URL,
		Label: l.label, Checklist: []wire.RequestChecklistLine{}, Author: i.Author, UpdatedAt: &updated, SeenAt: at}
	if l.pr {
		f.Screenshots = screenshotsOf(detail.Body)
	} else {
		f.Checklist = checklistOf(detail.Body)
	}
	d.requests.mu.Lock()
	if d.requests.byID == nil {
		d.requests.byID = map[wire.UUID]*wire.Request{}
	}
	r := (*wire.Request)(nil)
	if old != nil {
		r = d.requests.byID[old.ID]
	}
	opened := r == nil
	if opened {
		r = &wire.Request{ID: wire.UUID(store.NewUUID()), Kind: l.kind, Source: wire.RequestSourceForge, State: wire.RequestStateOpen,
			Folder: string(store.FolderURL(*i.Folder)), Waiters: []wire.RequestWaiter{}, AskedAt: at}
		d.requests.byID[r.ID] = r
	}
	r.Title, r.Forge = i.Title, f
	d.saveRequestLocked(r)
	c := copyRequest(r)
	d.requests.mu.Unlock()
	Broadcast(d, wire.NotifyRequestsChanged, wire.RequestUpdate{Request: c})
	if opened {
		d.raiseRequestEvent("request.opened", c, nil, nil)
	}
}

// forgeRequestGone ends the request for an item the sweep no longer lists with its label:
// closed, it is answered when every line is ticked and else dropped; open, the label came off
// (or a pull request got approved or changes-wanted), and it is answered.
func (d *Daemon) forgeRequestGone(ctx context.Context, r wire.Request) {
	kind := map[string]string{"issue": lineage.KindIssue, "pr": lineage.KindPR}[r.Forge.Item]
	repo := forgeRepo{r.Forge.Provider, r.Forge.Repo}
	node := repo.issue(int(r.Forge.Number))
	if kind == lineage.KindPR {
		node = repo.pr(int(r.Forge.Number))
	}
	detail, err := d.forgeItem(ctx, kind, wire.ForgeItemRequest{Node: node})
	if err != nil {
		return
	}
	switch {
	case detail.Item.State != "open" && (kind == lineage.KindPR || !allDone(checklistOf(detail.Body))):
		d.endRequest(r.ID, wire.RequestStateDropped, nil, wire.RequestDroppedWhyForgeClosed, nil)
	case detail.Item.State != "open":
		d.endRequest(r.ID, wire.RequestStateAnswered, new("Closed with every step done"), "", nil)
	default:
		answer := "The label " + r.Forge.Label + " was taken off"
		for _, l := range detail.Item.Labels {
			if slices.Contains(reviewAnswered, l.Name) {
				answer = map[string]string{"approved": "approve", "changes-wanted": "changes"}[l.Name]
			}
		}
		d.endRequest(r.ID, wire.RequestStateAnswered, &answer, "", nil)
	}
}

// answerForgeRequest is requests/answer for a forge request: a checklist or an approval, sent
// to GitHub as the person.
func (d *Daemon) answerForgeRequest(ctx context.Context, rec wire.Request, a wire.RequestAnswer, by *wire.AuditActor) (wire.RequestUpdate, error) {
	f := rec.Forge
	if f.Provider != "github" {
		return wire.RequestUpdate{}, Invalid("Only a GitHub request is answered here; answer it on %s.", f.URL)
	}
	gh, err := d.forgeGitHub()
	if err != nil {
		return wire.RequestUpdate{}, err
	}
	number := int(f.Number)
	var answer string
	switch {
	case a.Checklist != nil && f.Item == lineage.KindIssue:
		page, err := gh.ItemPage(ctx, f.Repo, number, "")
		if err != nil {
			return wire.RequestUpdate{}, err
		}
		body := tickChecklist(page.Body, a.Checklist.Done)
		if body != page.Body {
			if err := gh.SetBody(ctx, f.Repo, number, body); err != nil {
				return wire.RequestUpdate{}, err
			}
		}
		lines := checklistOf(body)
		if !allDone(lines) {
			d.requests.mu.Lock()
			r := d.requests.byID[rec.ID]
			if r != nil && r.Forge != nil {
				r.Forge.Checklist = lines
				d.saveRequestLocked(r)
				rec = copyRequest(r)
			}
			d.requests.mu.Unlock()
			Broadcast(d, wire.NotifyRequestsChanged, wire.RequestUpdate{Request: rec})
			return wire.RequestUpdate{Request: rec}, nil
		}
		if err := gh.SetLabels(ctx, f.Repo, number, nil, []string{f.Label}); err != nil {
			return wire.RequestUpdate{}, err
		}
		if c, ok := d.githubConnection(); ok && c.Login != "" {
			if err := gh.Unassign(ctx, f.Repo, number, []string{c.Login}); err != nil {
				log.Printf("requests: %s: unassign: %v", f.URL, err)
			}
		}
		if _, err := gh.CommentOnPR(ctx, f.Repo, number, "Done in Agents: every step is ticked."); err != nil {
			log.Printf("requests: %s: comment: %v", f.URL, err)
		}
		d.requests.mu.Lock()
		if r := d.requests.byID[rec.ID]; r != nil && r.Forge != nil {
			r.Forge.Checklist = lines
		}
		d.requests.mu.Unlock()
		answer = "Every step is done"
	case a.Approval != nil && f.Item == lineage.KindPR:
		action := a.Approval.Action
		note := strings.TrimSpace(deref(a.Approval.Note))
		add := "approved"
		remove := []string{f.Label}
		switch action {
		case "approve":
			if note == "" {
				note = "Approved in Agents."
			}
		case "changes":
			if note == "" {
				return wire.RequestUpdate{}, Invalid("Say what to change in the note.")
			}
			add, remove = "changes-wanted", nil
		default:
			return wire.RequestUpdate{}, Invalid("An approval is approve or changes, not %q.", action)
		}
		// The person's own comment: no <!-- agent --> mark.
		if _, err := gh.CommentOnPR(ctx, f.Repo, number, note); err != nil {
			return wire.RequestUpdate{}, err
		}
		if err := gh.SetLabels(ctx, f.Repo, number, []string{add}, remove); err != nil {
			return wire.RequestUpdate{}, err
		}
		answer = action + ": " + note
	default:
		return wire.RequestUpdate{}, Invalid("This request takes a %s answer.", map[string]string{"issue": "checklist", "pr": "approval"}[f.Item])
	}
	if !d.endRequest(rec.ID, wire.RequestStateAnswered, &answer, "", by) {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already."}
	}
	after := d.request(rec.ID)
	return wire.RequestUpdate{Request: *after}, nil
}

// addForgeRequestWaiter is a session that waits on request.* with where: {pr: <n>} or
// {issue: <n>}: a waiter of each open forge request on that item.
func (d *Daemon) addForgeRequestWaiter(item, number string, agent wire.UUID) {
	n, err := strconv.ParseInt(number, 10, 64)
	if err != nil {
		return
	}
	for _, r := range d.listRequests(wire.RequestsListStateOpen, "") {
		if r.Forge != nil && r.Forge.Item == item && r.Forge.Number == n {
			d.addRequestWaiter(r.ID, agent)
		}
	}
}

// forgeRequestDetails are a forge request's event details: pr or issue, and url.
func forgeRequestDetails(r wire.Request, details map[string]string) {
	if r.Forge == nil {
		return
	}
	details[r.Forge.Item] = fmt.Sprint(r.Forge.Number)
	details["url"] = r.Forge.URL
}

// sweepForgeRequestsEvery sweeps until ctx ends, at Shutdown.
func (d *Daemon) sweepForgeRequestsEvery(ctx context.Context) {
	t := time.NewTimer(forgeRequestFirst)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		d.sweepForgeRequests(ctx)
		t.Reset(forgeRequestEvery)
	}
}

func (d *Daemon) startForgeRequests() { d.goLoop("forge requests", d.sweepForgeRequestsEvery) }
