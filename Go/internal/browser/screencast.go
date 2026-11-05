package browser

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/cdp"
	"github.com/chromedp/cdproto/emulation"
	"github.com/chromedp/cdproto/input"
	"github.com/chromedp/cdproto/page"
	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/remote"
)

// The page a person watches (#3528, spike #3527): a CDP screencast of one tab of the
// machine's browser, and the person's input sent back to it. The cast attaches to a tab
// and leaves it open when it ends, so watching never closes an agent's page. It follows
// the newest tab: when an agent opens one, the person sees it.

// Frame is one JPEG of the page. Ack it with Cast.Ack once a client has drawn it:
// Chromium sends the next only then, so a slow client gets fewer frames, not a backlog.
type Frame struct {
	JPEG          []byte
	Ack           int64
	Width, Height float64
}

// Page is what the watched tab shows.
type Page struct {
	URL, Title string
}

// Input is the person's click, scroll, key or paste, in the page's CSS pixels.
type Input struct {
	Kind       string // mouse, wheel, key or text
	Type       string // mouse: mousePressed, mouseReleased, mouseMoved; key: keyDown, keyUp, char
	X, Y       float64
	Button     string
	ClickCount int64
	DeltaX     float64
	DeltaY     float64
	Key, Code  string
	KeyCode    int64
	Text       string
	Modifiers  int64
}

// The size a cast lays the page out at, in CSS pixels.
const (
	minSide = 200
	maxSide = 4096
)

// Cast is a screencast of the machine's browser. Make one with Watch; Close ends it.
type Cast struct {
	frame  func(Frame)
	page   func(Page)
	closed func()

	root       context.Context
	cancelRoot context.CancelFunc

	mu      sync.Mutex
	width   int64
	height  int64
	tab     target.ID
	tabCtx  context.Context
	stopTab context.CancelFunc
	done    bool
	// known is every tab seen: discovery says targetCreated again for the tabs that were
	// open already, and only a new one is followed.
	known map[target.ID]bool
}

// Watch starts a screencast of the newest tab of the browser at endpoint, laid out at
// width by height. frame hears each frame, page each change of address or title, and
// closed once, when the browser goes away (not after Close).
func Watch(endpoint string, width, height int64, frame func(Frame), page func(Page), closed func()) (*Cast, error) {
	alloc, cancelAlloc := remote.NewAllocator(context.Background(), endpoint, remote.NoModifyURL)
	root, cancelRoot := chromedp.NewContext(alloc)
	c := &Cast{frame: frame, page: page, closed: closed, root: root,
		cancelRoot: func() { cancelRoot(); cancelAlloc() }}
	c.width, c.height = clampSide(width), clampSide(height)
	// chromedp ties the connection's life to the context of its first call, so that one
	// is root itself, with no time limit; the browser is on this machine.
	if _, err := chromedp.CallBrowser(root, target.SetDiscoverTargets, target.SetDiscoverTargetsParams{Discover: true}); err != nil {
		c.cancelRoot()
		return nil, err
	}
	setup, cancel := context.WithTimeout(root, 15*time.Second)
	defer cancel()
	tab, err := c.newestTab(setup)
	if err != nil {
		c.cancelRoot()
		return nil, err
	}
	if err := c.attach(tab); err != nil {
		c.cancelRoot()
		return nil, err
	}
	go c.followTabs()
	return c, nil
}

// newestTab is the last page the browser lists, or a new blank one when it has none.
func (c *Cast) newestTab(ctx context.Context) (target.ID, error) {
	res, err := chromedp.CallBrowser(ctx, target.GetTargets, target.GetTargetsParams{})
	if err != nil {
		return "", err
	}
	c.mu.Lock()
	c.known = map[target.ID]bool{}
	for _, i := range res.TargetInfos {
		if i != nil {
			c.known[i.TargetID] = true
		}
	}
	c.mu.Unlock()
	if id := pickTab(res.TargetInfos, ""); id != "" {
		return id, nil
	}
	made, err := chromedp.CallBrowser(ctx, target.CreateTarget, target.CreateTargetParams{URL: "about:blank"})
	if err != nil {
		return "", err
	}
	return made.TargetID, nil
}

