package agentsd

import (
	"container/list"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// forge/image (#4009): an image on a forge page (an issue's body, a comment), read here, so that
// a client never loads a remote URL: a private repo's image needs the forge's token, which only
// this machine holds, and a client that loads what a page names tells its host who reads it.
//
// Only a forge's own image hosts are read; any other URL is refused with no request made, and a
// redirect off them is refused too. The forge's token is sent only to the hosts that need it,
// never to the hosts a redirect goes to for the bytes. Only raster images are given (PNG, JPEG,
// GIF and WebP, by their bytes, not by what the server says): an SVG can hold script. Each image
// is capped, and the answers are kept in a small LRU, so scrolling a page again asks nothing.
const (
	// forgeImageMost is the most bytes of one image; reading stops past it.
	forgeImageMost = 10 << 20
	// forgeImageWait is how long one image may take, redirects included.
	forgeImageWait = 15 * time.Second
	// forgeImagesKept and forgeImageBytesKept bound the cache: the least recently read go first.
	forgeImagesKept     = 64
	forgeImageBytesKept = 50 << 20
	// forgeImageRedirects bounds the redirects of one read.
	forgeImageRedirects = 5
)

// forgeImageTypes are the image types given; anything else, SVG among them, is refused.
var forgeImageTypes = map[string]bool{"image/png": true, "image/jpeg": true, "image/gif": true, "image/webp": true}

// forgeImageHost is one forge's seam: the URLs of its images, and its token for the hosts that need it.
// Each later forge adds one, with its hosts and its auth.
type forgeImageHost interface {
	// allows says that u is one of this forge's image URLs, for the first read and each redirect.
	allows(u *url.URL) bool
	// authorize adds the forge's token to req when req's host needs it, and only then.
	authorize(d *Daemon, req *http.Request)
}

// githubImages are GitHub's image hosts: attachments on github.com (user-attachments and a
// repo's assets), a repo's file on github.com (blob with raw=true, or raw; pr-shots.sh's
// screenshots, #4522), and the githubusercontent.com hosts they redirect to.
type githubImages struct{}

// githubImageHosts are read at any path; github.com only at its image paths.
var githubImageHosts = map[string]bool{
	"user-images.githubusercontent.com":         true,
	"private-user-images.githubusercontent.com": true,
	"raw.githubusercontent.com":                 true,
	"avatars.githubusercontent.com":             true,
}

func (githubImages) allows(u *url.URL) bool {
	if u.Scheme != "https" || u.User != nil || u.Port() != "" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	if githubImageHosts[host] {
		return true
	}
	if host != "github.com" {
		return false
	}
	// /user-attachments/assets/<id>, or /<owner>/<repo>/assets/<…>.
	parts := strings.Split(strings.TrimPrefix(u.EscapedPath(), "/"), "/")
	switch {
	case len(parts) >= 3 && parts[0] == "user-attachments" && parts[1] == "assets" && parts[2] != "":
		return true
	case len(parts) >= 4 && parts[0] != "" && parts[1] != "" && parts[2] == "assets" && parts[3] != "":
		return true
	}
	// /<owner>/<repo>/blob/<ref>/<path>?raw=true, or /<owner>/<repo>/raw/<ref>/<path>: GitHub
	// redirects both to raw.githubusercontent.com. A blob without raw=true is the HTML page.
	switch githubRepoFile(u) {
	case "raw":
		return true
	case "blob":
		return u.Query().Get("raw") == "true"
	}
	return false
}

// githubRepoFile is "blob" or "raw" when u's path is /<owner>/<repo>/<blob|raw>/<ref>/<path>,
// every segment set and none a dot segment, else "".
func githubRepoFile(u *url.URL) string {
	parts := strings.Split(strings.TrimPrefix(u.Path, "/"), "/")
	if len(parts) < 5 || (parts[2] != "blob" && parts[2] != "raw") {
		return ""
	}
	for _, p := range parts {
		if p == "" || p == "." || p == ".." {
			return ""
		}
	}
	return parts[2]
}

// authorize sends the GitHub connection's token to github.com (a private repo's attachment) and
// raw.githubusercontent.com (a private repo's file); the other hosts take a signed URL instead.
func (githubImages) authorize(d *Daemon, req *http.Request) {
	host := strings.ToLower(req.URL.Hostname())
	if host != "github.com" && host != "raw.githubusercontent.com" {
		return
	}
	if c, ok := d.githubConnection(); ok && c.Usable(nowFunc()) && c.Access != "" {
		req.Header.Set("Authorization", "Bearer "+c.Access)
	}
}

// forgeImageHosts are the forges whose images are read, GitHub first.
var forgeImageHosts = []forgeImageHost{githubImages{}}

type forgeImageCache struct {
	mu    sync.Mutex
	order *list.List // of *forgeImageEntry, the most recently read first
	byURL map[string]*list.Element
	bytes int
}

type forgeImageEntry struct {
	url   string
	image wire.ForgeImage
}

func (c *forgeImageCache) get(u string) (wire.ForgeImage, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.byURL[u]
	if !ok {
		return wire.ForgeImage{}, false
	}
	c.order.MoveToFront(e)
	return e.Value.(*forgeImageEntry).image, true
}

func (c *forgeImageCache) put(u string, image wire.ForgeImage) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.byURL == nil {
		c.order, c.byURL = list.New(), map[string]*list.Element{}
	}
	if e, ok := c.byURL[u]; ok {
		c.bytes -= len(e.Value.(*forgeImageEntry).image.Data)
		c.order.Remove(e)
		delete(c.byURL, u)
	}
	c.byURL[u] = c.order.PushFront(&forgeImageEntry{url: u, image: image})
	c.bytes += len(image.Data)
	for c.order.Len() > forgeImagesKept || c.bytes > forgeImageBytesKept {
		last := c.order.Back()
		old := last.Value.(*forgeImageEntry)
		c.bytes -= len(old.image.Data)
		c.order.Remove(last)
		delete(c.byURL, old.url)
	}
}

