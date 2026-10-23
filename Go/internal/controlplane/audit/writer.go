package audit

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// A Writer keeps a copy's entries (#2433): each is queued, not a goroutine of its own, and
// one goroutine takes them in batches. A batch is linked into the chain in order, under its
// lock, and then put all at once, each Put with a deadline. One Put at a time, as Log.Write
// does, kept 10 to 30 entries a second on a bucket while a SCIM sync makes up to 150.
const (
	// WriterQueue bounds the entries waiting. A full queue loses the entry, and says so.
	WriterQueue = 10_000
	// writerBatch is the most entries one batch takes, and writerPuts the Puts at once.
	writerBatch = 256
	writerPuts  = 32
	// PutPatience is each Put's deadline. putWait is the longest pause before the
	// next try. The pause starts at 200ms.
	PutPatience = 10 * time.Second
	putWait     = 2 * time.Second
)

// Pending is an entry to keep. Who did it and what it named are read on the writer, not
// by the caller, which may hold the router's lock (#2058).
type Pending struct {
	Method, Action, Host string
	At                   time.Time
	Who                  func() (wire.AuditActor, *string)
}

// Writer is a copy's one writer of entries.
type Writer struct {
	log   *Log
	logf  func(string)
	queue chan Pending
	stop  chan struct{}
	done  chan struct{}
	// giveUp is closed when Close's context ends, so a Put still refused is given up.
	giveUp     chan struct{}
	once       sync.Once
	giveUpOnce sync.Once
}

// NewWriter starts the writer of l's entries; logf hears what it could not keep.
func NewWriter(l *Log, logf func(string)) *Writer {
	w := &Writer{
		log: l, logf: logf, queue: make(chan Pending, WriterQueue),
		stop: make(chan struct{}), done: make(chan struct{}), giveUp: make(chan struct{}),
	}
	go w.run()
	return w
}

// Add queues an entry, and never waits. False when the queue is full or the writer has
// stopped: the entry is lost, and the log says so.
func (w *Writer) Add(p Pending) bool {
	if p.At.IsZero() {
		p.At = w.log.now()
	}
	select {
	case <-w.stop:
	default:
		select {
		case w.queue <- p:
			return true
		default:
		}
	}
	w.logf("audit: could not keep " + p.Method + ": the writer's queue is full or stopped")
	return false
}

// Close keeps what is queued, until ctx ends, and stops the writer.
func (w *Writer) Close(ctx context.Context) {
	w.once.Do(func() { close(w.stop) })
	select {
	case <-w.done:
	case <-ctx.Done():
		w.giveUpOnce.Do(func() { close(w.giveUp) })
	}
}

func (w *Writer) run() {
	defer close(w.done)
	for {
		select {
		case p := <-w.queue:
			w.keep(w.take(p))
		case <-w.stop:
			for {
				select {
				case p := <-w.queue:
					w.keep(w.take(p))
				default:
					return
				}
			}
		}
	}
}

// take is a batch: p and what else waits, at most writerBatch.
func (w *Writer) take(p Pending) []Pending {
	batch := []Pending{p}
	for len(batch) < writerBatch {
		select {
		case next := <-w.queue:
			batch = append(batch, next)
		default:
			return batch
		}
	}
	return batch
}

// keep links a batch in order and puts it at once. A Put the store refuses is tried
// again until it is kept. It is given up only when Close's context ends, and then
// the log says which entry left a gap.
func (w *Writer) keep(batch []Pending) {
	l := w.log
	linked := make([]Linked, 0, len(batch))
	for _, p := range batch {
		actor, target := p.Who()
		e, key := entry(actor, p.Method, p.Action, p.Host, target, p.At)
		var one Linked
		var err error
		if l.Chain != nil {
			one, err = l.Chain.link(&e, key, p.At)
		} else {
			one.Key, one.At = key, p.At
			one.Data, err = records.Encode(e)
		}
		if err != nil {
			w.logf("audit: could not keep " + p.Method + ": " + err.Error())
			continue
		}
		linked = append(linked, one)
	}
	kept := make([]bool, len(linked))
	var wg sync.WaitGroup
	gate := make(chan struct{}, writerPuts)
	for i, one := range linked {
		gate <- struct{}{}
		wg.Go(func() {
			defer func() { <-gate }()
			kept[i] = w.put(one)
		})
	}
	wg.Wait()
	for i, one := range linked {
		if !kept[i] {
			if l.Chain != nil {
				w.logf(fmt.Sprintf("audit: entry %d of chain %s (%s) was not kept: the chain has a gap there", one.Seq, l.Chain.ID, one.Key))
			} else {
				w.logf("audit: " + one.Key + " was not kept")
			}
			continue
		}
		if l.Out != nil {
			l.Out(one.Key, one.Data)
		}
	}
	if l.Chain != nil && len(linked) > 0 {
		ctx, cancel := context.WithTimeout(context.Background(), PutPatience)
		for _, one := range linked {
			l.Chain.landed(ctx, l.Store, one)
		}
		cancel()
	}
}

// put keeps one entry. It tries again until the store takes it. A later try that
// answers "already there" landed on an earlier try whose answer was lost. The wait
// starts at 200ms and grows to putWait. The entry is given up only when Close's
// context has ended.
func (w *Writer) put(one Linked) bool {
	for try := 0; ; try++ {
		ctx, cancel := context.WithTimeout(context.Background(), PutPatience)
		_, err := w.log.Store.Put(ctx, one.Key, one.Data, store.Absent)
		cancel()
		if err == nil || try > 0 && store.IsConflict(err) {
			return true
		}
		if try == 0 {
			w.sayRefused(one)
		}
		select {
		case <-w.giveUp:
			return false
		default:
		}
		wait := time.Duration(try+1) * 200 * time.Millisecond
		if wait <= 0 || wait > putWait {
			wait = putWait
		}
		timer := time.NewTimer(wait)
		select {
		case <-timer.C:
		case <-w.giveUp:
			timer.Stop()
			return false
		}
	}
}

// sayRefused logs the first time the store refuses one entry.
func (w *Writer) sayRefused(one Linked) {
	if w.log.Chain != nil {
		w.logf(fmt.Sprintf("audit: entry %d of chain %s (%s) was refused; trying again", one.Seq, w.log.Chain.ID, one.Key))
		return
	}
	w.logf("audit: " + one.Key + " was refused; trying again")
}
