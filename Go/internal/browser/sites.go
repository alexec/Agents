package browser

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/chromedp/cdproto/cdp"
	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/cdproto/storage"
	"github.com/chromedp/chromedp"
	"golang.org/x/net/publicsuffix"
)

// Settings ▸ Browser (#3535): the sites the kept profile has cookies for, which is how a
// site remembers a sign-in, Clear for one site or all, and the size of the download.
// Chromium keeps its cookies in a database it holds locked while it runs, so they are read
// and cleared through CDP, on the running browser.

// Site is one site with cookies in the kept profile: its registrable domain (github.com),
// with every subdomain's cookies counted under it.
type Site struct {
	Site    string
	Cookies int
}

// cookieStore is what Sites and Clear ask of a running Chromium; a test gives its own.
type cookieStore interface {
	cookies(ctx context.Context) ([]*network.Cookie, error)
	setCookies(ctx context.Context, cs []*network.Cookie) error
	clearOrigin(ctx context.Context, origin string) error
	clearAll(ctx context.Context) error
}

// Installed is whether this machine has a browser to start: Google Chrome (#5207), or a
// Chromium downloaded into Playwright's browsers folder.
func (m *Machine) Installed() bool {
	if m.chromeExe() != "" {
		return true
	}
	entries, err := os.ReadDir(m.Binaries)
	return err == nil && len(entries) > 0
}

// DownloadBytes is the size on disk of the Chromium download, 0 before the first one.
func (m *Machine) DownloadBytes() int64 {
	var n int64
	_ = filepath.WalkDir(m.Binaries, func(_ string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if fi, err := d.Info(); err == nil && fi.Mode().IsRegular() {
			n += fi.Size()
		}
		return nil
	})
	return n
}

// Sites is every site with cookies in the kept profile, most cookies first. Before
// Chromium is downloaded there are none, and nothing is started or downloaded; after,
// it starts Chromium when it is not running.
func (m *Machine) Sites(ctx context.Context) ([]Site, error) {
	store, err := m.store()
	if store == nil || err != nil {
		return nil, err
	}
	all, err := store.cookies(ctx)
	if err != nil {
		return nil, err
	}
	counts := map[string]int{}
	for _, c := range all {
		counts[SiteOf(c.Domain)]++
	}
	sites := make([]Site, 0, len(counts))
	for s, n := range counts {
		sites = append(sites, Site{Site: s, Cookies: n})
	}
	sort.Slice(sites, func(i, j int) bool {
		if sites[i].Cookies != sites[j].Cookies {
			return sites[i].Cookies > sites[j].Cookies
		}
		return sites[i].Site < sites[j].Site
	})
	return sites, nil
}

// Clear removes one site's cookies, and the storage of each host they were set for, or,
// with site "", every cookie and the storage of every host that had one. An agent signed
// in to that site is signed out. The browser endpoint has no call that deletes one
// cookie, so it clears them all and sets back the other sites'.
func (m *Machine) Clear(ctx context.Context, site string) error {
	store, err := m.store()
	if store == nil || err != nil {
		return err
	}
	all, err := store.cookies(ctx)
	if err != nil {
		return err
	}
	hosts := map[string]bool{}
	var keep []*network.Cookie
	for _, c := range all {
		if site != "" && SiteOf(c.Domain) != site {
			keep = append(keep, c)
			continue
		}
		hosts[strings.TrimPrefix(c.Domain, ".")] = true
	}
	if len(hosts) == 0 {
		return nil
	}
	if err := store.clearAll(ctx); err != nil {
		return err
	}
	if len(keep) > 0 {
		if err := store.setCookies(ctx, keep); err != nil {
			return fmt.Errorf("the other sites' cookies were cleared too: %w", err)
		}
	}
	for h := range hosts {
		for _, scheme := range []string{"https://", "http://"} {
			// Storage a host never had is no error to Chromium; a failure here leaves the
			// cookies, which hold the sign-in, cleared all the same.
			_ = store.clearOrigin(ctx, scheme+h)
		}
	}
	return nil
}

// store is the running browser's cookies, after it starts it when Chromium is downloaded;
// nil, with no error, when it is not.
func (m *Machine) store() (cookieStore, error) {
	if !m.Installed() {
		return nil, nil
	}
	if _, err := m.Endpoint(nil); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.running == nil || m.running.store == nil {
		return nil, errors.New("the browser stopped")
	}
	return m.running.store, nil
}

// SiteOf is the site a cookie's domain belongs to: its registrable domain (github.com for
// .api.github.com), or the host itself when it has none (localhost, an IP address).
func SiteOf(domain string) string {
	host := strings.ToLower(strings.TrimPrefix(domain, "."))
	if s, err := publicsuffix.EffectiveTLDPlusOne(host); err == nil {
		return s
	}
	return host
}

// cdpStore is a running Chromium's cookies, over the chromedp context that started it.
type cdpStore struct{ ctx context.Context }

// bound runs a call on the browser's own connection, with ctx's deadline: the browser's context
// lives as long as Chromium, ctx as long as the request.
func (s cdpStore) bound(ctx context.Context) (context.Context, context.CancelFunc) {
	c, cancel := context.WithCancel(s.ctx)
	stop := context.AfterFunc(ctx, cancel)
	return c, func() { stop(); cancel() }
}

func (s cdpStore) cookies(ctx context.Context) ([]*network.Cookie, error) {
	c, done := s.bound(ctx)
	defer done()
	res, err := chromedp.CallBrowser(c, storage.GetCookies, storage.GetCookiesParams{})
	return res.Cookies, err
}

func (s cdpStore) setCookies(ctx context.Context, cs []*network.Cookie) error {
	c, done := s.bound(ctx)
	defer done()
	params := make([]*network.CookieParam, 0, len(cs))
	for _, ck := range cs {
		p := &network.CookieParam{Name: ck.Name, Value: ck.Value, Domain: ck.Domain, Path: ck.Path,
			Secure: ck.Secure, HTTPOnly: ck.HTTPOnly, SameSite: ck.SameSite, Priority: ck.Priority,
			SourceScheme: ck.SourceScheme, SourcePort: ck.SourcePort, PartitionKey: ck.PartitionKey}
		if !ck.Session && ck.Expires > 0 {
			p.Expires = cdp.TimeSinceEpoch(ck.Expires)
		}
		params = append(params, p)
	}
	_, err := chromedp.CallBrowser(c, storage.SetCookies, storage.SetCookiesParams{Cookies: params})
	return err
}

// clearOrigin runs on the tab chromedp opened at the start: the browser endpoint answers
// Storage.clearDataForOrigin with an internal error, a page's clears the whole profile's.
func (s cdpStore) clearOrigin(ctx context.Context, origin string) error {
	c, done := s.bound(ctx)
	defer done()
	_, err := chromedp.Call(c, storage.ClearDataForOrigin, storage.ClearDataForOriginParams{Origin: origin, StorageTypes: "all"})
	return err
}

func (s cdpStore) clearAll(ctx context.Context) error {
	c, done := s.bound(ctx)
	defer done()
	_, err := chromedp.CallBrowser(c, storage.ClearCookies, storage.ClearCookiesParams{})
	return err
}
