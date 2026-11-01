package hosted

import (
	"context"
	"sync"
	"time"
)

// The disk as a whole (#3121): every account's store, and the service's own records, are
// on one disk. Two checks keep it from filling:
//
//   - a new account, and an upgrade, are refused when the plans' storage would add up to
//     more than the disk can hold (Config.StorageTotal, or the disk's size to its
//     high-water mark), so each plan's promise can be kept;
//   - an account's write that grows its store is refused once the disk is past its
//     high-water mark, so the service's own records (sign-ups, plans, Stripe events) still
//     have room. The metrics say how full the disk is.

// Space is a disk's size and what is free on it, in bytes.
type Space struct{ Total, Free int64 }

// diskHighWater is how full the disk may get, in hundredths, before accounts' writes are
// refused.
const diskHighWater = 90

// diskReadEvery is how long a reading of the disk is used before it is read again, so a
// write does not read the disk each time.
const diskReadEvery = 5 * time.Second

// disk reads the disk the store is on, at most once each diskReadEvery.
type disk struct {
	read func() (Space, error)
	now  func() time.Time

	mu   sync.Mutex
	last Space
	ok   bool
	at   time.Time
}

// space is the disk's last reading, read again when old. ok is false when there is no
// disk to read, or it could not be read.
func (d *disk) space() (Space, bool) {
	if d == nil || d.read == nil {
		return Space{}, false
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if now := d.now(); d.at.IsZero() || now.Sub(d.at) >= diskReadEvery {
		sp, err := d.read()
		d.last, d.ok, d.at = sp, err == nil && sp.Total > 0, now
	}
	return d.last, d.ok
}

// full says whether the disk is past its high-water mark. A disk that cannot be read is
// not full: the plan's own limit still holds.
func (d *disk) full() bool {
	sp, ok := d.space()
	return ok && (sp.Total-sp.Free)*100 >= sp.Total*diskHighWater
}

// storageTotal is the most the plans' storage may add up to: Config.StorageTotal, or the
// disk's size to its high-water mark. ok is false when neither is known.
func (s *Service) storageTotal() (int64, bool) {
	if s.cfg.StorageTotal > 0 {
		return s.cfg.StorageTotal, true
	}
	sp, ok := s.disk.space()
	if !ok {
		return 0, false
	}
	return sp.Total / 100 * diskHighWater, true
}

// roomFor says whether the plans' storage, every account's, has room for more bytes:
// a new account's plan, or what an upgrade adds.
func (s *Service) roomFor(ctx context.Context, more int64) (bool, error) {
	most, ok := s.storageTotal()
	if !ok {
		return true, nil
	}
	list, err := s.accounts.all(ctx)
	if err != nil {
		return false, err
	}
	sum := more
	for i := range list {
		sum += PlanOf(&list[i]).Storage
	}
	return sum <= most, nil
}
