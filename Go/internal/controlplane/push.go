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

// pushes is the control plane's own way to a device when no Mac host relays notices
// (public-security.md §5). One queue, sent in order by one worker, so a withdrawal never
// passes the post it takes back; held to pushQueue, and what does not fit is dropped and
// said.
type pushes struct {
	s      *Service
	sender Pusher
	queue  chan apns.Push
	// The needs this copy pushed itself, by need and device: a withdrawal goes the way its
	// post went, even if a relay host is online by then. Held to pushKept.
	mu   sync.Mutex
	sent map[string]time.Time
}

const (
	pushQueue = 256
	pushKept  = 1024
)

func newPushes(s *Service, sender Pusher) *pushes {
	p := &pushes{s: s, sender: sender, queue: make(chan apns.Push, pushQueue), sent: map[string]time.Time{}}
	go p.run()
	return p
}

func pushKey(need wire.NeedID, device wire.UUID) string {
	b, _ := json.Marshal(need)
	return string(b) + "/" + string(device)
}

// pushedHere says whether this copy pushed this need to this device itself.
func (p *pushes) pushedHere(d notices.RelayDelivery) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, ok := p.sent[pushKey(d.NeedID, d.Device)]
	return ok
}

// deliver seals one delivery to its device and queues it. A device with no token, or
// whose push cannot be sealed, gets nothing, and the log says so without the words.
func (p *pushes) deliver(d notices.RelayDelivery) {
	key := pushKey(d.NeedID, d.Device)
	p.mu.Lock()
	if d.Headline == nil {
		delete(p.sent, key)
	} else {
		if len(p.sent) >= pushKept {
			p.dropOldest()
		}
		p.sent[key] = time.Now()
	}
	p.mu.Unlock()
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

func (p *pushes) dropOldest() {
	oldest, at := "", time.Time{}
	for k, t := range p.sent {
		if oldest == "" || t.Before(at) {
			oldest, at = k, t
		}
	}
	delete(p.sent, oldest)
}

// sealPush is a delivery as APNs carries it: the item sealed whole, so the need's id and
// its words are legible only to the device. One too big for APNs loses its buttons, then
// its words, before it is not sent.
func sealPush(d notices.RelayDelivery, publicKey []byte, token records.PushToken) (apns.Push, error) {
	item := wire.ControlPushItem{NeedID: d.NeedID, Alert: d.Alert && d.Headline != nil}
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
			CollapseID: apns.CollapseID(d.NeedID), Sealed: sealed}
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
		if !push.Alert {
			what = "a background push"
		}
		p.s.log("notice: sent " + what + " through APNs")
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
		if c.PushToken != nil && c.PushToken.Token == token {
			c.PushToken = nil
			if err := p.s.records.UpdateClient(context.Background(), c); err != nil {
				p.s.log("notice: could not forget a gone push token: " + err.Error())
			}
		}
	}
}
