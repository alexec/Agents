package browser

import (
	"context"
	"errors"

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
	return p.pid, nil
}

// HideWindow puts tab's window back just below the screen, where the browser keeps it.
func (m *Machine) HideWindow(ctx context.Context, tab string) error {
	p, err := m.realWindow()
	if err != nil {
		return err
	}
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
