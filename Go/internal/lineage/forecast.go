package lineage

import (
	"hash/fnv"
	"math"
	"math/rand/v2"
	"slices"
	"time"
)

// The Timeline's forecast (#4172; M10 in specs/time-stream/wireframe.md, section 4, tested by
// backtest.py there):
//
//   - A working clock runs at the rate this project closes issues at each hour of the day, in
//     its time zone: fast in the evening, almost stopped at night. Every gap is measured on it.
//   - The pool is the gaps between child closes, on the clock, of the spans that ended in the
//     last ForecastWindow: a span is an epic's work from its first child's start to its last
//     child's close (section 7).
//   - Scope growth is the median of the same spans' children at the end over those known at
//     their first close. An open span gets known × (growth − 1) × (1 − done/known) more children:
//     all of the growth at the start, none at the end.
//   - ForecastDraws draws of one pool gap for each child left, added up, with a fixed seed: P10,
//     P50 and P90 of the sum, turned back into time of day, are the close and its band.
//   - The backtest stops the clock just after 25, 50, 75 and 90% of each past span's children
//     closed, forecasts its close from what was known then, and keeps the median error and the
//     width factor that makes the band hold 8 times in 10.

const (
	// ForecastWindow is how far back the clock, the pool and the backtest look.
	ForecastWindow = 30 * 24 * time.Hour
	// ForecastDraws is a forecast's simulation's draws.
	ForecastDraws = 1000
	// ForecastMinSpans is the fewest past spans a forecast is made from.
	ForecastMinSpans = 3
	// ForecastMinChildren is the fewest children a span the forecast learns from has.
	ForecastMinChildren = 4
	// ForecastHold is the share of the backtest's closes the widened band holds.
	ForecastHold = 0.8
	// forecastSeed fixes the simulation, so the same history gives the same forecast.
	forecastSeed = 4172
	// clockFloor is the slowest hour's rate, so the clock never stops.
	clockFloor = 0.05
	// errorFloor is the fewest hours an error is measured on, so a close a minute away does not
	// make an error of ×60.
	errorFloor = 0.05
)

// BacktestCuts are where the backtest stops the clock: after this share of a span's children closed.
var BacktestCuts = []float64{0.25, 0.5, 0.75, 0.9}

// Span is a stretch of an epic's work: from Start (its first child's start) to End (its last
// child's close; zero while it is open), with its children.
type Span struct {
	Start, End time.Time
	Children   []SpanChild
}

// SpanChild is a child of a span: when it was filed and when it closed (zero while open).
type SpanChild struct {
	Filed, Closed time.Time
}

// Clock is the working clock: a rate for each hour of the day in its time zone, with a mean of 1.
type Clock struct {
	rate [24]float64
	loc  *time.Location
}

// NewClock is the clock of closes in loc: an hour's rate is its share of the closes, × 24, at
// least clockFloor. With no closes every hour runs at 1.
func NewClock(closes []time.Time, loc *time.Location) Clock {
	c := Clock{loc: loc}
	var count [24]float64
	for _, t := range closes {
		count[t.In(loc).Hour()]++
	}
	total := 0.0
	for _, n := range count {
		total += n
	}
	for h := range c.rate {
		if total == 0 {
			c.rate[h] = 1
			continue
		}
		c.rate[h] = max(count[h]/total*24, clockFloor)
	}
	return c
}

// hours is t as hours since 1970, the unit the clock counts in.
func hours(t time.Time) float64 { return float64(t.UnixNano()) / float64(time.Hour) }

func wallOf(h float64) time.Time { return time.Unix(0, int64(h*float64(time.Hour))) }

// rateAt is the rate of the wall hour h is in.
func (c Clock) rateAt(h float64) float64 {
	return c.rate[time.Unix(int64(math.Floor(h))*3600, 0).In(c.loc).Hour()]
}

// between is the working hours from a to b, b after a.
func (c Clock) between(a, b float64) float64 {
	w := 0.0
	for t := a; t < b; {
		next := min(math.Floor(t)+1, b)
		w += (next - t) * c.rateAt(t)
		t = next
	}
	return w
}