func (d *Daemon) registerForgeImage() {
	On(d, wire.CallForgeImage, func(ctx context.Context, _ *Client, r wire.ForgeImageRequest) (wire.ForgeImage, error) {
		return d.forgeImage(ctx, r.URL)
	})
}

// forgeImageOf is the forge whose image u is, or nil.
func forgeImageOf(u *url.URL) forgeImageHost {
	for _, h := range forgeImageHosts {
		if h.allows(u) {
			return h
		}
	}
	return nil
}

func (d *Daemon) forgeImage(ctx context.Context, raw string) (wire.ForgeImage, error) {
	u, err := url.Parse(raw)
	if err != nil || !u.IsAbs() {
		return wire.ForgeImage{}, errors.New("forge/image: not a URL")
	}
	forge := forgeImageOf(u)
	if forge == nil {
		return wire.ForgeImage{}, fmt.Errorf("forge/image: %s is not a forge's image host", u.Hostname())
	}
	key := u.String()
	if image, ok := d.forgeImages.get(key); ok {
		return image, nil
	}
	ctx, cancel := context.WithTimeout(ctx, forgeImageWait)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, key, nil)
	if err != nil {
		return wire.ForgeImage{}, fmt.Errorf("forge/image: %w", err)
	}
	req.Header.Set("Accept", "image/png, image/jpeg, image/gif, image/webp")
	transport := d.forgeImageTransport
	if transport == nil {
		transport = http.DefaultTransport
	}
	client := &http.Client{
		// Each request, the first and every redirect, gets the token only where its host needs it.
		Transport: forgeImageAuth{d: d, forge: forge, next: transport},
		CheckRedirect: func(next *http.Request, via []*http.Request) error {
			if len(via) >= forgeImageRedirects {
				return errors.New("too many redirects")
			}
			if !forge.allows(next.URL) {
				return fmt.Errorf("a redirect to %s, not a forge's image host", next.URL.Hostname())
			}
			return nil
		},
	}
	res, err := client.Do(req)
	if err != nil {
		return wire.ForgeImage{}, fmt.Errorf("forge/image: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return wire.ForgeImage{}, fmt.Errorf("forge/image: %s", res.Status)
	}
	if res.ContentLength > forgeImageMost {
		return wire.ForgeImage{}, fmt.Errorf("forge/image: the image is more than %d MB", forgeImageMost>>20)
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, forgeImageMost+1))
	if err != nil {
		return wire.ForgeImage{}, fmt.Errorf("forge/image: %w", err)
	}
	if len(data) > forgeImageMost {
		return wire.ForgeImage{}, fmt.Errorf("forge/image: the image is more than %d MB", forgeImageMost>>20)
	}
	// The type is read from the bytes: a server's Content-Type can say image/png for an SVG.
	mime := http.DetectContentType(data)
	if !forgeImageTypes[mime] {
		return wire.ForgeImage{}, fmt.Errorf("forge/image: %s is not a PNG, JPEG, GIF or WebP image", mime)
	}
	image := wire.ForgeImage{MimeType: mime, Data: data}
	d.forgeImages.put(key, image)
	return image, nil
}

// forgeImageAuth is the forge's token on each request whose host needs it, never on another.
type forgeImageAuth struct {
	d     *Daemon
	forge forgeImageHost
	next  http.RoundTripper
}

func (a forgeImageAuth) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	req.Header.Del("Authorization")
	a.forge.authorize(a.d, req)
	return a.next.RoundTrip(req)
}
