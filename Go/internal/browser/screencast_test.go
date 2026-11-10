package browser

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/chromedp/cdproto/input"
	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/remote"
)

func TestAnAddressGetsAScheme(t *testing.T) {
	for typed, want := range map[string]string{
		"example.com":               "https://example.com",
		" gitlab.com/users/sign_in": "https://gitlab.com/users/sign_in",
		"localhost:3000/x":          "http://localhost:3000/x",
		"127.0.0.1:8080":            "http://127.0.0.1:8080",
		"app.localhost":             "http://app.localhost",
		"http://example.com":        "http://example.com",
		"about:blank":               "about:blank",
	} {
		if got, err := Address(typed); err != nil || got != want {
			t.Errorf("%q: %q %v", typed, got, err)
		}
	}
	if _, err := Address("  "); err == nil {
		t.Error("an empty address")
	}
}

func TestTheNewestPageIsWatched(t *testing.T) {
	infos := []*target.Info{
		{TargetID: "w", Type: "service_worker"},
		{TargetID: "d", Type: "page", URL: "devtools://devtools/inspector.html"},
		{TargetID: "b", Type: "page", URL: "https://b.example"},
		{TargetID: "a", Type: "page", URL: "about:blank"},
	}
	if got := pickTab(infos, ""); got != "b" {
		t.Fatal(got)
	}
	if got := pickTab(infos, "b"); got != "a" {
		t.Fatal(got)
	}
	if got := pickTab(infos[:2], ""); got != "" {
		t.Fatal(got)
	}
}

func TestAClickHoldsItsButtonUntilItIsReleased(t *testing.T) {
	press := mouseParams(Input{Kind: "mouse", Type: "mousePressed", X: 1, Y: 2, Button: "left"})
	if press.Type != input.DispatchMouseEventTypeMousePressed || press.Buttons != 1 || press.ClickCount != 1 || press.X != 1 {
		t.Fatalf("%+v", press)
	}
	drag := mouseParams(Input{Kind: "mouse", Type: "mouseMoved", Button: "left"})
	if drag.Buttons != 1 || drag.ClickCount != 0 {
		t.Fatalf("%+v", drag)
	}
	release := mouseParams(Input{Kind: "mouse", Type: "mouseReleased", Button: "left", ClickCount: 2})
	if release.Buttons != 0 || release.ClickCount != 2 {
		t.Fatalf("%+v", release)
	}
	hover := mouseParams(Input{Kind: "mouse"})
	if hover.Type != input.DispatchMouseEventTypeMouseMoved || hover.Button != input.MouseButtonNone {
		t.Fatalf("%+v", hover)
	}
	wheel := mouseParams(Input{Kind: "wheel", X: 5, Y: 6, DeltaY: 120})
	if wheel.Type != input.DispatchMouseEventTypeMouseWheel || wheel.DeltaY != 120 {
		t.Fatalf("%+v", wheel)
	}
}

func TestAKeyWithTextTypesIt(t *testing.T) {
	a := keyParams(Input{Kind: "key", Type: "keyDown", Key: "a", Code: "KeyA", KeyCode: 65, Text: "a"})
	if a.Type != input.DispatchKeyEventTypeKeyDown || a.Text != "a" || a.WindowsVirtualKeyCode != 65 {
		t.Fatalf("%+v", a)
	}
	back := keyParams(Input{Kind: "key", Type: "keyDown", Key: "Backspace", Code: "Backspace", KeyCode: 8})
	if back.Type != input.DispatchKeyEventTypeRawKeyDown || back.Text != "" {
		t.Fatalf("%+v", back)
	}
	up := keyParams(Input{Kind: "key", Type: "keyUp", Key: "a", Text: "a"})
	if up.Type != input.DispatchKeyEventTypeKeyUp || up.Text != "" {
		t.Fatalf("%+v", up)
	}
}

