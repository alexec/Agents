package noticebucket

import (
	"testing"
	"time"
)

// The bounds the person's settings take (#2859): out of them is the default or the most.
func TestLimitsKeepToTheirBounds(t *testing.T) {
	for _, c := range []struct {
		burst    int64
		minutes  float64
		want     int
		cooldown time.Duration
	}{
		{0, 0, DefaultBurst, DefaultCooldown},
		{5, 2, 5, 2 * time.Minute},
		{99, 99_999, MostBurst, MostCooldown},
		{-1, -3, DefaultBurst, DefaultCooldown},
	} {
		if b, cd := Limits(c.burst, c.minutes); b != c.want || cd != c.cooldown {
			t.Errorf("Limits(%d, %v) = %d, %v", c.burst, c.minutes, b, cd)
		}
	}
}

// A zero bucket is full, and one kept as JSON goes on where it stopped.
func TestABucketStartsFull(t *testing.T) {
	var b Bucket
	at := time.Unix(1_000_000, 0)
	if left, _, ok := b.Take(at, 2, time.Minute); !ok || left != 1 {
		t.Fatalf("%v %d", ok, left)
	}
	if left, _, ok := b.Take(at, 2, time.Minute); !ok || left != 0 {
		t.Fatalf("%v %d", ok, left)
	}
	if _, next, ok := b.Take(at.Add(30*time.Second), 2, time.Minute); ok || !next.Equal(at.Add(time.Minute)) {
		t.Fatalf("%v %v", ok, next)
	}
}
