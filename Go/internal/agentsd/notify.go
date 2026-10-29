package agentsd

import (
	"encoding/json"
	"fmt"
	"math"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// notify is the person told something happened (#2805): a notice, which goes the way a
// need does (spec 021: silent where the chat is in front of them, muted with the session,
// the Mac when they are at it, else the control plane's device), but asks nothing and is
// no Needs you row. The person's attention is one bucket for every agent on this host:
// a short burst, then one notice back each cool-down, and nothing queued.

// The person's two settings, in the display preferences every client shows.
const (
	noticeBurstKey    = "noticeBurst"
	noticeCooldownKey = "noticeCooldownMinutes"
)

// The defaults Alex chose (#2805), and the bounds the settings take.
const (
	defaultNoticeBurst    = 3
	defaultNoticeCooldown = 10 * time.Minute
	mostNoticeBurst       = 20
	mostNoticeCooldown    = 24 * time.Hour
	// noticeLife is how long a notice stays posted when nobody opens its chat.
	noticeLife = 24 * time.Hour
)

// noticeBucket is the person's attention: how many notices are left, as of when.
type noticeBucket struct {
	tokens float64
	at     time.Time
	set    bool
}

// postedNotice is a notice still posted: withdrawn when its chat is opened, the session
// goes, or a day passes.
type postedNotice struct {
	id      string
	agentID wire.UUID
	h3      string
	raised  wire.Date
}

// noticeLimits are the person's burst and cool-down, or the defaults.
func (d *Daemon) noticeLimits() (int, time.Duration) {
	burst, cooldown := defaultNoticeBurst, defaultNoticeCooldown
	prefs := d.preferences()
	var n float64
	if v, ok := prefs[noticeBurstKey]; ok && json.Unmarshal(v, &n) == nil && n >= 1 {
		burst = min(int(n), mostNoticeBurst)
	}
	if v, ok := prefs[noticeCooldownKey]; ok && json.Unmarshal(v, &n) == nil && n > 0 {
		cooldown = min(time.Duration(n*float64(time.Minute)), mostNoticeCooldown)
	}
	return burst, cooldown
}

// takeNotice takes one notice from the bucket, if one is left: what is left after it, or
// when the next comes back. Notices come back one at a time, each cool-down, so agents
// that met the limit together do not all go again at once. Called with attentionMu held.
func (d *Daemon) takeNotice(at time.Time, burst int, cooldown time.Duration) (left int, next time.Time, ok bool) {
	b := &d.noticeBucket
	if !b.set {
		b.tokens, b.at, b.set = float64(burst), at, true
	}
	if elapsed := at.Sub(b.at); elapsed > 0 {
		b.tokens += float64(elapsed) / float64(cooldown)
	}
	b.tokens = math.Min(b.tokens, float64(burst))
	b.at = at
	if b.tokens < 1 {
		return 0, at.Add(time.Duration((1 - b.tokens) * float64(cooldown))), false
	}
	b.tokens--
	return int(b.tokens), at.Add(time.Duration((1 - (b.tokens - math.Floor(b.tokens))) * float64(cooldown))), true
}

// noticeNeedsLocked is every notice still posted, as needs; a notice whose chat is in
// front of the person, whose session went, or that is a day old is dropped. Called with
// attentionMu held, from needs().
func (d *Daemon) noticeNeedsLocked(at time.Time) []wire.Need {
	var out []wire.Need
	kept := d.notices[:0]
	for _, n := range d.notices {
		a := d.Store.Agent(n.agentID)
		watched := false
		for _, p := range d.presences {
			watched = watched || (p.active && p.watching != nil && *p.watching == n.agentID)
		}
		if a == nil || a.State == wire.AgentStateArchived || watched || at.Sub(n.raised.Time()) >= noticeLife {
			continue
		}
		kept = append(kept, n)
		id, agentID := n.id, n.agentID
		folder := folderPath(a)
		title := ""
		if a.Title != nil {
			title = *a.Title
		}
		out = append(out, wire.Need{ID: wire.NeedID{Notice: &id}, AgentID: &agentID, Folder: fileURL(folder, true),
			Kind: wire.NeedKindNotice, RaisedAt: n.raised,
			Headline: truncating(wire.Headline{H1: filepath.Base(folder), H2: title, H3: n.h3})})
	}
	d.notices = kept
	return out
}

// noticeTime is a time as the agent is told it: the host's clock, to the minute.
func noticeTime(t time.Time) string { return t.Local().Format("15:04") }

// notify is the notify tool.
func (d *Daemon) notify(id wire.UUID, args map[string]json.RawMessage) (string, error) {
	title := strings.TrimSpace(argString(args, "title"))
	body := strings.TrimSpace(argString(args, "body"))
	if title == "" {
		return "", Invalid("Nothing was sent: send a `title` that says what happened.")
	}
	if d.Store.Agent(id) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was sent."}
	}
	notice := wire.SentNotice{Title: title}
	if body != "" {
		notice.Body = &body
	}
	burst, cooldown := d.noticeLimits()
	at := nowFunc()
	var reply string
	switch {
	case d.muted(&id):
		notice.Outcome = wire.NoticeOutcomeMuted
		reply = "Not sent: the person muted this conversation. It is on the record in the chat."
	case d.watched(id):
		notice.Outcome = wire.NoticeOutcomeShownHere
		reply = "Not sent as a notification: the person is looking at this conversation, so it is shown here."
	default:
		d.attentionMu.Lock()
		left, next, ok := d.takeNotice(at, burst, cooldown)
		if ok {
			h3 := title
			if body != "" {
				h3 += " — " + body
			}
			d.notices = append(d.notices, postedNotice{id: string(store.NewUUID()), agentID: id, h3: h3, raised: wire.DateOf(at)})
		}
		d.attentionMu.Unlock()
		if !ok {
			nextAt := wire.DateOf(next)
			notice.Outcome, notice.NextAt = wire.NoticeOutcomeCoolingDown, &nextAt
			wait := int(math.Ceil(next.Sub(at).Seconds()))
			reply = fmt.Sprintf("In the cool-down: the next notice can go at %s (in %d seconds). Nothing was sent or queued.",
				noticeTime(next), wait)
			break
		}
		notice.Outcome = wire.NoticeOutcomeSent
		reply = fmt.Sprintf("Sent. %d more can go now; the next comes back at %s.", left, noticeTime(next))
	}
	d.record(id, wire.TranscriptEntryKind{Notified: &wire.TranscriptEntryKindNotified{Value: notice}})
	// Something new for the person, as a reply is (#70): unread until they look.
	if notice.Outcome != wire.NoticeOutcomeShownHere {
		d.change(id, func(a *wire.Agent) {
			yes := true
			a.IsUnread = &yes
		})
	}
	if notice.Outcome == wire.NoticeOutcomeSent {
		d.reconsider()
	}
	return reply, nil
}
