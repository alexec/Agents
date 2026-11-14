package browser

import (
	"context"
	"errors"
	"log"
	"time"

	cdpbrowser "github.com/chromedp/cdproto/browser"
	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/chromedp"
)

// The hand-off in the real window (#5208): when the browser is Google Chrome (#5207), its
// window is real, just below the screen. hand_to_person moves the window with the agent's
// tab onto the screen, so the person does the step there (a press-and-hold check, a Touch
// ID or iCloud Keychain passkey prompt, a CAPTCHA), and puts it back below the screen when
// the person is done. The screencast cannot carry those steps.

// ErrNoWindow is ShowWindow's refusal when the browser has no real window to show: it is
// not running, or it is Chrome for Testing, whose window (when it has one) is off every
// screen and has no place there.
var ErrNoWindow = errors.New("the browser has no window to show: it is not Google Chrome")

// onScreen is where the window goes for the person, left and top: on the main display,
// clear of the menu bar. macOS keeps it on a smaller screen.
const onScreen = 100

// ShowWindow brings tab's window onto the screen and tab to the front of it, and says
// Google Chrome's pid, for the app to come to the front. tab "" is the window of the
// browser's first tab.
func (m *Machine) ShowWindow(ctx context.Context, tab string) (int, error) {
	p, err := m.realWindow()
	if err != nil {
		return 0, err
	}
	c, done := cdpStore{p.ctxOf()}.bound(ctx)
	defer done()
	if tab != "" {
		if _, err := chromedp.CallBrowser(c, target.ActivateTarget, target.ActivateTargetParams{TargetID: target.ID(tab)}); err != nil {
			return 0, err
		}
	}
	at := int64(onScreen)
	if err := setWindow(c, tab, &cdpbrowser.Bounds{Left: &at, Top: &at, WindowState: cdpbrowser.WindowStateNormal}); err != nil {
		return 0, err
	}
	// The keeper leaves every window where it is until HideWindow (#5313): the person may
	// open a pop-up for the step, such as a sign-in with another site.
	m.mu.Lock()
	p.shown++
	m.mu.Unlock()
	return p.pid, nil
}

// HideWindow puts tab's window back just below the screen, where the browser keeps it.
func (m *Machine) HideWindow(ctx context.Context, tab string) error {
	p, err := m.realWindow()
	if err != nil {
		return err
	}
	m.mu.Lock()
	if p.shown > 0 {
		p.shown--
	}
	m.mu.Unlock()
	c, done := cdpStore{p.ctxOf()}.bound(ctx)
	defer done()
	left, top := int64(-(windowWidth - 1)), int64(belowScreen)
	return setWindow(c, tab, &cdpbrowser.Bounds{Left: &left, Top: &top})
}

// realWindow is the running Google Chrome, or ErrNoWindow.
func (m *Machine) realWindow() (*process, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p := m.running
	if p == nil || !p.chrome || p.ctxOf() == nil {
		return nil, ErrNoWindow
	}
	select {
	case <-p.done:
		return nil, ErrNoWindow
	default:
	}
	return p, nil
}

// ctxOf is the chromedp context that started p, which reaches the browser itself.
func (p *process) ctxOf() context.Context {
	if s, ok := p.store.(cdpStore); ok {
		return s.ctx
	}
	return nil
}

// setWindow sets the bounds of tab's window, or of the first tab's when tab is "".
func setWindow(ctx context.Context, tab string, bounds *cdpbrowser.Bounds) error {
	var w cdpbrowser.GetWindowForTargetResult
	var err error
	if tab == "" {
		w, err = chromedp.Call(ctx, cdpbrowser.GetWindowForTarget, cdpbrowser.GetWindowForTargetParams{})
	} else {
		w, err = chromedp.CallBrowser(ctx, cdpbrowser.GetWindowForTarget, cdpbrowser.GetWindowForTargetParams{TargetID: target.ID(tab)})
	}
	if err != nil {
		return err
	}
	_, err = chromedp.CallBrowser(ctx, cdpbrowser.SetWindowBounds, cdpbrowser.SetWindowBoundsParams{WindowID: w.WindowID, Bounds: bounds})
	return err
}

// The keeper (#5313): Google Chrome opens every window after its first one on the screen,
// at (0, 30) on this Mac: a tab an agent opens in a new window, a page's pop-up, a window
// for a tab when the last window closed. The start moves only the first window below the
// screen (moveBelowScreen), so those stayed in sight, and macOS called their pages hidden
// when other windows covered them. The keeper moves each window that is not where it put
// it back below the screen: at once when a page opens, and every keepEvery for a window
// that moved some other way. While a hand-off has the window on the screen (ShowWindow),
// it moves nothing.

// keepEvery is how often the keeper looks at every window.
const keepEvery = 2 * time.Second

