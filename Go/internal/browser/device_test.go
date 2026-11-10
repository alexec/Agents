package browser

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/cdproto/emulation"
	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/remote"
)

func TestTheDevicesAreNamed(t *testing.T) {
	if d, ok := DeviceNamed(" Desktop "); !ok || d != nil {
		t.Fatalf("desktop: %v %v", d, ok)
	}
	if d, ok := DeviceNamed("phone"); !ok || d.Width != 412 || !d.Mobile || !d.Touch {
		t.Fatalf("phone: %+v %v", d, ok)
	}
	if d, ok := DeviceNamed("tablet"); !ok || d.Width != 640 {
		t.Fatalf("tablet: %+v %v", d, ok)
	}
	if _, ok := DeviceNamed("watch"); ok {
		t.Fatal("a watch is not a device")
	}
}

// The user agent is the browser's own Chrome on the device, and the client hints keep the
// browser's brands, with the device's platform: they agree, as #4060's user agent does.
func TestADevicesUserAgentKeepsTheBrowsersChrome(t *testing.T) {
	brands := []*emulation.UserAgentBrandVersion{{Brand: "Chromium", Version: "141"}, {Brand: "Not?A_Brand", Version: "8"}}
	own := uaHints{Agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
		Brands: brands, FullVersionList: brands}
	phone, _ := DeviceNamed("phone")
	p, err := phone.userAgent(own)
	if err != nil {
		t.Fatal(err)
	}
	if p.UserAgent != "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36" {
		t.Fatal(p.UserAgent)
	}
	m := p.UserAgentMetadata
	if m == nil || m.Platform != "Android" || !m.Mobile || m.Model != "Pixel 7" || len(m.Brands) != 2 || m.Brands[0].Version != "141" {
		t.Fatalf("%+v", m)
	}
	tablet, _ := DeviceNamed("tablet")
	if p, _ := tablet.userAgent(own); p.UserAgentMetadata.Mobile || strings.Contains(p.UserAgent, "Mobile") {
		t.Fatalf("a tablet is not mobile: %+v", p)
	}
	// With no brands read (a page that is not secure), no hints rather than wrong ones.
	if p, _ := phone.userAgent(uaHints{Agent: own.Agent}); p.UserAgentMetadata != nil {
		t.Fatal("hints with no brands")
	}
	if _, err := phone.userAgent(uaHints{Agent: "Mozilla/5.0"}); err == nil {
		t.Fatal("a user agent with no Chrome")
	}
}

