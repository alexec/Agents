package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/apns"
	"github.com/alexec/agents/Go/internal/controlplane/notices"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// Pusher is what posts the control plane's own pushes (#1460): apns.Client, or a fake.
type Pusher interface {
	Send(ctx context.Context, p apns.Push) error
}

// pushes is the control plane's way to a phone or an iPad (public-security.md §5). One
// queue, sent in order by one worker, so a withdrawal never passes the post it takes
// back; held to pushQueue, and what does not fit is dropped and said.
type pushes struct {
	s      *Service
	sender Pusher
	queue  chan apns.Push
	// A Live Activity gets at most one update in each interval of this length (#4997).
	activityEvery time.Duration
	mu            sync.Mutex
	// By activity token: the updates held back.
	activities map[string]*activityThrottle
}

const pushQueue = 256

// liveActivityEvery is the least time between two updates of one Live Activity (#4997).
// With several lanes at work, a turn moves many times a minute, and each update wakes the
// Lock Screen.
const liveActivityEvery = time.Minute

// activityThrottle is one Live Activity's last update, and the newest one held back until
// its interval ends.
type activityThrottle struct {
	last   time.Time
	held   *apns.Push
	device string
	timer  *time.Timer
}

func newPushes(s *Service, sender Pusher, activityEvery time.Duration) *pushes {
	p := &pushes{s: s, sender: sender, queue: make(chan apns.Push, pushQueue), activityEvery: activityEvery,
		activities: map[string]*activityThrottle{}}
	go p.run()
	return p
}

// deliver seals one delivery to its device and queues it. A device with no token, or
// whose push cannot be sealed, gets nothing, and the log says so without the words.
func (p *pushes) deliver(d notices.RelayDelivery) {
	client := p.s.records.Client(string(d.Device))
	if client == nil || client.PushToken == nil {
		p.s.log(fmt.Sprintf("notice: no push token for %s", d.Device))
		return
	}
	push, err := sealPush(d, client.PublicKey, *client.PushToken)
	if err != nil {
		p.s.log(fmt.Sprintf("notice: could not seal a push for %s: %v", d.Device, err))
		return
	}
	select {
	case p.queue <- push:
	default:
		p.s.log(fmt.Sprintf("notice: the push queue is full; dropped one for %s", d.Device))
	}
}

// queueActivity queues a Live Activity's push (#1744) in the same line as the notices, so
// it goes in the order it was said. An activity gets at most one update in each interval
// (#4997): an update that comes sooner is held, a newer one takes its place, and the
// newest goes when the interval ends. An end goes at once, and the update held goes with
// nothing.
func (p *pushes) queueActivity(push apns.Push, device string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	for token, t := range p.activities {
		// Bound the map: an activity with nothing held and its interval ended is new again.
		if t.timer == nil && now.Sub(t.last) >= p.activityEvery {
			delete(p.activities, token)
		}
	}
	t := p.activities[push.Token]
	if push.Activity.End {
		if t != nil {
			if t.timer != nil {
				t.timer.Stop()
			}
			delete(p.activities, push.Token)
		}
		p.queueLocked(push, device)
		return
	}
	if t == nil {
		p.activities[push.Token] = &activityThrottle{last: now}
		p.queueLocked(push, device)
		return
	}
	t.held, t.device = &push, device
	if t.timer == nil {
		t.timer = time.AfterFunc(t.last.Add(p.activityEvery).Sub(now), func() { p.releaseHeld(push.Token, t) })
	}
}

// releaseHeld queues the newest update held for an activity, when its interval ends.
func (p *pushes) releaseHeld(token string, t *activityThrottle) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.activities[token] != t || t.held == nil {
		return // It ended.
	}
	push := *t.held
	t.held, t.timer, t.last = nil, nil, time.Now()
	p.queueLocked(push, t.device)
}

// queueLocked puts a Live Activity's push in the line; p.mu is held, so pushes for one
// activity go in the order they were let through.
func (p *pushes) queueLocked(push apns.Push, device string) {
	select {
	case p.queue <- push:
	default:
		p.s.log(fmt.Sprintf("live activity: the push queue is full; dropped one for %s", device))
	}
}

// sealPush is a delivery as APNs carries it: the item sealed whole, so the need's id and
// its words are legible only to the device. One too big for APNs loses its buttons, then
// its words, before it is not sent.
func sealPush(d notices.RelayDelivery, publicKey []byte, token records.PushToken) (apns.Push, error) {
	item := wire.ControlPushItem{NeedID: d.NeedID, Alert: d.Alert && d.Headline != nil, Timely: d.Timely}
	var tries []*wire.Headline
	if d.Headline != nil {
		full := apns.Truncated(*d.Headline)
		bare := full
		bare.Answers = nil
		placeholder := wire.Headline{H1: "Agents", H2: "An agent", H3: "needs you"}
		tries = []*wire.Headline{&full, &bare, &placeholder}
	} else {
		tries = []*wire.Headline{nil}
	}
	for _, headline := range tries {
		item.Headline = headline
		plaintext, _ := json.Marshal(item)
		sealed, err := apns.Seal(publicKey, apns.Purpose, plaintext)
		if err != nil {
			return apns.Push{}, err
		}
		push := apns.Push{Token: token.Token, Environment: wire.PushEnvironment(token.Environment), Alert: item.Alert,
			Timely: item.Alert && d.Timely != nil && *d.Timely, CollapseID: apns.CollapseID(d.NeedID), Sealed: sealed}
		if len(push.Payload()) <= apns.MaxPayload {
			return push, nil
		}
	}
	return apns.Push{}, errors.New("too big for APNs")
}

func (p *pushes) run() {
	for {
		select {
		case <-p.s.stop:
			return
		case push := <-p.queue:
			p.send(push)
		}
	}
}

func (p *pushes) send(push apns.Push) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	err := p.sender.Send(ctx, push)
	switch {
	case err == nil:
		what := "an alert"
		switch {
		case push.Activity != nil:
			what = "a Live Activity update"
			if push.Activity.End {
				what = "a Live Activity end"
			}
			// The priority, so a day's log counts the urgent ones (#4997).
			what += map[bool]string{true: " (priority 10)", false: " (priority 5)"}[push.Activity.Urgent]
		case !push.Alert:
			what = "a background push"
		}
		p.s.log("notice: sent " + what + " through APNs")
	case errors.Is(err, apns.ErrGone) && push.Activity != nil:
		p.s.log("live activity: APNs says an activity's token is gone; it is forgotten")
		for _, c := range p.s.records.Clients() {
			p.s.forgetActivityToken(c.ID, push.Token)
		}
	case errors.Is(err, apns.ErrGone):
		p.s.log("notice: APNs says a device's token is gone; it is forgotten")
		p.forgetToken(push.Token)
	default:
		p.s.log("notice: " + err.Error())
	}
}

// forgetToken takes a token Apple refused off the device it was on. The device sets a
// new one the next time it opens.
func (p *pushes) forgetToken(token string) {
	for _, c := range p.s.records.Clients() {
		if c.PushToken == nil || c.PushToken.Token != token {
			continue
		}
		err := p.s.records.ChangeClient(context.Background(), c.ID, func(c *records.ClientRecord) bool {
			if c.PushToken == nil || c.PushToken.Token != token {
				return false
			}
			c.PushToken = nil
			return true
		})
		if err != nil {
			p.s.log("notice: could not forget a gone push token: " + err.Error())
		}
	}
}
