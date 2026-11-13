package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// A hand-off in one of the agents' own Chrome windows (#5095). Some sites refuse the app's
// browser (Chrome for Testing): Google (#4837) and Microsoft (#4324) pass only in a real
// Chrome that an agent drives over DevTools (.agents/signups/cdp.mjs), and they then show a
// human check there. hand_to_person with cdp_port hands that step to the person: the
// daemon brings that Chrome's page tab to the front and the card names the window, in place
// of Open the page. The daemon does no step on the page: it only finds and shows the tab.

// handOffPort is hand_to_person's cdp_port, when the call gives one.
func handOffPort(args map[string]json.RawMessage) (int, bool) {
	if _, ok := args["cdp_port"]; !ok {
		return 0, false
	}
	port, _ := argInt(args, "cdp_port")
	return port, true
}

// chromeAsksLongest is the most finding and showing the tab may take: Chrome on this
// machine answers DevTools' HTTP at once, or not at all.
const chromeAsksLongest = 5 * time.Second

// chromeTarget is one entry of Chrome's DevTools /json/list.
type chromeTarget struct {
	ID    string `json:"id"`
	Type  string `json:"type"`
	Title string `json:"title"`
	URL   string `json:"url"`
}

// frontChromeTab brings the first web page tab of the Chrome on this DevTools port to the
// front, and says that window as the card names it. The first web page, not the first tab:
// Chrome's own pages (its sign-in bubble, chrome://…) can take the first place (#4837).
func frontChromeTab(ctx context.Context, port int) (string, error) {
	if port < 1024 || port > 65535 {
		return "", fmt.Errorf("cdp_port %d is not a DevTools port: give the port the agents' Chrome was started with, as 9233", port)
	}
	ctx, cancel := context.WithTimeout(ctx, chromeAsksLongest)
	defer cancel()
	base := "http://127.0.0.1:" + strconv.Itoa(port)
	noChrome := fmt.Errorf("no Chrome answers on DevTools port %d. Start that Chrome first (.agents/signups/cdp.mjs), open the page, then hand the step over", port)
	var targets []chromeTarget
	if err := chromeGet(ctx, base+"/json/list", &targets); err != nil {
		return "", noChrome
	}
	var tab *chromeTarget
	for i, t := range targets {
		if t.Type == "page" && (strings.HasPrefix(t.URL, "https://") || strings.HasPrefix(t.URL, "http://")) {
			tab = &targets[i]
			break
		}
	}
	if tab == nil {
		return "", fmt.Errorf("the Chrome on DevTools port %d has no web page open. Open the page with the step first", port)
	}
	if err := chromeGet(ctx, base+"/json/activate/"+url.PathEscape(tab.ID), nil); err != nil {
		return "", noChrome
	}
	return chromeWindowWords(port, tab.Title, tab.URL), nil
}

// chromeWindowWords is the window as the card says it: "the agents' Chrome (DevTools port
// 9233), at the tab “Create account” (signup.live.com)".
func chromeWindowWords(port int, title, page string) string {
	said := "the agents' Chrome (DevTools port " + strconv.Itoa(port) + ")"
	host := ""
	if u, err := url.Parse(page); err == nil {
		host = u.Hostname()
	}
	title = strings.TrimSpace(title)
	switch {
	case title != "" && host != "":
		said += ", at the tab “" + title + "” (" + host + ")"
	case host != "":
		said += ", at " + host
	}
	return said
}

// chromeGet asks Chrome's DevTools HTTP for one path, and reads its JSON into out (nil
// reads nothing).
func chromeGet(ctx context.Context, address string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.New(resp.Status)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
