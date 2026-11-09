package browser

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/chromedp/cdproto/emulation"
	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/chromedp"
)

// A device profile for a session's tabs (#4086): the size, scale, touch and user agent of a
// phone or a tablet, set over CDP as a browser's developer tools do. @playwright/mcp's own
// --device does not work with --cdp-endpoint ("Device emulation is not supported with
// cdpEndpoint"), so Tabs sets it. Chromium drops a CDP session's overrides when the session
// detaches, so Tabs keeps one session on each tab it emulates, for as long as the profile
// holds. It is device emulation, not a way past bot checks: the user agent is the browser's
// own Chrome on Android, and the client hints agree with it.

// Device is one profile. The values are Playwright's (its device list in playwright-core,
// 1.64), from a Chromium device, so that the user agent and Sec-CH-UA can agree.
type Device struct {
	Name          string
	Width, Height int64
	Scale         float64
	Mobile, Touch bool
	// agent is the user agent, with %s where the browser's own Chrome version goes.
	agent                    string
	platform, version, model string
}

// Devices are the profiles a session can take, besides "desktop", which is none.
var Devices = []Device{
	// Playwright's "Pixel 7".
	{Name: "phone", Width: 412, Height: 839, Scale: 2.625, Mobile: true, Touch: true,
		agent:    "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36",
		platform: "Android", version: "14.0.0", model: "Pixel 7"},
	// Playwright's "Galaxy Tab S9".
	{Name: "tablet", Width: 640, Height: 1024, Scale: 2.5, Mobile: true, Touch: true,
		agent:    "Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Safari/537.36",
		platform: "Android", version: "14.0.0", model: "SM-X710"},
}

// Desktop is the profile with no overrides: the browser as it starts.
const Desktop = "desktop"

// DeviceNamed is the profile called name, nil for desktop; false when there is none.
func DeviceNamed(name string) (*Device, bool) {
	name = strings.ToLower(strings.TrimSpace(name))
	if name == Desktop {
		return nil, true
	}
	for i := range Devices {
		if Devices[i].Name == name {
			return &Devices[i], true
		}
	}
	return nil, false
}

// metrics is the layout the device gives a page.
func (d *Device) metrics() emulation.SetDeviceMetricsOverrideParams {
	return emulation.SetDeviceMetricsOverrideParams{Width: d.Width, Height: d.Height, DeviceScaleFactor: d.Scale, Mobile: d.Mobile,
		ScreenWidth: d.Width, ScreenHeight: d.Height}
}

// uaHints is what the browser says of itself, as a page reads it: its user agent and, in a
// secure page, its client hints' brands.
type uaHints struct {
	Agent           string                             `json:"agent"`
	Brands          []*emulation.UserAgentBrandVersion `json:"brands"`
	FullVersionList []*emulation.UserAgentBrandVersion `json:"fullVersionList"`
	FullVersion     string                             `json:"fullVersion"`
}

const readHints = `(async () => {
	const d = navigator.userAgentData;
	const h = d ? await d.getHighEntropyValues(["fullVersionList", "uaFullVersion"]) : {};
	return {agent: navigator.userAgent, brands: d ? d.brands : [], fullVersionList: h.fullVersionList || [], fullVersion: h.uaFullVersion || ""};
})()`

var chromeVersion = regexp.MustCompile(`Chrome/([0-9.]+)`)

// userAgent is the device's user agent and client hints, from the browser's own: its
// Chrome version and its brands, with the device's platform, model and mobile.
func (d *Device) userAgent(own uaHints) (emulation.SetUserAgentOverrideParams, error) {
	m := chromeVersion.FindStringSubmatch(own.Agent)
	if m == nil {
		return emulation.SetUserAgentOverrideParams{}, fmt.Errorf("the browser's user agent names no Chrome: %q", own.Agent)
	}
	p := emulation.SetUserAgentOverrideParams{UserAgent: fmt.Sprintf(d.agent, m[1]), Platform: "Linux armv81"}
	if len(own.Brands) > 0 {
		// Chrome on an Android tablet leaves "Mobile" out of its user agent, and says ?0.
		mobile := strings.Contains(p.UserAgent, " Mobile ")
		form := "Tablet"
		if mobile {
			form = "Mobile"
		}
		p.UserAgentMetadata = &emulation.UserAgentMetadata{Brands: own.Brands, FullVersionList: own.FullVersionList,
			Platform: d.platform, PlatformVersion: d.version, Model: d.model, Mobile: mobile, FormFactors: []string{form}}
	}
	return p, nil
}

