package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/mail"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Channel links (#1762, spec 736 US7, FR-037): a channel identity (a Slack user, an email
// address) acts as a person only once that person has approved the link on one of their
// signed-in clients. A machine asks before a channel message starts anything
// (links/check); an identity not linked starts nothing, and its person is asked:
//
//   - the person whose sign-in email is the sender's email (for email, the address);
//   - with no such person, the admins, who send the request on to a person
//     (links/approve with for). Only the person named approves a link: an admin who could
//     link an identity to someone else could act as them.
//
// Email also needs DKIM: a pass, signed by the address's domain or a parent of it.
//
//	v1/links/<channel>/<sha256(identity)>.json   a link (data-model.md "Channel link")
//	v1/linkRequests/<request>.json               a request, kept a day after it ends

const (
	linksPrefix        = "v1/links/"
	linkRequestsPrefix = "v1/linkRequests/"
	linkLifetime       = 24 * time.Hour
	linkKept           = 24 * time.Hour
	// linksOpen is how many requests may wait at once.
	linksOpen = 50
	// requestsReadAgain is how long the requests read are used before they are read again,
	// unless a change here or at another copy drops them first (#2060).
	requestsReadAgain = time.Minute
)

var channelNameRule = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,39}$`)

// linkRecord is v1/links/<channel>/<sha256(identity)>.json.
type linkRecord struct {
	Channel    string        `json:"channel"`
	Identity   string        `json:"identity"`
	Name       string        `json:"name,omitempty"`
	User       string        `json:"user"`
	ApprovedBy string        `json:"approvedBy"`
	ApprovedAt records.Stamp `json:"approvedAt"`
}

// linkRequestRecord is v1/linkRequests/<request>.json.
type linkRequestRecord struct {
	ID       string        `json:"id"`
	Channel  string        `json:"channel"`
	Identity string        `json:"identity"`
	Name     string        `json:"name,omitempty"`
	Email    string        `json:"email,omitempty"`
	For      string        `json:"for,omitempty"`
	Created  records.Stamp `json:"created"`
	Expires  records.Stamp `json:"expires"`
	Result   string        `json:"result,omitempty"`
	By       string        `json:"by,omitempty"`
}

func linkKey(channel, identity string) string {
	sum := sha256.Sum256([]byte(identity))
	return linksPrefix + channel + "/" + hex.EncodeToString(sum[:]) + ".json"
}

func linkRequestKey(id string) string { return linkRequestsPrefix + id + ".json" }

type links struct {
	s   *Service
	now func() time.Time
	// One change at a time, so the limits hold at this copy.
	mu sync.Mutex
	// The requests as last read, and when: a burst of messages from senders not linked
	// reads them once, not once a message (#2060).
	readMu   sync.Mutex
	kept     []linkRequestRecord
	keptAt   time.Time
	keptGood bool
}

func newLinks(s *Service) *links { return &links{s: s, now: time.Now} }

// sender is a sender made plain: the channel in lower case, an email address in lower
// case. False when it cannot name anyone.
func plainSender(in wire.ChannelSender) (wire.ChannelSender, bool) {
	out := in
	out.Channel = strings.ToLower(strings.TrimSpace(in.Channel))
	out.Identity = strings.TrimSpace(in.Identity)
	if !channelNameRule.MatchString(out.Channel) || out.Identity == "" || len(out.Identity) > 320 || !utf8.ValidString(out.Identity) {
		return out, false
	}
	if name := strings.TrimSpace(deref(in.Name)); name != "" && utf8.RuneCountInString(name) <= 80 {
		out.Name = &name
	} else {
		out.Name = nil
	}
	if email := strings.ToLower(strings.TrimSpace(deref(in.Email))); email != "" && len(email) <= 320 {
		out.Email = &email
	} else {
		out.Email = nil
	}
	if out.Channel == "email" {
		address, err := mail.ParseAddress(out.Identity)
		if err != nil || address.Name != "" || address.Address != out.Identity {
			return out, false
		}
		out.Identity = strings.ToLower(out.Identity)
		out.Email = &out.Identity
	}
	return out, true
}

// dkimPasses says an email's DKIM result is a pass signed by the address's domain or a
// parent of it (DMARC's relaxed alignment).
func dkimPasses(address string, dkim *wire.ChannelDKIM) bool {
	if dkim == nil || !strings.EqualFold(strings.TrimSpace(dkim.Result), "pass") {
		return false
	}
	at := strings.LastIndexByte(address, '@')
	signer := strings.Trim(strings.ToLower(strings.TrimSpace(deref(dkim.Domain))), ".")
	if at < 0 || signer == "" || !strings.Contains(signer, ".") {
		return false
	}
	domain := address[at+1:]
	return domain == signer || strings.HasSuffix(domain, "."+signer)
}

// check is links/check: the linked person, or nothing, with a request made for the
// identity when none waits.
func (l *links) check(ctx context.Context, in wire.ChannelSender) (wire.ChannelLinkChecked, error) {
	sender, ok := plainSender(in)
	if !ok {
		return wire.ChannelLinkChecked{Refused: new("That sender names no one.")}, nil
	}
	if sender.Channel == "email" && !dkimPasses(sender.Identity, sender.Dkim) {
		l.s.log("an email from a sender whose DKIM did not pass was refused")
		return wire.ChannelLinkChecked{Refused: new("The email's DKIM check did not pass.")}, nil
	}
	link, _, err := l.read(ctx, sender.Channel, sender.Identity)
	if err != nil {
		return wire.ChannelLinkChecked{}, fail(storeUnavailable, "The channel links could not be read: %v", err)
	}
	if link != nil && l.s.isPerson(link.User) {
		return wire.ChannelLinkChecked{User: &link.User, UserName: optional(l.s.personName(link.User))}, nil
	}
	if err := l.ask(ctx, sender); err != nil {
		return wire.ChannelLinkChecked{}, err
	}
	return wire.ChannelLinkChecked{}, nil
}

// isPerson says a user is a person (not a bot) who is not removed. The local owner with
// no record yet is one.
func (s *Service) isPerson(user string) bool {
	p := s.records.Person(user)
	if p == nil {
		return user != "" && user == s.localOwner()
	}
	return !p.IsRemoved() && !p.IsBot()
}

// personForEmail is the one person with a sign-in of that email, or "".
func (l *links) personForEmail(email string) string {
	if email == "" {
		return ""
	}
	found := ""
	for _, p := range l.s.records.People() {
		if p.IsBot() {
			continue
		}
		for _, in := range p.SignIns {
			if strings.EqualFold(in.Email, email) {
				if found != "" && found != p.ID {
					return ""
				}
				found = p.ID
			}
		}
	}
	return found
}

// ask makes a request for an identity, unless one made for it has not expired yet: a
// denied identity asks again only a day later.
func (l *links) ask(ctx context.Context, sender wire.ChannelSender) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	all, err := l.all(ctx)
	if err != nil {
		return fail(storeUnavailable, "The link requests could not be read: %v", err)
	}
	waiting := 0
	for _, r := range all {
		if r.Channel == sender.Channel && r.Identity == sender.Identity && l.now().Before(r.Expires.Time) {
			return nil
		}
		if l.open(r) {
			waiting++
		}
	}
	if waiting >= linksOpen {
		return nil
	}
	now := records.At(l.now())
	r := linkRequestRecord{ID: newJoinID(), Channel: sender.Channel, Identity: sender.Identity, Name: deref(sender.Name),
		Email: deref(sender.Email), For: l.personForEmail(deref(sender.Email)), Created: now, Expires: records.At(now.Add(linkLifetime))}
	data, err := records.Encode(r)
	if err != nil {
		return err
	}
	if _, err := l.s.cfg.Store.Put(ctx, linkRequestKey(r.ID), data, store.Absent); err != nil {
		return err
	}
	l.readAgain()
	l.tellRequested(r)
	l.s.announce("linkRequested", r.ID, "")
	l.s.log("a " + r.Channel + " identity asks to be linked (request " + r.ID[:8] + ")")
	return nil
}

// all is every request kept; ended ones older than linkKept are deleted on the way. What
// was read is used again for requestsReadAgain, until a request changes.
func (l *links) all(ctx context.Context) ([]linkRequestRecord, error) {
	l.readMu.Lock()
	defer l.readMu.Unlock()
	if l.keptGood && l.now().Sub(l.keptAt) < requestsReadAgain {
		return slices.Clone(l.kept), nil
	}
	listed, err := l.s.cfg.Store.List(ctx, linkRequestsPrefix)
	if err != nil {
		return nil, err
	}
	now := l.now()
	out := []linkRequestRecord{}
	for _, entry := range listed {
		r, _, err := l.readRequest(ctx, strings.TrimSuffix(strings.TrimPrefix(entry.Key, linkRequestsPrefix), ".json"))
		if err != nil || r == nil {
			continue
		}
		if now.Sub(r.Expires.Time) > linkKept {
			l.s.cfg.Store.Delete(ctx, entry.Key)
			continue
		}
		out = append(out, *r)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Created.Before(out[b].Created.Time) })
	l.kept, l.keptAt, l.keptGood = out, now, true
	return slices.Clone(out), nil
}

// readAgain drops the requests read: one was made or changed, here or at another copy.
func (l *links) readAgain() {
	l.readMu.Lock()
	l.keptGood = false
	l.readMu.Unlock()
}

func (l *links) readRequest(ctx context.Context, id string) (*linkRequestRecord, string, error) {
	if !isJoinID(id) {
		return nil, "", nil
	}
	object, err := l.s.cfg.Store.Get(ctx, linkRequestKey(id))
	if err != nil || object == nil {
		return nil, "", err
	}
	var r linkRequestRecord
	if json.Unmarshal(object.Data, &r) != nil || r.ID != id {
		return nil, "", nil
	}
	return &r, object.ETag, nil
}

func (l *links) writeRequest(ctx context.Context, r linkRequestRecord, etag string) error {
	data, err := records.Encode(r)
	if err != nil {
		return err
	}
	_, err = l.s.cfg.Store.Put(ctx, linkRequestKey(r.ID), data, store.Matching(etag))
	l.readAgain()
	if err != nil {
		if store.IsConflict(err) {
			return fail(notPermitted, "That request was decided already.")
		}
		return err
	}
	return nil
}

func (l *links) read(ctx context.Context, channel, identity string) (*linkRecord, string, error) {
	object, err := l.s.cfg.Store.Get(ctx, linkKey(channel, identity))
	if err != nil || object == nil {
		return nil, "", err
	}
	var r linkRecord
	if json.Unmarshal(object.Data, &r) != nil || r.Channel != channel || r.Identity != identity {
		return nil, "", nil
	}
	return &r, object.ETag, nil
}

// every is every link kept.
func (l *links) every(ctx context.Context) ([]linkRecord, error) {
	listed, err := l.s.cfg.Store.List(ctx, linksPrefix)
	if err != nil {
		return nil, err
	}
	out := []linkRecord{}
	for _, entry := range listed {
		object, err := l.s.cfg.Store.Get(ctx, entry.Key)
		if err != nil || object == nil {
			continue
		}
		var r linkRecord
		if json.Unmarshal(object.Data, &r) != nil || linkKey(r.Channel, r.Identity) != entry.Key {
			continue
		}
		out = append(out, r)
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].Channel != out[b].Channel {
			return out[a].Channel < out[b].Channel
		}
		return out[a].Identity < out[b].Identity
	})
	return out, nil
}

// open says a request still waits.
func (l *links) open(r linkRequestRecord) bool { return r.Result == "" && l.now().Before(r.Expires.Time) }

// mayDecide says a person may decide a request: the person named, or an admin when it
// names nobody.
func (l *links) mayDecide(r linkRequestRecord, user string) bool {
	if r.For != "" {
		return r.For == user
	}
	return l.s.isAdmin(user)
}

// row is a request as a client's card shows it.
func (l *links) row(r linkRequestRecord) wire.ChannelLinkRequest {
	row := wire.ChannelLinkRequest{Request: r.ID, Channel: r.Channel, Identity: r.Identity, Name: optional(r.Name),
		Email: optional(r.Email), For: optional(r.For), Expires: dateOf(r.Expires.Time)}
	if name := l.s.personName(r.For); name != "" {
		row.ForName = &name
	}
	return row
}

// deciders is who decides a request: the person named, or every admin.
func (l *links) deciders(r linkRequestRecord) []string {
	if r.For != "" {
		return []string{r.For}
	}
	out := []string{}
	for _, p := range l.s.records.People() {
		if p.IsAdmin() {
			out = append(out, p.ID)
		}
	}
	if l.s.records.Person(l.s.localOwner()) == nil {
		out = append(out, l.s.localOwner())
	}
	return out
}

// tellRequested shows a request's card to whoever decides it, at this copy.
func (l *links) tellRequested(r linkRequestRecord) {
	for _, user := range l.deciders(r) {
		l.s.router.TellPerson(user, "control/linkRequested", l.row(r))
	}
}

// tellDecided takes a request's card away from whoever was shown it, at this copy.
func (l *links) tellDecided(r linkRequestRecord, result string, deciders []string) {
	for _, user := range deciders {
		l.s.router.TellPerson(user, "control/linkDecided", wire.ChannelLinkDecided{Request: r.ID, Result: result})
	}
}

// requests is links/requests: the open requests the caller may decide.
func (l *links) requests(ctx context.Context, user string) ([]wire.ChannelLinkRequest, error) {
	all, err := l.all(ctx)
	if err != nil {
		return nil, fail(storeUnavailable, "The link requests could not be read: %v", err)
	}
	out := []wire.ChannelLinkRequest{}
	for _, r := range all {
		if l.open(r) && l.mayDecide(r, user) {
			out = append(out, l.row(r))
		}
	}
	return out, nil
}

// decide is links/approve and links/deny. An admin approving a request that names nobody
// names the person it goes to; the link is made only by that person's approval.
func (l *links) decide(ctx context.Context, request wire.ChannelLinkDecide, user string, approve bool) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	r, etag, err := l.readRequest(ctx, request.Request)
	if err != nil {
		return err
	}
	if r == nil || !l.mayDecide(*r, user) {
		return fail(invalidParams, "There is no such request to link.")
	}
	if !l.open(*r) {
		return fail(notPermitted, "That request has ended. A new message from the sender asks again.")
	}
	before := l.deciders(*r)
	if !approve {
		r.Result, r.By = "denied", user
		if err := l.writeRequest(ctx, *r, etag); err != nil {
			return err
		}
		l.tellDecided(*r, "denied", before)
		l.s.announce("linkDecided", r.ID, user)
		l.s.log("a " + r.Channel + " identity was not linked")
		return nil
	}
	if r.For == "" {
		to := deref(request.For)
		if to == "" {
			return fail(invalidParams, "Say which person this %s identity is.", r.Channel)
		}
		if !l.s.isPerson(to) {
			return fail(invalidParams, "There is no such person.")
		}
		r.For = to
		if to != user {
			// Sent on: the person approves it themselves.
			if err := l.writeRequest(ctx, *r, etag); err != nil {
				return err
			}
			l.tellDecided(*r, "sent", before)
			l.tellRequested(*r)
			l.s.announce("linkRequested", r.ID, user)
			l.s.log("a " + r.Channel + " link request was sent to " + to)
			return nil
		}
	}
	r.Result, r.By = "approved", user
	if err := l.writeRequest(ctx, *r, etag); err != nil {
		return err
	}
	link := linkRecord{Channel: r.Channel, Identity: r.Identity, Name: r.Name, User: r.For, ApprovedBy: user,
		ApprovedAt: records.At(l.now())}
	data, err := records.Encode(link)
	if err != nil {
		return err
	}
	if _, err := l.s.cfg.Store.Put(ctx, linkKey(link.Channel, link.Identity), data, store.Always); err != nil {
		return err
	}
	l.tellDecided(*r, "approved", before)
	l.changed(link.User)
	l.s.announce("linkDecided", r.ID, user)
	l.s.log("a " + r.Channel + " identity was linked to " + link.User)
	return nil
}

// list is links/list: the caller's own links, or an admin's, everyone's.
func (l *links) list(ctx context.Context, user string) ([]wire.ChannelLink, error) {
	every, err := l.every(ctx)
	if err != nil {
		return nil, fail(storeUnavailable, "The channel links could not be read: %v", err)
	}
	admin := l.s.isAdmin(user)
	out := []wire.ChannelLink{}
	for _, r := range every {
		if (r.User != user && !admin) || !l.s.isPerson(r.User) {
			continue
		}
		out = append(out, wire.ChannelLink{Channel: r.Channel, Identity: r.Identity, Name: optional(r.Name), User: r.User,
			UserName: optional(l.s.personName(r.User)), ApprovedBy: r.ApprovedBy, ApprovedAt: dateOf(r.ApprovedAt.Time)})
	}
	return out, nil
}

// remove is links/remove: a person unlinks their own, an admin anyone's.
func (l *links) remove(ctx context.Context, request wire.ChannelLinkRemove, user string) error {
	channel := strings.ToLower(strings.TrimSpace(request.Channel))
	identity := strings.TrimSpace(request.Identity)
	if channel == "email" {
		identity = strings.ToLower(identity)
	}
	r, _, err := l.read(ctx, channel, identity)
	if err != nil {
		return fail(storeUnavailable, "The channel links could not be read: %v", err)
	}
	if r == nil || (r.User != user && !l.s.isAdmin(user)) {
		return fail(invalidParams, "There is no such link.")
	}
	if err := l.s.cfg.Store.Delete(ctx, linkKey(channel, identity)); err != nil {
		return err
	}
	l.changed(r.User)
	l.s.log("a " + channel + " identity was unlinked from " + r.User)
	return nil
}

// dropFor removes a removed person's links, and ends the requests that name them.
func (l *links) dropFor(ctx context.Context, user string) {
	if every, err := l.every(ctx); err == nil {
		for _, r := range every {
			if r.User == user {
				l.s.cfg.Store.Delete(ctx, linkKey(r.Channel, r.Identity))
			}
		}
	}
	if all, err := l.all(ctx); err == nil {
		for _, r := range all {
			if r.For == user && l.open(r) {
				if _, etag, err := l.readRequest(ctx, r.ID); err == nil {
					r.Result, r.By = "denied", ""
					l.writeRequest(ctx, r, etag)
				}
			}
		}
	}
}

// changed tells the person and the admins, here and at every other copy, that links
// changed.
func (l *links) changed(user string) {
	l.tellChanged(user)
	l.s.announce("linksChanged", user, "")
}

func (l *links) tellChanged(user string) {
	told := map[string]bool{}
	for _, p := range append([]string{user}, l.deciders(linkRequestRecord{})...) {
		if !told[p] {
			told[p] = true
			l.s.router.TellPerson(p, "control/linksChanged", wire.Empty{})
		}
	}
}

// heardFromCopy is another copy's request made, sent on or decided: its cards here.
func (l *links) heardFromCopy(kind, id string) {
	l.readAgain()
	r, _, err := l.readRequest(context.Background(), id)
	if err != nil || r == nil {
		return
	}
	switch {
	case kind == "linkRequested" && l.open(*r):
		l.tellRequested(*r)
		if r.For != "" {
			// Sent on: the admins' cards go.
			admins := l.deciders(linkRequestRecord{})
			l.tellDecided(*r, "sent", admins)
		}
	case kind == "linkDecided":
		everyone := append(l.deciders(linkRequestRecord{}), r.For)
		l.tellDecided(*r, r.Result, everyone)
	}
}

// linksMethod answers links/list, links/requests, links/approve, links/deny and
// links/remove.
func (m *Methods) linksMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	user := m.callerPerson(from)
	switch method {
	case "links/list":
		return m.s.links.list(ctx, user)
	case "links/requests":
		return m.s.links.requests(ctx, user)
	case "links/approve", "links/deny":
		request, err := require[wire.ChannelLinkDecide](params, "ChannelLinkDecide")
		if err != nil {
			return nil, err
		}
		return wire.Empty{}, m.s.links.decide(ctx, request, user, method == "links/approve")
	case "links/remove":
		request, err := require[wire.ChannelLinkRemove](params, "ChannelLinkRemove")
		if err != nil {
			return nil, err
		}
		return wire.Empty{}, m.s.links.remove(ctx, request, user)
	}
	return nil, notFound(method)
}
