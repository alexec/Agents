package slackmcp

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

// The inbox: what Socket Mode pushed, kept in memory for events/poll. Slack sends an event
// once, to one open connection, and only while one is open; a poll reads it from here. It
// holds at most maxKept events, so a client that polls too seldom loses the oldest, and the
// poll says so. A cursor from another run of the server starts again from now.

// maxKept bounds the inbox.
const maxKept = 1000

// item is one event in the inbox.
type item struct {
	seq    uint64
	id     string // the eventId, which also keeps an event Slack sends twice once
	name   string
	at     time.Time
	data   map[string]any
	sender map[string]any
	// What the filters match.
	channel, user, thread, question string
	mentioned                       bool
}

// Inbox is the events since the server started, newest last.
type Inbox struct {
	mu    sync.Mutex
	boot  string
	next  uint64
	items []item
	seen  map[string]bool
}

// NewInbox is an empty inbox with a run of its own.
func NewInbox() *Inbox {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return &Inbox{boot: hex.EncodeToString(b), next: 1, seen: map[string]bool{}}
}

// add keeps it, unless an event with its id is already kept; false when it was.
func (b *Inbox) add(it item) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.seen[it.id] {
		return false
	}
	it.seq = b.next
	b.next++
	b.items = append(b.items, it)
	b.seen[it.id] = true
	if len(b.items) > maxKept {
		delete(b.seen, b.items[0].id)
		b.items = append([]item(nil), b.items[1:]...)
	}
	return true
}

// last is the newest event's seq, 0 for none.
func (b *Inbox) last() uint64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.next - 1
}

// since is up to limit events after seq that keep, and the seq read to; lost is true when
// events after seq were dropped before this read; more when there are others after.
func (b *Inbox) since(seq uint64, limit int, keep func(item) bool) (out []item, read uint64, lost, more bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	read = seq
	if len(b.items) > 0 && b.items[0].seq > seq+1 {
		lost = true
	}
	for _, it := range b.items {
		if it.seq <= seq {
			continue
		}
		if len(out) == limit {
			more = true
			break
		}
		read = it.seq
		if keep(it) {
			out = append(out, it)
		}
	}
	return out, read, lost, more
}