// pickTab is the newest page tab other than not: Chromium lists the newest first.
func pickTab(infos []*target.Info, not target.ID) target.ID {
	for _, i := range infos {
		if i != nil && i.Type == "page" && i.TargetID != not && !strings.HasPrefix(i.URL, "devtools://") {
			return i.TargetID
		}
	}
	return ""
}

// attach moves the cast to tab: it stops the old tab's screencast and starts one on this.
func (c *Cast) attach(tab target.ID) error {
	c.mu.Lock()
	if c.done {
		c.mu.Unlock()
		return errors.New("the cast is closed")
	}
	if c.stopTab != nil {
		c.stopTab()
	}
	ctx, cancel := chromedp.NewContext(c.root, chromedp.WithTargetID(tab), chromedp.WithDetachOnCancel())
	c.tab, c.tabCtx, c.stopTab = tab, ctx, cancel
	w, h := c.width, c.height
	c.mu.Unlock()

	// The first call attaches, with no time limit, as it ties the tab's context to its own.
	if err := chromedp.Do(ctx); err != nil {
		cancel()
		return err
	}
	// The events first, so the first frame is not missed.
	frames := chromedp.Events(ctx, page.ScreencastFrame)
	go func() {
		for ev, err := range frames {
			if err != nil {
				return
			}
			f := Frame{JPEG: ev.Data, Ack: ev.SessionID}
			if m := ev.Metadata; m != nil {
				f.Width, f.Height = m.DeviceWidth, m.DeviceHeight
			}
			c.frame(f)
		}
	}()
	if err := c.start(ctx, w, h); err != nil {
		cancel()
		return err
	}
	c.tellPage(ctx)
	return nil
}

// start lays the page out at w by h and asks for frames of that size.
func (c *Cast) start(ctx context.Context, w, h int64) error {
	call, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if _, err := chromedp.Call(call, emulation.SetDeviceMetricsOverride,
		emulation.SetDeviceMetricsOverrideParams{Width: w, Height: h, DeviceScaleFactor: 1}); err != nil {
		return err
	}
	quality := int64(60)
	_, err := chromedp.Call(call, page.StartScreencast, page.StartScreencastParams{
		Format: page.StartScreencastFormatJpeg, Quality: &quality, MaxWidth: w, MaxHeight: h, EveryNthFrame: 1})
	return err
}

// tellPage says the watched tab's address and title.
func (c *Cast) tellPage(ctx context.Context) {
	call, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	res, err := chromedp.CallBrowser(call, target.GetTargets, target.GetTargetsParams{})
	if err != nil {
		return
	}
	c.mu.Lock()
	tab := c.tab
	c.mu.Unlock()
	for _, i := range res.TargetInfos {
		if i != nil && i.TargetID == tab {
			c.page(Page{URL: i.URL, Title: i.Title})
		}
	}
}

// followTabs moves to each new tab, away from a closed one, and says each change of the
// watched tab's address or title. It ends when the browser does, and says closed then.
func (c *Cast) followTabs() {
	events := make(chan any, 64)
	ended := make(chan struct{})
	ctx := c.root
	listen := func(each func(func(any) bool)) {
		each(func(ev any) bool {
			select {
			case events <- ev:
				return true
			case <-ctx.Done():
				return false
			}
		})
		select {
		case ended <- struct{}{}:
		case <-ctx.Done():
		}
	}
	go listen(func(yield func(any) bool) {
		for ev, err := range chromedp.BrowserEvents(ctx, target.TargetCreated) {
			if err != nil || !yield(ev) {
				return
			}
		}
	})
	go listen(func(yield func(any) bool) {
		for ev, err := range chromedp.BrowserEvents(ctx, target.TargetDestroyed) {
			if err != nil || !yield(ev) {
				return
			}
		}
	})
	go listen(func(yield func(any) bool) {
		for ev, err := range chromedp.BrowserEvents(ctx, target.TargetInfoChanged) {
			if err != nil || !yield(ev) {
				return
			}
		}
	})
	for {
		select {
		case <-ctx.Done():
			return
		case <-ended:
			// The browser went away (or the cast was closed, which ctx says first).
			c.mu.Lock()
			done := c.done
			c.done = true
			c.mu.Unlock()
			if !done && c.closed != nil {
				c.closed()
			}
			c.cancelRoot()
			return
		case ev := <-events:
			c.handleTarget(ev)
		}
	}
}

