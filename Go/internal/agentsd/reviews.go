package agentsd

import (
	"context"
	"log"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The pull requests in the sidebar's For Review (#3330): each folder's open pull requests
// labelled needs-approval, a UI change waiting for the person (#2811), until one is labelled
// approved or changes-wanted, is closed, or the person dismisses it. Read with forge/pulls
// (#3129), one search for every folder, on its own poll; said with each folder's pins
// (FolderPins.reviews, pins/changed). A dismissal is kept in <root>/review-dismissals.json,
// so a dismissed pull request never comes back; not in the folder's .agents/pins.json, which
// a repo may check in. A pull request the person opened is kept in <root>/review-opened.json
// (#3464), so every client draws its row read.

const (
	reviewLabel = "needs-approval"
	// reviewDismissalsPerFolder bounds the dismissals kept for one folder: the oldest go first.
	reviewDismissalsPerFolder = 200
	// reviewOpenedPerFolder bounds the opened pull requests kept for one folder: the oldest go first.
	reviewOpenedPerFolder = 200
)

// The labels that say the person has answered: the pull request leaves For Review.
var reviewAnswered = []string{"approved", "changes-wanted"}

// reviewEvery is the poll: forge/pulls keeps an answer a minute, so no faster than that.
var reviewEvery = 2 * time.Minute

// reviewFirst is how long after the start the first poll is.
var reviewFirst = 15 * time.Second

type reviewBook struct {
	reviewMu sync.Mutex
	// reviews is each folder's pull requests for review as last read, dismissed ones left out.
	reviews map[string][]wire.ReviewPull
	// dismissed is each folder's dismissed pull requests' URLs, oldest first.
	dismissed       map[string][]string
	dismissedLoaded bool
	// opened is each folder's opened pull requests' URLs, oldest first.
	opened       map[string][]string
	openedLoaded bool
}

func (d *Daemon) reviewDismissalsPath() string {
	return filepath.Join(d.Store.Loc.Root, "review-dismissals.json")
}

func (d *Daemon) dismissedLocked() map[string][]string {
	if !d.dismissedLoaded {
		d.dismissedLoaded = true
		d.dismissed = map[string][]string{}
		readStore(d.reviewDismissalsPath(), &d.dismissed, "every dismissed pull request may be listed again")
		if d.dismissed == nil {
			d.dismissed = map[string][]string{}
		}
	}
	return d.dismissed
}

func (d *Daemon) reviewOpenedPath() string {
	return filepath.Join(d.Store.Loc.Root, "review-opened.json")
}

func (d *Daemon) openedLocked() map[string][]string {
	if !d.openedLoaded {
		d.openedLoaded = true
		d.opened = map[string][]string{}
		readStore(d.reviewOpenedPath(), &d.opened, "every opened pull request may be drawn unread again")
		if d.opened == nil {
			d.opened = map[string][]string{}
		}
	}
	return d.opened
}

// reviewsFor is a folder's pull requests for review, newest first, each one the person opened
// said so; nil when it has none.
func (d *Daemon) reviewsFor(folder string) []wire.ReviewPull {
	d.reviewMu.Lock()
	defer d.reviewMu.Unlock()
	prs := slices.Clone(d.reviews[folder])
	opened := d.openedLocked()[folder]
	for i := range prs {
		if slices.Contains(opened, string(prs[i].URL)) {
			prs[i].Opened = new(true)
		}
	}
	return prs
}

// reviewPullOf is a forge item as For Review lists it, and whether it belongs there.
func reviewPullOf(i wire.ForgeItem) (wire.ReviewPull, bool) {
	if i.State != "open" || i.URL == nil || *i.URL == "" || (i.Draft != nil && *i.Draft) {
		return wire.ReviewPull{}, false
	}
	labelled := false
	for _, l := range i.Labels {
		if slices.Contains(reviewAnswered, l.Name) {
			return wire.ReviewPull{}, false
		}
		labelled = labelled || l.Name == reviewLabel
	}
	// A ref is "github:owner/name#12", or "gitlab:group/project!12".
	ref := i.Node.Ref
	if at := strings.Index(ref, ":"); at >= 0 {
		ref = ref[at+1:]
	}
	at := strings.LastIndexAny(ref, "#!")
	if !labelled || at < 0 {
		return wire.ReviewPull{}, false
	}
	number, err := strconv.ParseInt(ref[at+1:], 10, 64)
	if err != nil {
		return wire.ReviewPull{}, false
	}
	return wire.ReviewPull{URL: wire.URL(*i.URL), Number: number, Title: i.Title, Repo: ref[:at],
		Ref: new(i.Node.Ref), Author: i.Author, UpdatedAt: i.UpdatedAt}, true
}

// readReviews reads every folder's open pull requests labelled needs-approval once, and says a
// folder's pins again when its list changed. A forge that could not be read keeps its last list.
func (d *Daemon) readReviews(ctx context.Context) {
	list, err := d.forgeList(ctx, true, wire.ForgeListRequest{State: new("open"), Label: new(reviewLabel),
		Limit: new(int64(forgeListMost))})
	if err != nil || len(list.Errors) > 0 {
		return
	}
	read := map[string][]wire.ReviewPull{}
	for _, i := range list.Items {
		if p, ok := reviewPullOf(i); ok && i.Folder != nil {
			read[*i.Folder] = append(read[*i.Folder], p)
		}
	}
	d.setReviews(read)
}

// setReviews keeps what was read, dismissed ones left out, and says each folder that changed.
func (d *Daemon) setReviews(read map[string][]wire.ReviewPull) {
	d.reviewMu.Lock()
	dismissed := d.dismissedLocked()
	next := map[string][]wire.ReviewPull{}
	for folder, prs := range read {
		var kept []wire.ReviewPull
		for _, p := range prs {
			if !slices.Contains(dismissed[folder], string(p.URL)) {
				kept = append(kept, p)
			}
		}
		slices.SortStableFunc(kept, func(a, b wire.ReviewPull) int {
			switch {
			case a.UpdatedAt > b.UpdatedAt:
				return -1
			case a.UpdatedAt < b.UpdatedAt:
				return 1
			}
			return 0
		})
		if len(kept) > 0 {
			next[folder] = kept
		}
	}
	var changed []string
	for folder, prs := range next {
		if !slices.Equal(prs, d.reviews[folder]) {
			changed = append(changed, folder)
		}
	}
	for folder := range d.reviews {
		if _, ok := next[folder]; !ok {
			changed = append(changed, folder)
		}
	}
	d.reviews = next
	d.reviewMu.Unlock()
	for _, folder := range changed {
		d.pinsChanged(folder)
	}
}

// dismissReview takes a pull request out of a folder's For Review for good.
func (d *Daemon) dismissReview(folder string, url wire.URL) {
	d.reviewMu.Lock()
	dismissed := d.dismissedLocked()
	if !slices.Contains(dismissed[folder], string(url)) {
		kept := append(dismissed[folder], string(url))
		if len(kept) > reviewDismissalsPerFolder {
			kept = kept[len(kept)-reviewDismissalsPerFolder:]
		}
		dismissed[folder] = kept
		if err := writeStore(d.reviewDismissalsPath(), dismissed); err != nil {
			log.Printf("for review: the dismissals were not written: %v", err)
		}
	}
	prs := slices.DeleteFunc(slices.Clone(d.reviews[folder]), func(p wire.ReviewPull) bool { return p.URL == url })
	if len(prs) == 0 {
		delete(d.reviews, folder)
	} else {
		d.reviews[folder] = prs
	}
	d.reviewMu.Unlock()
	d.pinsChanged(folder)
}

// openReview keeps that the person opened a pull request, so its row is drawn read.
func (d *Daemon) openReview(folder string, url wire.URL) {
	d.reviewMu.Lock()
	opened := d.openedLocked()
	if slices.Contains(opened[folder], string(url)) {
		d.reviewMu.Unlock()
		return
	}
	kept := append(opened[folder], string(url))
	if len(kept) > reviewOpenedPerFolder {
		kept = kept[len(kept)-reviewOpenedPerFolder:]
	}
	opened[folder] = kept
	if err := writeStore(d.reviewOpenedPath(), opened); err != nil {
		log.Printf("for review: the opened pull requests were not written: %v", err)
	}
	d.reviewMu.Unlock()
	d.pinsChanged(folder)
}

func (d *Daemon) registerReviews() {
	On(d, wire.CallReviewsDismiss, func(ctx context.Context, c *Client, r wire.ReviewDismissRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		if strings.TrimSpace(string(r.URL)) == "" {
			return wire.Empty{}, Invalid("reviews/dismiss names the pull request's url.")
		}
		d.dismissReview(folder, r.URL)
		return wire.Empty{}, nil
	})
	On(d, wire.CallReviewsOpen, func(ctx context.Context, c *Client, r wire.ReviewOpenRequest) (wire.Empty, error) {
		folder, err := d.knownPinFolder(r.Folder)
		if err != nil {
			return wire.Empty{}, err
		}
		if strings.TrimSpace(string(r.URL)) == "" {
			return wire.Empty{}, Invalid("reviews/open names the pull request's url.")
		}
		d.openReview(folder, r.URL)
		return wire.Empty{}, nil
	})
}

// readReviewsEvery reads For Review's pull requests until ctx ends, at Shutdown (#3522).
func (d *Daemon) readReviewsEvery(ctx context.Context) {
	t := time.NewTimer(reviewFirst)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		d.readReviews(ctx)
		t.Reset(reviewEvery)
	}
}

// startReviews starts the poll.
func (d *Daemon) startReviews() { d.goLoop("for review", d.readReviewsEvery) }