// emulated is one tab's session that holds its profile.
type emulated struct {
	ctx    context.Context
	cancel context.CancelFunc
	device *Device
}

// Emulate gives tab the device's profile, or takes it away with nil. It holds a session on
// the tab while the profile holds; the tab closing ends it.
func (t *Tabs) Emulate(tab target.ID, d *Device) error {
	t.mu.Lock()
	e := t.emulated[tab]
	if d == nil {
		delete(t.emulated, tab)
		t.mu.Unlock()
		if e != nil {
			// Detached, the session's overrides go with it.
			e.cancel()
		}
		return nil
	}
	if e == nil {
		ctx, cancel := chromedp.NewContext(t.root, chromedp.WithTargetID(tab), chromedp.WithDetachOnCancel())
		e = &emulated{ctx: ctx, cancel: cancel}
		if t.emulated == nil {
			t.emulated = map[target.ID]*emulated{}
		}
		t.emulated[tab] = e
		t.mu.Unlock()
		// The first call attaches, with no time limit, as it ties the tab's context to its own.
		if err := chromedp.Do(ctx); err != nil {
			t.forget(tab, e)
			return err
		}
	} else {
		t.mu.Unlock()
	}
	if err := t.apply(e.ctx, d); err != nil {
		t.forget(tab, e)
		return err
	}
	t.mu.Lock()
	e.device = d
	t.mu.Unlock()
	return nil
}

// apply sets the device's overrides on the session of ctx.
func (t *Tabs) apply(ctx context.Context, d *Device) error {
	call, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	own, err := t.ownHints(call)
	if err != nil {
		return err
	}
	ua, err := d.userAgent(own)
	if err != nil {
		return err
	}
	if _, err := chromedp.Call(call, emulation.SetDeviceMetricsOverride, d.metrics()); err != nil {
		return err
	}
	if _, err := chromedp.Call(call, emulation.SetTouchEmulationEnabled,
		emulation.SetTouchEmulationEnabledParams{Enabled: d.Touch, MaxTouchPoints: 5}); err != nil {
		return err
	}
	_, err = chromedp.Call(call, emulation.SetUserAgentOverride, ua)
	return err
}

// ownHints is the browser's own user agent and client hints, read once from a page and kept
// while the browser runs. A page that this emulates already says the same Chrome and brands.
func (t *Tabs) ownHints(ctx context.Context) (uaHints, error) {
	t.mu.Lock()
	own := t.hints
	t.mu.Unlock()
	if len(own.Brands) > 0 {
		return own, nil
	}
	read, err := chromedp.Run(ctx, chromedp.Evaluate[uaHints](readHints, chromedp.EvalAwaitPromise))
	if err != nil {
		return uaHints{}, err
	}
	if read.Agent == "" {
		return uaHints{}, errors.New("the page did not say the browser's user agent")
	}
	t.mu.Lock()
	// Kept only with the brands, which only a secure page reads: a page that is not asks again.
	if t.hints.Agent == "" || len(read.Brands) > 0 {
		t.hints = read
	}
	t.mu.Unlock()
	return read, nil
}

// EmulatedAs is the profile tab has, nil for none.
func (t *Tabs) EmulatedAs(tab target.ID) *Device {
	t.mu.Lock()
	defer t.mu.Unlock()
	if e := t.emulated[tab]; e != nil {
		return e.device
	}
	return nil
}

// forget drops tab's session, when it is still e (nil: whichever it has).
func (t *Tabs) forget(tab target.ID, e *emulated) {
	t.mu.Lock()
	had := t.emulated[tab]
	if had != nil && (e == nil || had == e) {
		delete(t.emulated, tab)
	} else {
		had = nil
	}
	t.mu.Unlock()
	if had != nil {
		had.cancel()
	}
}