// TestACastOfARealChromium runs only with AGENTS_TEST_CHROMIUM naming a Chromium: it
// watches a page, clicks into a field, types and pastes into it, follows a new tab, and
// leaves the tabs open when it ends.
func TestACastOfARealChromium(t *testing.T) {
	exe := os.Getenv("AGENTS_TEST_CHROMIUM")
	if exe == "" {
		t.Skip("AGENTS_TEST_CHROMIUM names no Chromium")
	}
	profile := t.TempDir()
	p, err := launchChromium(exe, profile, append(os.Environ(), "HOME="+t.TempDir()), false)
	if err != nil {
		t.Fatal(err)
	}
	defer p.stop()

	frames := make(chan Frame, 16)
	pages := make(chan Page, 16)
	cast, err := Watch(p.endpoint, "", 640, 480, nil, func(f Frame) {
		select {
		case frames <- f:
		default:
		}
	}, func(pg Page) { pages <- pg }, nil)
	if err != nil {
		t.Fatal(err)
	}
	next := func() Frame {
		t.Helper()
		select {
		case f := <-frames:
			cast.Ack(f.Ack)
			return f
		case <-time.After(10 * time.Second):
			t.Fatal("no frame")
		}
		return Frame{}
	}
	page := `data:text/html,<input id=f style="position:absolute;left:0;top:0;width:300px;height:40px" autofocus>`
	if err := cast.Navigate("go", page); err != nil {
		t.Fatal(err)
	}
	f := next()
	if len(f.JPEG) < 100 || f.JPEG[0] != 0xFF || f.JPEG[1] != 0xD8 || f.Width != 640 || f.Height != 480 {
		t.Fatalf("not a 640×480 JPEG: %d bytes, %v×%v", len(f.JPEG), f.Width, f.Height)
	}
	// A person clicks what they see: wait, as they would, for the page to be there.
	ctx, err := cast.tabContext()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; ; i++ {
		ready, _ := chromedp.Run(ctx, chromedp.Evaluate[bool](`document.readyState === "complete" && !!document.getElementById("f")`))
		if ready {
			break
		}
		if i == 100 {
			t.Fatal("the page did not load")
		}
		time.Sleep(50 * time.Millisecond)
	}
	for _, in := range []Input{
		{Kind: "mouse", Type: "mousePressed", X: 20, Y: 20, Button: "left"},
		{Kind: "mouse", Type: "mouseReleased", X: 20, Y: 20, Button: "left"},
		{Kind: "key", Type: "keyDown", Key: "h", Code: "KeyH", KeyCode: 72, Text: "h"},
		{Kind: "key", Type: "keyUp", Key: "h", Code: "KeyH", KeyCode: 72},
		{Kind: "key", Type: "keyDown", Key: "i", Code: "KeyI", KeyCode: 73, Text: "i"},
		{Kind: "key", Type: "keyUp", Key: "i", Code: "KeyI", KeyCode: 73},
		{Kind: "key", Type: "keyDown", Key: "Backspace", Code: "Backspace", KeyCode: 8},
		{Kind: "key", Type: "keyUp", Key: "Backspace", Code: "Backspace", KeyCode: 8},
		{Kind: "text", Text: " there"},
	} {
		editing, err := cast.Input(in)
		if err != nil {
			t.Fatal(in, err)
		}
		// A click released in the field leaves the focus in it: a phone opens its keyboard.
		if released := in.Type == "mouseReleased"; released != (editing != nil) || released && !*editing {
			t.Fatalf("%v: editing %v", in, editing)
		}
	}
	value, err := chromedp.Run(ctx, chromedp.Evaluate[string](`document.getElementById("f").value`))
	if err != nil || value != "h there" {
		t.Fatalf("%q %v", value, err)
	}
	// A click beside the field takes the focus out of it: the keyboard goes.
	for _, kind := range []string{"mousePressed", "mouseReleased"} {
		editing, err := cast.Input(Input{Kind: "mouse", Type: kind, X: 400, Y: 300, Button: "left"})
		if err != nil {
			t.Fatal(err)
		}
		if kind == "mouseReleased" && (editing == nil || *editing) {
			t.Fatalf("editing %v after a click outside the field", editing)
		}
	}

	// An agent's new tab is the one watched.
	made, err := chromedp.CallBrowser(cast.root, target.CreateTarget, target.CreateTargetParams{URL: "data:text/html,<title>Second</title>"})
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.After(10 * time.Second)
	for {
		cast.mu.Lock()
		tab := cast.tab
		cast.mu.Unlock()
		if tab == made.TargetID {
			break
		}
		select {
		case <-deadline:
			t.Fatal("the cast did not follow the new tab")
		case <-time.After(50 * time.Millisecond):
		}
	}
	for seen := false; !seen; {
		select {
		case pg := <-pages:
			seen = pg.Title == "Second"
		case <-time.After(10 * time.Second):
			t.Fatal("no page title")
		}
	}
	if err := cast.Navigate("back", ""); err != nil {
		t.Fatal(err)
	}
	cast.Close()

	// Watching leaves the tabs as they were.
	alloc, cancelAlloc := remote.NewAllocator(context.Background(), p.endpoint, remote.NoModifyURL)
	defer cancelAlloc()
	check, cancel := chromedp.NewContext(alloc)
	defer cancel()
	res, err := chromedp.CallBrowser(check, target.GetTargets, target.GetTargetsParams{})
	if err != nil {
		t.Fatal(err)
	}
	pagesLeft := 0
	for _, i := range res.TargetInfos {
		if i.Type == "page" {
			pagesLeft++
		}
	}
	if pagesLeft < 2 {
		t.Fatalf("the cast closed a tab: %d left", pagesLeft)
	}
}
