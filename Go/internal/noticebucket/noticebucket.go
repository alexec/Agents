// Package noticebucket is the person's attention (#2805, #2859): a short burst of notices,
// then one back each cool-down, and nothing queued. A host keeps one when it has no
// control plane; the control plane keeps one per person, for every machine of theirs.
package noticebucket

import (
	"math"
	"time"
)

// The defaults Alex chose (#2805), and the bounds the settings take.
const (
	DefaultBurst    = 3
	DefaultCooldown = 10 * time.Minute
	MostBurst       = 20
	MostCooldown    = 24 * time.Hour
)

// Bucket is how many notices are left, as of when. A zero Bucket is full.
type Bucket struct {
	Tokens float64   `json:"tokens"`
	At     time.Time `json:"at"`
}

// Limits is a burst and a cool-down as the person set them, within the bounds: a burst
// under 1 or a cool-down of no time is the default.
func Limits(burst int64, cooldownMinutes float64) (int, time.Duration) {
	b, c := DefaultBurst, DefaultCooldown
	if burst >= 1 {
		b = int(min(burst, MostBurst))
	}
	if cooldownMinutes > 0 {
		c = min(time.Duration(cooldownMinutes*float64(time.Minute)), MostCooldown)
	}
	return b, c
}

// Take takes one notice, if one is left: what is left after it, or when the next comes
// back. Notices come back one at a time, each cool-down, so agents that met the limit
// together do not all go again at once.
func (b *Bucket) Take(at time.Time, burst int, cooldown time.Duration) (left int, next time.Time, ok bool) {
	if b.At.IsZero() {
		b.Tokens, b.At = float64(burst), at
	}
	if elapsed := at.Sub(b.At); elapsed > 0 {
		b.Tokens += float64(elapsed) / float64(cooldown)
	}
	b.Tokens = math.Min(b.Tokens, float64(burst))
	b.At = at
	if b.Tokens < 1 {
		return 0, at.Add(time.Duration((1 - b.Tokens) * float64(cooldown))), false
	}
	b.Tokens--
	return int(b.Tokens), at.Add(time.Duration((1 - (b.Tokens - math.Floor(b.Tokens))) * float64(cooldown))), true
}