// keepBelow keeps p's windows below the screen until p ends. Started once per Google
// Chrome whose window is below the screen (not on an Xvfb screen, where nobody sees it).
func (m *Machine) keepBelow(p *process) {
	ctx := p.ctxOf()
	if ctx == nil {
		return
	}
	opened := make(chan struct{}, 1)
	chromedp.ListenBrowser(ctx, func(ev any) {
		if e, ok := ev.(*target.EventTargetCreated); ok && e.TargetInfo != nil && e.TargetInfo.Type == "page" {
			select {
			case opened <- struct{}{}:
			default:
			}
		}
	})
	// Discovery is what sends targetCreated on this connection; tabs.go and the screencast
	// turn it on for their own.
	if _, err := chromedp.CallBrowser(ctx, target.SetDiscoverTargets, target.SetDiscoverTargetsParams{Discover: true}); err != nil {
		log.Printf("browser: the window keeper hears no new pages, so it looks every %s only: %v", keepEvery, err)
	}
	placed := map[cdpbrowser.WindowID]cdpbrowser.Bounds{}
	tick := time.NewTicker(keepEvery)
	defer tick.Stop()
	for {
		select {
		case <-p.done:
			return
		case <-tick.C:
		case <-opened:
		}
		m.mu.Lock()
		shown := p.shown > 0
		m.mu.Unlock()
		if shown {
			// The person's window: HideWindow puts it back, and the next look the rest.
			clear(placed)
			continue
		}
		c, cancel := context.WithTimeout(ctx, keepEvery)
		keepWindowsBelow(c, placed)
		cancel()
	}
}

// keepWindowsBelow moves every window of a page that is not as it was left (placed, by
// window) below the screen, and writes down where each one is then. A window macOS keeps
// partly on the screen is moved once, not on every look.
func keepWindowsBelow(ctx context.Context, placed map[cdpbrowser.WindowID]cdpbrowser.Bounds) {
	targets, err := chromedp.CallBrowser(ctx, target.GetTargets, target.GetTargetsParams{})
	if err != nil {
		return
	}
	seen := map[cdpbrowser.WindowID]bool{}
	for _, t := range targets.TargetInfos {
		if t.Type != "page" {
			continue
		}
		w, err := chromedp.CallBrowser(ctx, cdpbrowser.GetWindowForTarget, cdpbrowser.GetWindowForTargetParams{TargetID: t.TargetID})
		if err != nil || w.Bounds == nil || seen[w.WindowID] {
			continue
		}
		seen[w.WindowID] = true
		if was, ok := placed[w.WindowID]; ok && sameBounds(was, *w.Bounds) {
			continue
		}
		if moves := belowBounds(*w.Bounds); moves != nil {
			if w.Bounds.WindowState != cdpbrowser.WindowStateNormal {
				// Chrome moves only a normal window: a maximized or full-screen one is made
				// normal first.
				normal := &cdpbrowser.Bounds{WindowState: cdpbrowser.WindowStateNormal}
				if _, err := chromedp.CallBrowser(ctx, cdpbrowser.SetWindowBounds, cdpbrowser.SetWindowBoundsParams{WindowID: w.WindowID, Bounds: normal}); err != nil {
					log.Printf("browser: couldn't make window %d normal to move it below the screen: %v", w.WindowID, err)
					continue
				}
			}
			if _, err := chromedp.CallBrowser(ctx, cdpbrowser.SetWindowBounds, cdpbrowser.SetWindowBoundsParams{WindowID: w.WindowID, Bounds: moves}); err != nil {
				log.Printf("browser: couldn't move window %d below the screen: %v", w.WindowID, err)
				continue
			}
			if now, err := chromedp.CallBrowser(ctx, cdpbrowser.GetWindowForTarget, cdpbrowser.GetWindowForTargetParams{TargetID: t.TargetID}); err == nil && now.Bounds != nil {
				w.Bounds = now.Bounds
			}
		}
		placed[w.WindowID] = *w.Bounds
	}
	for id := range placed {
		if !seen[id] {
			delete(placed, id)
		}
	}
}

// belowBounds is where a window at b goes to be below the screen, as moveBelowScreen puts
// the first one: all but one point to the left of the screen and as far down as macOS
// lets it, at its own width. It is nil for a minimized window, which is not on the screen.
func belowBounds(b cdpbrowser.Bounds) *cdpbrowser.Bounds {
	if b.WindowState == cdpbrowser.WindowStateMinimized {
		return nil
	}
	width := b.Width
	if width <= 0 {
		width = windowWidth
	}
	left, top := -(width - 1), int64(belowScreen)
	return &cdpbrowser.Bounds{Left: &left, Top: &top}
}

// sameBounds is whether a and b are one place, size and state.
func sameBounds(a, b cdpbrowser.Bounds) bool {
	at := func(v *int64) int64 {
		if v == nil {
			return 0
		}
		return *v
	}
	return at(a.Left) == at(b.Left) && at(a.Top) == at(b.Top) && a.Width == b.Width && a.Height == b.Height && a.WindowState == b.WindowState
}
