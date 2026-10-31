package agentsd

import (
	"sync/atomic"
	"time"
)

// nowSlot holds the clock. A test replaces it. The atomic pointer keeps that
// replacement safe while a goroutine from an earlier test still reads the clock (#2510).
var nowSlot atomic.Pointer[func() time.Time]

func init() {
	f := time.Now
	nowSlot.Store(&f)
}

// nowFunc is the clock.
func nowFunc() time.Time {
	return (*nowSlot.Load())()
}

// setNowFunc replaces the clock and returns the previous one.
func setNowFunc(f func() time.Time) func() time.Time {
	prev := nowSlot.Swap(&f)
	if prev == nil {
		return time.Now
	}
	return *prev
}
