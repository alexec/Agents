package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/apns"
	"github.com/alexec/agents/Go/internal/controlplane/notices"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/webpush"
	"github.com/alexec/agents/Go/wire"
)

// WebPusher is what posts the control plane's Web Push to a browser (#1486):
// webpush.Client, or a fake.
type WebPusher interface {
	Send(ctx context.Context, p webpush.Push) error
	PublicKey() string
}

// webPushes is the control plane's way to a browser: a browser has no relay host and no
// mailbox, so every notice the ladder sends to one goes from here, relay or none. One
// queue, sent in order by one worker. It sends no withdrawal (deliver says why).
type webPushes struct {
	s      *Service
	sender WebPusher
	queue  chan webpush.Push
}

func newWebPushes(s *Service, sender WebPusher) *webPushes {
	p := &webPushes{s: s, sender: sender, queue: make(chan webpush.Push, pushQueue)}
	go p.run()
	return p
}

func webPushOf(s *records.WebPushSubscription) webpush.Subscription {
	return webpush.Subscription{Endpoint: s.Endpoint, P256dh: s.P256dh, Auth: s.Auth}
}

// deliver queues one delivery for its browser. The item goes whole: Web Push seals it to
// the browser's keys, so the push service reads none of it.
func (p *webPushes) deliver(d notices.RelayDelivery) {
	client := p.s.records.Client(string(d.Device))
	if client == nil || client.WebPush == nil {
		p.s.log(fmt.Sprintf("notice: no Web Push subscription for %s", d.Device))
		return
	}
	push, err := webPushFor(d, *client.WebPush)
	if err != nil {
		p.s.log(fmt.Sprintf("notice: could not seal a Web Push for %s: %v", d.Device, err))
		return
	}
	select {
	case p.queue <- push:
	default:
		p.s.log(fmt.Sprintf("notice: the Web Push queue is full; dropped one for %s", d.Device))
	}
}

// webPushFor is a delivery as a browser's service worker reads it: a ControlPushItem.
// One too big loses its buttons, then its words, before it is not sent.
func webPushFor(d notices.RelayDelivery, s records.WebPushSubscription) (webpush.Push, error) {
	if d.Headline == nil {
		return webpush.Push{}, errors.New("a browser gets no withdrawal")
	}
	item := wire.ControlPushItem{NeedID: d.NeedID, Alert: d.Alert}
	full := apns.Truncated(*d.Headline)
	bare := full
	bare.Answers = nil
	placeholder := wire.Headline{H1: "Agents", H2: "An agent", H3: "needs you"}
	tries := []*wire.Headline{&full, &bare, &placeholder}
	needID, _ := json.Marshal(d.NeedID)
	sum := sha256.Sum256(needID)
	// A topic is at most 32 base64url characters: a newer push for the need replaces one
	// the push service still holds.
	topic := base64.RawURLEncoding.EncodeToString(sum[:24])
	for _, headline := range tries {
		item.Headline = headline
		payload, _ := json.Marshal(item)
		if len(payload) <= webpush.MaxPayload {
			return webpush.Push{Subscription: webPushOf(&s), Payload: payload, Urgent: item.Alert, Topic: topic}, nil
		}
	}
	return webpush.Push{}, errors.New("too big for Web Push")
}

func (p *webPushes) run() {
	for {
		select {
		case <-p.s.stop:
			return
		case push := <-p.queue:
			p.send(push)
		}
	}
}

func (p *webPushes) send(push webpush.Push) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	err := p.sender.Send(ctx, push)
	switch {
	case err == nil:
		p.s.log("notice: sent a Web Push")
	case errors.Is(err, webpush.ErrGone):
		p.s.log("notice: a push service says a browser's subscription is gone; it is forgotten")
		p.forget(push.Endpoint)
	default:
		p.s.log("notice: " + err.Error())
	}
}

// forget takes a subscription its push service refused off the browser it was on. The
// page subscribes again the next time it opens.
func (p *webPushes) forget(endpoint string) {
	for _, c := range p.s.records.Clients() {
		if c.WebPush == nil || c.WebPush.Endpoint != endpoint {
			continue
		}
		err := p.s.records.ChangeClient(context.Background(), c.ID, func(c *records.ClientRecord) bool {
			if c.WebPush == nil || c.WebPush.Endpoint != endpoint {
				return false
			}
			c.WebPush = nil
			return true
		})
		if err != nil {
			p.s.log("notice: could not forget a gone Web Push subscription: " + err.Error())
		}
	}
}