func (c *Cast) handleTarget(ev any) {
	c.mu.Lock()
	tab := c.tab
	var fresh bool
	if e, ok := ev.(target.EventTargetCreated); ok && e.TargetInfo != nil {
		fresh = !c.known[e.TargetInfo.TargetID]
		c.known[e.TargetInfo.TargetID] = true
	}
	c.mu.Unlock()
	switch e := ev.(type) {
	case target.EventTargetCreated:
		if i := e.TargetInfo; fresh && i.Type == "page" && i.TargetID != tab {
			_ = c.attach(i.TargetID)
		}
	case target.EventTargetDestroyed:
		if e.TargetID != tab {
			return
		}
		ctx, cancel := context.WithTimeout(c.root, 15*time.Second)
		defer cancel()
		res, err := chromedp.CallBrowser(ctx, target.GetTargets, target.GetTargetsParams{})
		if err != nil {
			return
		}
		next := pickTab(res.TargetInfos, tab)
		if next == "" {
			made, err := chromedp.CallBrowser(ctx, target.CreateTarget, target.CreateTargetParams{URL: "about:blank"})
			if err != nil {
				return
			}
			next = made.TargetID
		}
		_ = c.attach(next)
	case target.EventTargetInfoChanged:
		if i := e.TargetInfo; i != nil && i.TargetID == tab {
			c.page(Page{URL: i.URL, Title: i.Title})
		}
	}
}

// tabContext is the watched tab's context, or an error once the cast is closed.
func (c *Cast) tabContext() (context.Context, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.done || c.tabCtx == nil {
		return nil, errors.New("the browser is not running")
	}
	return c.tabCtx, nil
}

// Ack says a client drew frame n, so Chromium may send the next.
func (c *Cast) Ack(n int64) {
	ctx, err := c.tabContext()
	if err != nil {
		return
	}
	call, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, _ = chromedp.Call(call, page.ScreencastFrameAck, page.ScreencastFrameAckParams{SessionID: n})
}

// Resize lays the page out at a new size and asks for frames of it.
func (c *Cast) Resize(width, height int64) error {
	c.mu.Lock()
	c.width, c.height = clampSide(width), clampSide(height)
	w, h := c.width, c.height
	c.mu.Unlock()
	ctx, err := c.tabContext()
	if err != nil {
		return err
	}
	return c.start(ctx, w, h)
}

// Input sends the person's input to the page.
func (c *Cast) Input(in Input) error {
	ctx, err := c.tabContext()
	if err != nil {
		return err
	}
	call, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	switch in.Kind {
	case "mouse", "wheel":
		_, err = chromedp.Call(call, input.DispatchMouseEvent, mouseParams(in))
	case "key":
		_, err = chromedp.Call(call, input.DispatchKeyEvent, keyParams(in))
	case "text":
		_, err = chromedp.Call(call, input.InsertText, input.InsertTextParams{Text: in.Text})
	default:
		err = errors.New("unknown input: " + in.Kind)
	}
	return err
}

func mouseParams(in Input) input.DispatchMouseEventParams {
	p := input.DispatchMouseEventParams{X: in.X, Y: in.Y, Modifiers: in.Modifiers}
	if in.Kind == "wheel" {
		p.Type = input.DispatchMouseEventTypeMouseWheel
		p.DeltaX, p.DeltaY = in.DeltaX, in.DeltaY
		return p
	}
	p.Type = input.DispatchMouseEventType(in.Type)
	if p.Type == "" {
		p.Type = input.DispatchMouseEventTypeMouseMoved
	}
	p.Button = input.MouseButton(in.Button)
	if p.Button == "" {
		p.Button = input.MouseButtonNone
	}
	p.ClickCount = in.ClickCount
	if p.Type != input.DispatchMouseEventTypeMouseMoved && p.ClickCount == 0 {
		p.ClickCount = 1
	}
	// buttons is what is held during the event: a press holds its button, a move after
	// one (a drag) too, which the client says by naming the button on the move.
	if p.Type != input.DispatchMouseEventTypeMouseReleased {
		p.Buttons = map[input.MouseButton]int64{
			input.MouseButtonLeft: 1, input.MouseButtonRight: 2, input.MouseButtonMiddle: 4}[p.Button]
	}
	return p
}