// after is the wall hour w working hours after from.
func (c Clock) after(from, w float64) float64 {
	t, acc := from, 0.0
	for {
		r := c.rateAt(t)
		step := (math.Floor(t) + 1 - t) * r
		if acc+step >= w {
			return t + (w-acc)/r
		}
		acc += step
		t = math.Floor(t) + 1
	}
}

// Model is what a forecast is made from: the clock, the pool of gaps on it, and the scope growth.
type Model struct {
	Clock  Clock
	Pool   []float64
	Growth float64
	// Spans is how many past spans the pool and the growth are from.
	Spans int
}

// learnable is a span the forecast learns from: it has ended, with ForecastMinChildren
// children or more, all of them closed by its end.
func learnable(s Span) bool {
	if s.End.IsZero() || len(s.Children) < ForecastMinChildren {
		return false
	}
	for _, c := range s.Children {
		if c.Closed.IsZero() || c.Closed.After(s.End) {
			return false
		}
	}
	return true
}

// Learn is the model at at: the clock from the closes in the ForecastWindow before it, the pool
// and the growth from the learnable spans that ended in it. ok is false with fewer than
// ForecastMinSpans of them.
func Learn(spans []Span, closes []time.Time, at time.Time, loc *time.Location) (Model, bool) {
	since := at.Add(-ForecastWindow)
	var recent []time.Time
	for _, t := range closes {
		if t.Before(at) && !t.Before(since) {
			recent = append(recent, t)
		}
	}
	m := Model{Clock: NewClock(recent, loc)}
	var growth []float64
	for _, s := range spans {
		if !learnable(s) || !s.End.Before(at) || s.End.Before(since) {
			continue
		}
		ts := []float64{hours(s.Start)}
		for _, c := range s.Children {
			ts = append(ts, hours(c.Closed))
		}
		slices.Sort(ts)
		for i := 1; i < len(ts); i++ {
			m.Pool = append(m.Pool, m.Clock.between(ts[i-1], ts[i]))
		}
		growth = append(growth, growthOf(s))
		m.Spans++
	}
	if m.Spans < ForecastMinSpans {
		return m, false
	}
	m.Growth = median(growth)
	return m, true
}

// growthOf is a span's children at its end over those filed by its first close.
func growthOf(s Span) float64 {
	first := s.Children[0].Closed
	for _, c := range s.Children {
		if c.Closed.Before(first) {
			first = c.Closed
		}
	}
	known := 0
	for _, c := range s.Children {
		if !c.Filed.After(first) {
			known++
		}
	}
	return float64(len(s.Children)) / float64(max(1, known))
}

