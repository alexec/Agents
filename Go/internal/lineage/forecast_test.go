package lineage

import (
	"encoding/json"
	"math"
	"os"
	"testing"
	"time"
)

var pacific = time.FixedZone("UTC-8", -8*3600)

func at(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

// #4172: an hour's rate is its share of the closes × 24, so a day on the clock is 24 working
// hours; after turns working hours back into wall time.
func TestClockRunsAtTheRateOfTheCloses(t *testing.T) {
	// Three closes at 18:00 Pacific and one at 09:00.
	closes := []time.Time{at("2026-11-01T02:10:00Z"), at("2026-11-02T02:20:00Z"), at("2026-11-03T02:30:00Z"), at("2026-11-02T17:00:00Z")}
	c := NewClock(closes, pacific)
	if c.rate[18] != 18 || c.rate[9] != 6 || c.rate[2] != clockFloor {
		t.Fatalf("rates 18:00 %v, 09:00 %v, 02:00 %v; want 18, 6 and %v", c.rate[18], c.rate[9], c.rate[2], clockFloor)
	}
	from := hours(at("2026-11-05T00:00:00Z"))
	day := c.between(from, from+24)
	if want := 24 + 22*clockFloor; math.Abs(day-want) > 1e-9 {
		t.Fatalf("a day is %v working hours, want %v", day, want)
	}
	// 18:00 to 18:30 Pacific is 9 working hours.
	six := hours(at("2026-11-05T02:00:00Z"))
	if w := c.between(six, six+0.5); math.Abs(w-9) > 1e-9 {
		t.Fatalf("half an hour at 18:00 is %v working hours, want 9", w)
	}
	for _, w := range []float64{0.5, 9, 17.5, 30, 100} {
		if back := c.between(from, c.after(from, w)); math.Abs(back-w) > 1e-6 {
			t.Fatalf("after(%v) then between is %v", w, back)
		}
	}
	if flat := NewClock(nil, pacific); flat.between(from, from+5) != 5 {
		t.Fatal("with no closes the clock runs at 1")
	}
}

// span is a closed span that started at start, with a child closed each gap hours.
func span(start time.Time, n int, gap time.Duration) Span {
	s := Span{Start: start}
	for i := range n {
		s.Children = append(s.Children, SpanChild{Filed: start, Closed: start.Add(time.Duration(i+1) * gap)})
	}
	s.End = s.Children[n-1].Closed
	return s
}

// #4172: the same history gives the same forecast; the growth still to come shrinks as the epic
// is done; a forecast needs ForecastMinSpans past spans.
func TestForecastIsTheSameForTheSameHistory(t *testing.T) {
	now := at("2026-11-08T12:00:00Z")
	var spans []Span
	var closes []time.Time
	for i := range 6 {
		s := span(now.Add(-time.Duration(48*(i+1))*time.Hour), 4+i, time.Duration(1+i)*time.Hour)
		spans = append(spans, s)
		for _, c := range s.Children {
			closes = append(closes, c.Closed)
		}
	}
	if _, ok := Learn(spans[:2], closes, now, pacific); ok {
		t.Fatal("a model from 2 spans")
	}
	m, ok := Learn(spans, closes, now, pacific)
	if !ok || m.Spans != 6 || len(m.Pool) != 4+5+6+7+8+9 {
		t.Fatalf("model: %v spans, %d gaps", m.Spans, len(m.Pool))
	}
	a, ok := m.Forecast(now, 8, 3, 5, 1, Rng("github:o/r#1"))
	b, _ := m.Forecast(now, 8, 3, 5, 1, Rng("github:o/r#1"))
	if !ok || !a.Mid.Equal(b.Mid) || !a.Low.Equal(b.Low) || !a.High.Equal(b.High) {
		t.Fatalf("two forecasts of the same: %v and %v", a, b)
	}
	if !(now.Before(a.Low) && !a.Mid.Before(a.Low) && !a.High.Before(a.Mid)) || len(a.Children) != 5 || a.Children[4].After(a.Mid) {
		t.Fatalf("forecast out of order: %+v", a)
	}
	wide, _ := m.Forecast(now, 8, 3, 5, 2, Rng("github:o/r#1"))
	if !wide.Mid.Equal(a.Mid) || !wide.Low.Before(a.Low) || !wide.High.After(a.High) {
		t.Fatalf("a width of 2 does not widen the band: %+v", wide)
	}
	if _, ok := m.Forecast(now, 4, 4, 0, 1, Rng("x")); ok {
		t.Fatal("a forecast with no open child")
	}
	m.Growth = 1.2
	if n := m.toCome(10, 0, 10); n != 12 {
		t.Fatalf("all of the growth at the start: %d, want 12", n)
	}
	if n := m.toCome(10, 9, 1); n != 1 {
		t.Fatalf("none of the growth at the end: %d, want 1", n)
	}
}

// #4172: the widened band holds ForecastHold of the closes.
func TestWidthMakesTheBandHold(t *testing.T) {
	var cuts []backtestCut
	for i := range 10 {
		cuts = append(cuts, backtestCut{low: 2, mid: 4, high: 8, actual: float64(1 + i*2)})
	}
	w := widthFor(cuts)
	held := 0
	for _, c := range cuts {
		if lo, _, hi := widen(c.low, c.mid, c.high, w); lo <= c.actual && c.actual <= hi {
			held++
		}
	}
	if held < 8 {
		t.Fatalf("width %v holds %d of 10", w, held)
	}
	// The close at 1 h is the eighth the band must hold.
	if lo, _, _ := widen(2, 4, 8, w-0.05); lo <= 1 {
		t.Fatalf("width %v is not the smallest", w)
	}
}

// #4172: the Go backtest gives the error backtest.py gives on the same data, ±0.1. The fixture
// is this repo's epics read on 2026-11-08 with backtest.py's query; `python3 backtest.py --late`
// on it says M10 is off by ×2.19 at 65 cuts. backtest.py measures from filed to closed and
// draws with Python's random, so the spans here are the same and the draws are not.
func TestBacktestMatchesBacktestPy(t *testing.T) {
	b, err := os.ReadFile("testdata/time-stream-epics.json")
	if err != nil {
		t.Fatal(err)
	}
	var epics []struct {
		Created    string  `json:"created"`
		Closed     *string `json:"closed"`
		NotPlanned bool    `json:"notPlanned"`
		Children   []struct {
			Created string  `json:"created"`
			Closed  *string `json:"closed"`
		} `json:"children"`
	}
	if err := json.Unmarshal(b, &epics); err != nil {
		t.Fatal(err)
	}
	var spans []Span
	var closes []time.Time
	var last time.Time
	for _, e := range epics {
		s := Span{Start: at(e.Created)}
		if e.Closed != nil && !e.NotPlanned {
			s.End = at(*e.Closed)
		}
		for _, c := range e.Children {
			child := SpanChild{Filed: at(c.Created)}
			if c.Closed != nil {
				child.Closed = at(*c.Closed)
				closes = append(closes, child.Closed)
				last = maxTime(last, child.Closed)
			}
			s.Children = append(s.Children, child)
		}
		if !s.End.IsZero() {
			last = maxTime(last, s.End)
		}
		spans = append(spans, s)
	}
	bt, ok := RunBacktest(spans, closes, last.Add(time.Hour), pacific, BacktestCuts)
	if !ok {
		t.Fatal("no backtest")
	}
	if bt.Cuts != 65 {
		t.Fatalf("%d cuts, backtest.py has 65", bt.Cuts)
	}
	if math.Abs(bt.Error-2.19) > 0.1 {
		t.Fatalf("median error ×%.2f, backtest.py says ×2.19", bt.Error)
	}
	if float64(bt.Holds) >= ForecastHold*float64(bt.Cuts) || bt.Width <= 1 {
		t.Fatalf("P10 to P90 holds %d of %d with width %v: backtest.py's holds 44 of 65, so it needs widening", bt.Holds, bt.Cuts, bt.Width)
	}
	again, _ := RunBacktest(spans, closes, last.Add(time.Hour), pacific, BacktestCuts)
	if again != bt {
		t.Fatalf("two backtests of the same: %+v and %+v", bt, again)
	}
	t.Logf("error ×%.2f, %d cuts of %d spans, P10-P90 holds %d, width %.2f", bt.Error, bt.Cuts, bt.Spans, bt.Holds, bt.Width)
}

func maxTime(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}
