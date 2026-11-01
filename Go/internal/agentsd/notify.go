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
// goes, or a day passes. Its id is its transcript entry's, so the banner names the line a
// tap goes to (#2860); to is where its line last said it went.
type postedNotice struct {
	id      string
	agentID wire.UUID
	h3      string
	raised  wire.Date
	to      wire.NoticeDevice
}

// noticeLimits are the person's burst and cool-down, from your layer (#2957, FR-002's new
// rule, moved from display.json on the first start, FR-012), or the defaults.
func (d *Daemon) noticeLimits() (int, time.Duration) {
	var burst int64
	var cooldown float64
	if n := d.yourPolicyRules().NoticeLimits; n != nil {
		if n.Burst != nil {
			burst = *n.Burst
		}
		if n.WaitMinutes != nil {
			cooldown = float64(*n.WaitMinutes)
		}
	}
	return noticebucket.Limits(burst, cooldown)
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

// writeNoticeLimits is the notifications part from the control plane, written into your
// layer (#2957), so this host and every client of it use the person's limits. display.json
// is also written, unchanged, so the window's old Notifications pane keeps working until
// slice 4 moves it to Agents ▸ Policy (FR-023).
func (d *Daemon) writeNoticeLimits(raw wire.JSONValue) error {
	var limits wire.NoticeLimits
	if err := json.Unmarshal(raw, &limits); err != nil {
		return errors.New("not notice limits")
	}
	burst, cooldown := noticebucket.Limits(limits.Burst, limits.CooldownMinutes)
	if _, err := d.setPreferences(map[string]wire.JSONValue{
		noticeBurstKey:    asJSON(burst),
		noticeCooldownKey: asJSON(max(int(math.Round(cooldown.Minutes())), 1)),
	}); err != nil {
		return err
	}
	return d.setYourNoticeLimits(int64(burst), cooldown)
}

// mirrorNoticeLimitsFrom reads noticeBurst and noticeCooldownMinutes out of m (the display
// preferences, just written by setPreferences) and saves them into your layer (#2957).
func (d *Daemon) mirrorNoticeLimitsFrom(m map[string]wire.JSONValue) {
	var burst, cooldown float64
	if v, ok := m[noticeBurstKey]; ok {
		json.Unmarshal(v, &burst)
	}
	if v, ok := m[noticeCooldownKey]; ok {
		json.Unmarshal(v, &cooldown)
	}
	b, c := noticebucket.Limits(int64(burst), cooldown)
	d.setYourNoticeLimits(int64(b), c)
}

// setYourNoticeLimits saves burst and cooldown into your layer's noticeLimits rule
// (#2957), which noticeLimits() now reads.
func (d *Daemon) setYourNoticeLimits(burst int64, cooldown time.Duration) error {
	wait := int64(math.Round(cooldown.Minutes()))
	return d.editYoursLocked(func(rules *wire.PolicyRules) error {
		rules.NoticeLimits = &wire.PolicyNoticeLimits{Burst: &burst, WaitMinutes: &wait}
		return nil
	})
}

// setYourArchiveMyChats saves the archive switch into your layer's archiveMyChats rule
// (#2957), which agentsMayArchiveMyChats() now reads.
func (d *Daemon) setYourArchiveMyChats(on bool) error {
	return d.editYoursLocked(func(rules *wire.PolicyRules) error { rules.ArchiveMyChats = &on; return nil })
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
	entryID := store.NewUUID()
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
			d.notices = append(d.notices, postedNotice{id: string(entryID), agentID: id, h3: h3, raised: wire.DateOf(at)})
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
	d.recordEntry(id, entryID, wire.TranscriptEntryKind{Notified: &wire.TranscriptEntryKindNotified{Value: notice}}, nil)
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

// noticeWentTo records where a posted notice went (#2860), after its line, once each time
// it goes somewhere new: the computer, when reconsider sends it to the window, or a device,
// when the control plane says so (notices/delivered). A notice no longer posted is not
// recorded: its chat was opened, so the line is in front of the person already.
func (d *Daemon) noticeWentTo(id string, to wire.NoticeDevice) {
	d.attentionMu.Lock()
	var agentID wire.UUID
	found := false
	for i := range d.notices {
		if d.notices[i].id == id && d.notices[i].to != to {
			d.notices[i].to, agentID, found = to, d.notices[i].agentID, true
		}
	}
	d.attentionMu.Unlock()
	if !found {
		return
	}
	delivery := wire.NoticeDelivery{Notice: wire.UUID(id), To: to}
	d.record(agentID, wire.TranscriptEntryKind{NoticeDelivered: &wire.TranscriptEntryKindNoticeDelivered{Value: delivery}})
}

// toldNoticeDelivered is notices/delivered: the control plane sent one of this host's
// notices to a device of the person's.
func (d *Daemon) toldNoticeDelivered(params json.RawMessage) {
	var told wire.NoticeDelivered
	if err := json.Unmarshal(params, &told); err != nil || told.Need.Notice == nil {
		log.Printf("notices/delivered: %v", err)
		return
	}
	d.noticeWentTo(*told.Need.Notice, told.To)
}