func median(v []float64) float64 {
	s := slices.Sorted(slices.Values(v))
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// Forecast is when an open span probably closes: P50, and P10 to P90 (Low to High). Children
// is each open child's time along the line: the P50 shared out.
type Forecast struct {
	Low, Mid, High time.Time
	Children       []time.Time
}

// toCome is the children left to forecast for a span with known children, done of them closed
// and open of them forecast: the open ones and the growth still to come.
func (m Model) toCome(known, done, open int) int {
	if known == 0 {
		return open
	}
	more := float64(known) * (m.Growth - 1) * (1 - float64(done)/float64(known))
	return max(open, int(math.RoundToEven(float64(open)+more)))
}

// draw is the sorted sums of ForecastDraws draws of n gaps each from the pool.
func (m Model) draw(n int, rng *rand.Rand) []float64 {
	sums := make([]float64, ForecastDraws)
	for i := range sums {
		for range n {
			sums[i] += m.Pool[rng.IntN(len(m.Pool))]
		}
	}
	slices.Sort(sums)
	return sums
}

// Rng is the simulation's source for key (an epic's ref), the same for the same key, so a
// forecast does not move when nothing changed.
func Rng(key string) *rand.Rand {
	h := fnv.New64a()
	_, _ = h.Write([]byte(key))
	return rand.New(rand.NewPCG(forecastSeed, h.Sum64()))
}

// Forecast is the close of a span at now with known children (not those that wait for a
// person), done of them closed and open of them to forecast. width widens the band around P50
// (1 is P10 to P90 as drawn). None with no open child or an empty pool.
func (m Model) Forecast(now time.Time, known, done, open int, width float64, rng *rand.Rand) (Forecast, bool) {
	if open < 1 || len(m.Pool) == 0 {
		return Forecast{}, false
	}
	n := m.toCome(known, done, open)
	sums := m.draw(n, rng)
	t := hours(now)
	at := func(w float64) float64 { return m.Clock.after(t, w) - t }
	mid := sums[ForecastDraws/2]
	// The width is learnt on wall hours (the backtest's), so the band is widened on them too.
	low, midWall, high := widen(at(sums[ForecastDraws/10]), at(mid), at(sums[ForecastDraws*9/10]), width)
	f := Forecast{Low: wallOf(t + low), Mid: wallOf(t + midWall), High: wallOf(t + high)}
	for i := range open {
		f.Children = append(f.Children, wallOf(m.Clock.after(t, mid*float64(i+1)/float64(n))))
	}
	return f, true
}

// widen is the band low to high around mid, each end's distance from mid in log terms × width.
func widen(low, mid, high, width float64) (float64, float64, float64) {
	if width == 1 || mid <= 0 {
		return low, mid, high
	}
	return mid * math.Pow(max(low, 1e-9)/mid, width), mid, mid * math.Pow(max(high, mid)/mid, width)
}

// Backtest is how well the forecast did on the past spans: the median error (forecast over
// actual, or actual over forecast), how often P10 to P90 held the close, and the Width that
// makes the band hold ForecastHold of them.
type Backtest struct {
	Error float64
	Cuts  int
	Holds int
	Width float64
	Spans int
}

// backtestCut is one cut's forecast and what happened, in wall hours after the cut.
type backtestCut struct{ low, mid, high, actual float64 }

// RunBacktest tests the forecast on the learnable spans that ended in the ForecastWindow before
// now: at each cut of BacktestCuts, a model learnt from what had ended before it. ok is false
// when no cut could be forecast.
func RunBacktest(spans []Span, closes []time.Time, now time.Time, loc *time.Location, cuts []float64) (Backtest, bool) {
	rng := rand.New(rand.NewPCG(forecastSeed, forecastSeed))
	var out []backtestCut
	tested := 0
	for _, s := range spans {
		if !learnable(s) || !s.End.Before(now) || s.End.Before(now.Add(-ForecastWindow)) {
			continue
		}
		xs := make([]time.Time, 0, len(s.Children))
		for _, c := range s.Children {
			xs = append(xs, c.Closed)
		}
		slices.SortFunc(xs, time.Time.Compare)
		forecast := false
		for _, q := range cuts {
			t := xs[max(0, int(float64(len(xs))*q)-1)]
			if hours(t) >= hours(s.End)-1e-6 {
				continue
			}
			known, open := 0, 0
			for _, c := range s.Children {
				if !c.Filed.After(t) {
					known++
					if c.Closed.After(t) {
						open++
					}
				}
			}
			if open == 0 {
				continue
			}
			m, ok := Learn(spans, closes, t, loc)
			if !ok {
				continue
			}
			sums := m.draw(m.toCome(known, known-open, open), rng)
			th := hours(t)
			at := func(w float64) float64 { return m.Clock.after(th, w) - th }
			out = append(out, backtestCut{low: at(sums[ForecastDraws/10]), mid: at(sums[ForecastDraws/2]),
				high: at(sums[ForecastDraws*9/10]), actual: hours(s.End) - th})
			forecast = true
		}
		if forecast {
			tested++
		}
	}
	if len(out) == 0 {
		return Backtest{}, false
	}
	b := Backtest{Cuts: len(out), Spans: tested}
	var errs []float64
	for _, c := range out {
		a, p := max(c.actual, errorFloor), max(c.mid, errorFloor)
		errs = append(errs, max(a/p, p/a))
		if c.low <= c.actual && c.actual <= c.high {
			b.Holds++
		}
	}
	b.Error = median(errs)
	b.Width = widthFor(out)
	return b, true
}

// widthFor is the smallest width, in steps of 0.05 from 0.25 to 20, whose band holds
// ForecastHold of the cuts' closes; 20 when none does.
func widthFor(cuts []backtestCut) float64 {
	for step := 5; step <= 400; step++ {
		w := float64(step) / 20
		held := 0
		for _, c := range cuts {
			low, _, high := widen(c.low, c.mid, c.high, w)
			if low <= c.actual && c.actual <= high {
				held++
			}
		}
		if float64(held) >= ForecastHold*float64(len(cuts)) {
			return w
		}
	}
	return 20
}
