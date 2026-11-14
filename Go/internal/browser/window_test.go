package browser

import (
	"context"
	"os"
	"testing"
	"time"

	cdpbrowser "github.com/chromedp/cdproto/browser"
	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/chromedp"
)

func TestBelowBoundsKeepsTheWindowsWidth(t *testing.T) {
	b := belowBounds(cdpbrowser.Bounds{Width: 500, Height: 600, WindowState: cdpbrowser.WindowStateNormal})
	if b == nil || *b.Left != -499 || *b.Top != belowScreen {
		t.Fatalf("%+v", b)
	}
	if b := belowBounds(cdpbrowser.Bounds{WindowState: cdpbrowser.WindowStateMaximized}); b == nil || *b.Left != -(windowWidth-1) {
		t.Fatalf("a window with no width goes as the first one: %+v", b)
	}
	if b := belowBounds(cdpbrowser.Bounds{Width: 800, WindowState: cdpbrowser.WindowStateMinimized}); b != nil {
		t.Fatalf("a minimized window is not on the screen: %+v", b)
	}
}

func TestSameBounds(t *testing.T) {
	l, top, other := int64(-1279), int64(1399), int64(30)
	a := cdpbrowser.Bounds{Left: &l, Top: &top, Width: 1280, Height: 800, WindowState: cdpbrowser.WindowStateNormal}
	if !sameBounds(a, a) {
		t.Fatal("a window is where it is")
	}
	moved := a
	moved.Top = &other
	resized := a
	resized.Height = 661
	for _, b := range []cdpbrowser.Bounds{moved, resized, {}} {
		if sameBounds(a, b) {
			t.Fatalf("%+v is not %+v", b, a)
		}
	}
}

// TestARealChromeKeepsItsWindowsBelow starts the Google Chrome in AGENTS_TEST_GOOGLE_CHROME
// with a window on this machine's screen (#5313): take the "browser" lease. A window it
// opens later comes up on the screen; the keeper moves it below the screen, faster than its
// look every keepEvery. While a hand-off shows the window, nothing moves; after it, every
// window goes back below.
func TestARealChromeKeepsItsWindowsBelow(t *testing.T) {
	exe := os.Getenv("AGENTS_TEST_GOOGLE_CHROME")
	if exe == "" {
		t.Skip("set AGENTS_TEST_GOOGLE_CHROME to Google Chrome to open real windows")
	}
	p, err := launchChromium(exe, t.TempDir(), os.Environ(), mode{chrome: true, headed: true})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		p.stop()
		<-p.done
	}()
	if !p.below {
		t.Fatal("Google Chrome with a window is not kept below the screen")
	}
	m := &Machine{running: p}
	go m.keepBelow(p)
	ctx := p.store.(cdpStore).ctx
	bounds := func(tab target.ID) cdpbrowser.Bounds {
		w, err := chromedp.CallBrowser(ctx, cdpbrowser.GetWindowForTarget, cdpbrowser.GetWindowForTargetParams{TargetID: tab})
		if err != nil {
			t.Fatal(err)
		}
		return *w.Bounds
	}
	ts, err := chromedp.Targets(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var first target.ID
	for _, ti := range ts {
		if ti.Type == "page" {
			first = ti.TargetID
			break
		}
	}
	if first == "" {
		t.Fatal("no page")
	}
	floor := *bounds(first).Top // as far down as macOS lets a window go
	below := func(b cdpbrowser.Bounds) bool { return *b.Left+b.Width <= 1 && *b.Top >= floor-50 }
	if b := bounds(first); !below(b) {
		t.Fatalf("the first window is on the screen: (%d, %d)", *b.Left, *b.Top)
	}
	open := func() target.ID {
		yes := true
		made, err := chromedp.CallBrowser(ctx, target.CreateTarget, target.CreateTargetParams{URL: "about:blank", NewWindow: &yes})
		if err != nil {
			t.Fatal(err)
		}
		return made.TargetID
	}
	waitBelow := func(tab target.ID, within time.Duration) {
		t.Helper()
		end := time.Now().Add(within)
		for {
			b := bounds(tab)
			if below(b) {
				return
			}
			if time.Now().After(end) {
				t.Fatalf("still on the screen after %s: (%d, %d) %d×%d", within, *b.Left, *b.Top, b.Width, b.Height)
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	time.Sleep(keepEvery / 2) // away from the keeper's own look
	opened := time.Now()
	second := open()
	waitBelow(second, keepEvery-500*time.Millisecond)
	b := bounds(second)
	t.Logf("a new window went below the screen in %s: (%d, %d)", time.Since(opened).Round(10*time.Millisecond), *b.Left, *b.Top)

	// Playwright's headed viewport sets only a width and a height.
	w, _ := chromedp.CallBrowser(ctx, cdpbrowser.GetWindowForTarget, cdpbrowser.GetWindowForTargetParams{TargetID: second})
	if _, err := chromedp.CallBrowser(ctx, cdpbrowser.SetWindowBounds, cdpbrowser.SetWindowBoundsParams{WindowID: w.WindowID, Bounds: &cdpbrowser.Bounds{Width: 1280, Height: 661}}); err != nil {
		t.Fatal(err)
	}
	waitBelow(second, 2*keepEvery)

	// A hand-off: the window is the person's, and a pop-up they open stays with it.
	if _, err := m.ShowWindow(context.Background(), string(first)); err != nil {
		t.Fatal(err)
	}
	popup := open()
	time.Sleep(2*keepEvery + 500*time.Millisecond)
	for _, tab := range []target.ID{first, popup} {
		if b := bounds(tab); below(b) {
			t.Fatalf("the keeper moved a window during the hand-off: (%d, %d)", *b.Left, *b.Top)
		}
	}
	if err := m.HideWindow(context.Background(), string(first)); err != nil {
		t.Fatal(err)
	}
	waitBelow(first, keepEvery)
	waitBelow(popup, 2*keepEvery)
}
