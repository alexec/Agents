package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/noticebucket"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// notify is the person told something happened (#2805): a notice, which goes the way a
// need does (spec 021: silent where the chat is in front of them, muted with the session,
// the Mac when they are at it, else the control plane's device), but asks nothing and is
// no Needs you row. The person's attention is one bucket for every agent and every machine
// of theirs (#2859): a short burst, then one notice back each cool-down, and nothing
// queued. With a control plane, the bucket is the control plane's (notices/take); without
// one, or when it cannot be asked, this host keeps its own.

// The person's two settings, in the display preferences every client shows. With a
// control plane they follow the person (the notifications part of the user settings): a
// change here is sent there (user/setNoticeLimits), and what the control plane sends is
// written here.
const (
	noticeBurstKey    = "noticeBurst"
	noticeCooldownKey = "noticeCooldownMinutes"
)

const (
	// noticeLife is how long a notice stays posted when nobody opens its chat.
	noticeLife = 24 * time.Hour
	// noticePatience is how long notify waits for the control plane's bucket before it
	// takes from this host's.
	noticePatience = 5 * time.Second
)

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
	prefs := d.preferences()
	var burst, cooldown float64
	if v, ok := prefs[noticeBurstKey]; ok {
		json.Unmarshal(v, &burst)
	}
	if v, ok := prefs[noticeCooldownKey]; ok {
		json.Unmarshal(v, &cooldown)
	}
	return noticebucket.Limits(int64(burst), cooldown)
}

// noticeLimitsWire is the limits as the control plane takes them.
func noticeLimitsWire(burst int, cooldown time.Duration) wire.NoticeLimits {
	return wire.NoticeLimits{Burst: int64(burst), CooldownMinutes: cooldown.Minutes()}
}

// takeNotice takes one notice from this host's bucket. Called with attentionMu held.
func (d *Daemon) takeNotice(at time.Time, burst int, cooldown time.Duration) (left int, next time.Time, ok bool) {
	return d.noticeBucket.Take(at, burst, cooldown)
}

// takeNoticeOnControl takes one notice from the person's bucket on the control plane.
// asked is false when this host has no control plane or it could not be asked: then this
// host's own bucket decides.
func (d *Daemon) takeNoticeOnControl(burst int, cooldown time.Duration) (taken wire.NoticeTaken, asked bool) {
	ask := d.askControl.Load()
	if ask == nil {
		return taken, false
	}
	ctx, cancel := context.WithTimeout(d.ctx, noticePatience)
	defer cancel()
	out, err := (*ask)(ctx, wire.CallNoticesTake.Name, noticeLimitsWire(burst, cooldown))
	if err != nil || json.Unmarshal(out, &taken) != nil {
		log.Printf("notices/take: this host's own bucket decides: %v", err)
		return wire.NoticeTaken{}, false
	}
	return taken, true
}

// noticeLimitsChanged is the person setting Burst or Cool-down in a client of this host:
// with a control plane, the person's other machines take it too.
func (d *Daemon) noticeLimitsChanged(change map[string]wire.JSONValue) {
	_, burst := change[noticeBurstKey]
	_, cooldown := change[noticeCooldownKey]
	ask := d.askControl.Load()
	if !burst && !cooldown || ask == nil {
		return
	}
	limits := noticeLimitsWire(d.noticeLimits())
	safe.Go("user/setNoticeLimits", func() {
		ctx, cancel := context.WithTimeout(d.ctx, noticePatience)
		defer cancel()
		if _, err := (*ask)(ctx, wire.CallUserSetNoticeLimits.Name, limits); err != nil {
			log.Printf("user/setNoticeLimits: kept on this machine only: %v", err)
		}
	})
}

// writeNoticeLimits is the notifications part from the control plane, written into the
// display preferences, so this host and every client of it use the person's limits.
func (d *Daemon) writeNoticeLimits(raw wire.JSONValue) error {
	var limits wire.NoticeLimits
	if err := json.Unmarshal(raw, &limits); err != nil {
		return errors.New("not notice limits")
	}
	burst, cooldown := noticebucket.Limits(limits.Burst, limits.CooldownMinutes)
	_, err := d.setPreferences(map[string]wire.JSONValue{
		noticeBurstKey:    asJSON(burst),
		noticeCooldownKey: asJSON(max(int(math.Round(cooldown.Minutes())), 1)),
	})
	return err
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
		taken, asked := d.takeNoticeOnControl(burst, cooldown)
		d.attentionMu.Lock()
		left, next, ok := taken.Left, taken.NextAt.Time(), taken.Sent
		if !asked {
			var l int
			l, next, ok = d.takeNotice(at, burst, cooldown)
			left = int64(l)
		}
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
			wait := max(int(math.Ceil(next.Sub(at).Seconds())), 0)
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