// TestADeviceOnARealChromium runs only with AGENTS_TEST_CHROMIUM naming a Chromium. A tab
// takes the phone's profile, and another session on it (Playwright's, the cast's) sees it;
// a cast that ends leaves it; desktop takes it away.
func TestADeviceOnARealChromium(t *testing.T) {
	exe := os.Getenv("AGENTS_TEST_CHROMIUM")
	if exe == "" {
		t.Skip("AGENTS_TEST_CHROMIUM names no Chromium")
	}
	p, err := launchChromium(exe, t.TempDir(), append(os.Environ(), "HOME="+t.TempDir()), false)
	if err != nil {
		t.Fatal(err)
	}
	defer p.stop()
	tabs, err := FollowTabs(p.endpoint, func(target.ID, target.ID) {}, func(target.ID) {}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tabs.Close()
	// A page made for phones (with no viewport meta, a phone lays a page out 980 wide), on
	// 127.0.0.1, a secure origin, so the page reads client hints and is sent them.
	hints := make(chan http.Header, 8)
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case hints <- r.Header.Clone():
		default:
		}
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(`<meta name=viewport content="width=device-width"><p>a page`))
	}))
	defer site.Close()
	tab, err := tabs.Open(site.URL)
	if err != nil {
		t.Fatal(err)
	}

	// Another client of the browser, as @playwright/mcp is.
	alloc, cancelAlloc := remote.NewAllocator(context.Background(), p.endpoint, remote.NoModifyURL)
	defer cancelAlloc()
	root, cancelRoot := chromedp.NewContext(alloc)
	defer cancelRoot()
	if _, err := chromedp.CallBrowser(root, target.GetTargets, target.GetTargetsParams{}); err != nil {
		t.Fatal(err)
	}
	other, cancelOther := chromedp.NewContext(root, chromedp.WithTargetID(tab), chromedp.WithDetachOnCancel())
	defer cancelOther()
	if err := chromedp.Do(other); err != nil {
		t.Fatal(err)
	}
	type seen struct {
		Width, Touch int64
		Ratio        float64
		Agent        string
		Mobile       bool
		Platform     string
	}
	look := func() seen {
		t.Helper()
		ctx, cancel := context.WithTimeout(other, 10*time.Second)
		defer cancel()
		s, err := chromedp.Run(ctx, chromedp.Evaluate[seen](`({width: innerWidth, touch: navigator.maxTouchPoints, ratio: devicePixelRatio,
			agent: navigator.userAgent, mobile: !!(navigator.userAgentData && navigator.userAgentData.mobile),
			platform: navigator.userAgentData ? navigator.userAgentData.platform : ""})`))
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	before := look()
	if strings.Contains(before.Agent, "Android") || before.Width == 412 {
		t.Fatalf("emulated before: %+v", before)
	}

	phone, _ := DeviceNamed("phone")
	if err := tabs.Emulate(tab, phone); err != nil {
		t.Fatal(err)
	}
	s := look()
	if s.Width != 412 || s.Ratio != 2.625 || s.Touch == 0 || !strings.Contains(s.Agent, "Android 14; Pixel 7") ||
		strings.Contains(s.Agent, "Headless") {
		t.Fatalf("not a phone: %+v", s)
	}
	if v := chromeVersion.FindString(before.Agent); v == "" || !strings.Contains(s.Agent, v) {
		t.Fatalf("not the browser's own Chrome: %q, %q", s.Agent, before.Agent)
	}
	if before.Platform == "" || !s.Mobile || s.Platform != "Android" {
		t.Fatalf("the hints do not agree: %+v, before %+v", s, before)
	}

	// A cast of the session lays the page out as the phone, and leaves it so when it ends.
	frames := make(chan Frame, 4)
	cast, err := Watch(p.endpoint, tab, 800, 600, phone, func(f Frame) {
		select {
		case frames <- f:
		default:
		}
	}, func(Page) {}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if s := look(); s.Width != 412 {
		t.Fatalf("the cast laid it out at %d", s.Width)
	}
	for len(hints) > 0 {
		<-hints
	}
	if err := cast.Navigate("go", site.URL+"/again"); err != nil {
		t.Fatal(err)
	}
	select {
	case h := <-hints:
		if !strings.Contains(h.Get("User-Agent"), "Pixel 7") || h.Get("Sec-CH-UA-Mobile") != "?1" ||
			h.Get("Sec-CH-UA-Platform") != `"Android"` || h.Get("Sec-CH-UA") == "" {
			t.Fatalf("the request does not agree: %v", h)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no request")
	}
	select {
	case f := <-frames:
		if f.Width != 412 {
			t.Fatalf("a frame %v wide", f.Width)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no frame")
	}
	cast.Close()
	time.Sleep(500 * time.Millisecond)
	if s := look(); s.Width != 412 || !strings.Contains(s.Agent, "Pixel 7") {
		t.Fatalf("the cast's end took the phone away: %+v", s)
	}

	// Playwright's session ends with the agent's turn: the phone stays.
	cancelOther()
	other, cancelOther = chromedp.NewContext(root, chromedp.WithTargetID(tab), chromedp.WithDetachOnCancel())
	defer cancelOther()
	if err := chromedp.Do(other); err != nil {
		t.Fatal(err)
	}
	if s := look(); s.Width != 412 {
		t.Fatalf("Playwright's end took the phone away: %+v", s)
	}

	// A cast that watched at the pane's size gives it up for a device the session takes.
	if err := tabs.Emulate(tab, nil); err != nil {
		t.Fatal(err)
	}
	cast, err = Watch(p.endpoint, tab, 800, 600, nil, func(Frame) {}, func(Page) {}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cast.Close()
	if s := look(); s.Width != 800 || strings.Contains(s.Agent, "Android") {
		t.Fatalf("still a phone: %+v", s)
	}
	if err := cast.SetDevice(phone); err != nil {
		t.Fatal(err)
	}
	if err := tabs.Emulate(tab, phone); err != nil {
		t.Fatal(err)
	}
	if s := look(); s.Width != 412 {
		t.Fatalf("the cast kept its size: %+v", s)
	}
	// And takes it back when the session is a desktop again.
	if err := tabs.Emulate(tab, nil); err != nil {
		t.Fatal(err)
	}
	if err := cast.SetDevice(nil); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	if s := look(); s.Width != 800 || strings.Contains(s.Agent, "Android") {
		t.Fatalf("not the pane's size again: %+v", s)
	}
}