func keyParams(in Input) input.DispatchKeyEventParams {
	p := input.DispatchKeyEventParams{Type: input.DispatchKeyEventType(in.Type), Key: in.Key, Code: in.Code,
		WindowsVirtualKeyCode: in.KeyCode, NativeVirtualKeyCode: in.KeyCode, Modifiers: in.Modifiers}
	if p.Type == "" {
		p.Type = input.DispatchKeyEventTypeKeyDown
	}
	// A key down with text types it; one without (Backspace, an arrow, a shortcut) is a
	// raw key down, as Chromium's own DevTools screencast sends it.
	if p.Type == input.DispatchKeyEventTypeKeyDown {
		if in.Text == "" {
			p.Type = input.DispatchKeyEventTypeRawKeyDown
		} else {
			p.Text, p.UnmodifiedText = in.Text, in.Text
		}
	}
	if p.Type == input.DispatchKeyEventTypeChar {
		p.Text, p.UnmodifiedText = in.Text, in.Text
	}
	return p
}

// Navigate is the bar over the page: go to an address, back, forward or reload.
func (c *Cast) Navigate(action, address string) error {
	ctx, err := c.tabContext()
	if err != nil {
		return err
	}
	call, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	switch action {
	case "go":
		u, err := Address(address)
		if err != nil {
			return err
		}
		_, err = chromedp.Call(call, page.Navigate, page.NavigateParams{URL: u})
		return err
	case "reload":
		_, err := chromedp.Call(call, page.Reload, page.ReloadParams{})
		return err
	case "back", "forward":
		h, err := chromedp.Call(call, page.GetNavigationHistory, cdp.Empty{})
		if err != nil {
			return err
		}
		i := h.CurrentIndex - 1
		if action == "forward" {
			i = h.CurrentIndex + 1
		}
		if i < 0 || int(i) >= len(h.Entries) {
			return nil
		}
		_, err = chromedp.Call(call, page.NavigateToHistoryEntry, page.NavigateToHistoryEntryParams{EntryID: h.Entries[i].ID})
		return err
	}
	return errors.New("unknown action: " + action)
}

// Address is what a person typed in the bar, as a URL: https:// when it names no scheme,
// http:// for this machine's own servers.
func Address(typed string) (string, error) {
	s := strings.TrimSpace(typed)
	if s == "" {
		return "", errors.New("no address")
	}
	if strings.Contains(s, "://") || strings.HasPrefix(s, "about:") || strings.HasPrefix(s, "data:") {
		if _, err := url.Parse(s); err != nil {
			return "", err
		}
		return s, nil
	}
	scheme := "https://"
	host := strings.SplitN(s, "/", 2)[0]
	if h := strings.Split(host, ":")[0]; h == "localhost" || h == "127.0.0.1" || strings.HasSuffix(h, ".localhost") {
		scheme = "http://"
	}
	u := scheme + s
	if _, err := url.Parse(u); err != nil {
		return "", err
	}
	return u, nil
}

// Close ends the screencast and leaves the tab open.
func (c *Cast) Close() {
	c.mu.Lock()
	if c.done {
		c.mu.Unlock()
		c.cancelRoot()
		return
	}
	c.done = true
	ctx, stop := c.tabCtx, c.stopTab
	c.mu.Unlock()
	if ctx != nil {
		call, cancel := context.WithTimeout(ctx, 2*time.Second)
		_, _ = chromedp.Call(call, page.StopScreencast, cdp.Empty{})
		_, _ = chromedp.Call(call, emulation.ClearDeviceMetricsOverride, cdp.Empty{})
		cancel()
		stop()
	}
	c.cancelRoot()
}

func clampSide(n int64) int64 {
	return min(max(n, minSide), maxSide)
}
