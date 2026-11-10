package agentsd

import (
	"container/list"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/internal/forgejomcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/internal/jiramcp"
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
	// d says which GitLab, Forgejo, Azure DevOps or Jira is connected: a self-hosted one's own root.
	allows(d *Daemon, u *url.URL) bool
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

// publicHost is u's host, in lower case, when u is https on the default port with no user; else "".
func publicHost(u *url.URL) string {
	if u.Scheme != "https" || u.User != nil || u.Port() != "" {
		return ""
	}
	return strings.ToLower(u.Hostname())
}

// onRoot says that u is on the root of a self-hosted forge: its scheme, host and port, with no
// user. A local Forgejo can be on http.
func onRoot(u *url.URL, root string) bool {
	r, err := url.Parse(root)
	if err != nil || r.Host == "" || u.User != nil {
		return false
	}
	return strings.EqualFold(u.Scheme, r.Scheme) && strings.EqualFold(u.Host, r.Host)
}

// pathUnder says that u's path is prefix and at least one more segment, with no dot segment.
func pathUnder(u *url.URL, prefix string) bool {
	rest, ok := strings.CutPrefix(u.Path, prefix)
	if !ok || rest == "" {
		return false
	}
	for _, p := range strings.Split(rest, "/") {
		if p == "." || p == ".." {
			return false
		}
	}
	return true
}

func (githubImages) allows(_ *Daemon, u *url.URL) bool {
	host := publicHost(u)
	if host == "" {
		return false
	}
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

// publicAvatars are the avatar hosts that need no token, for every forge that gives them (#4363):
// Gravatar (GitLab, Forgejo, Bitbucket and Jira Cloud can give one), Atlassian's avatar host
// (Bitbucket's and Jira Cloud's), and Linear's public uploads. They are one host, not one per
// forge, because Atlassian's Gravatar URL names Atlassian's host as its default, and a redirect
// goes only to a host of the same list.
type publicAvatars struct{}

func (publicAvatars) allows(_ *Daemon, u *url.URL) bool {
	switch host := publicHost(u); {
	case host == "secure.gravatar.com" || host == "www.gravatar.com":
		return pathUnder(u, "/avatar/")
	case strings.HasPrefix(host, "avatar-management--avatars.") && strings.HasSuffix(host, ".prod.public.atl-paas.net"):
		return pathUnder(u, "/")
	case host == "public.linear.app":
		return pathUnder(u, "/")
	}
	return false
}

func (publicAvatars) authorize(*Daemon, *http.Request) {}

// gitlabImages are a GitLab's user avatars (#4363): gitlab.com's, and the connected GitLab's on
// its own root. An avatar is public, so no token goes.
type gitlabImages struct{}

func (gitlabImages) allows(d *Daemon, u *url.URL) bool {
	if !pathUnder(u, "/uploads/-/system/user/avatar/") {
		return false
	}
	if publicHost(u) == "gitlab.com" {
		return true
	}
	c, ok := d.gitlabConnection()
	return ok && c.URL != "" && onRoot(u, gitlabmcp.BaseURL(c.URL))
}

func (gitlabImages) authorize(*Daemon, *http.Request) {}

// forgejoImages are a Forgejo's avatars (#4363): Codeberg's, and the connected Forgejo's on its
// own root; /avatars/ are uploaded, /avatar/ made from the e-mail. They are public: no token goes.
type forgejoImages struct{}

func (forgejoImages) allows(d *Daemon, u *url.URL) bool {
	if !pathUnder(u, "/avatars/") && !pathUnder(u, "/avatar/") {
		return false
	}
	if publicHost(u) == "codeberg.org" {
		return true
	}
	c, ok := d.forgejoConnection()
	return ok && c.URL != "" && onRoot(u, forgejomcp.BaseURL(c.URL))
}

func (forgejoImages) authorize(*Daemon, *http.Request) {}

// azureImages are an Azure DevOps identity's picture (#4363), for Azure Repos and Azure Boards:
// /<organization>/_apis/GraphProfile/MemberAvatars/<descriptor> or _api/_common/identityImage, on
// dev.azure.com, an organization's visualstudio.com, or the connected Azure DevOps Server. It
// needs the token, as the API does.
type azureImages struct{}

func azureImagePath(u *url.URL) bool {
	return strings.Contains(u.Path, "/_apis/GraphProfile/MemberAvatars/") || strings.HasSuffix(u.Path, "/_api/_common/identityImage")
}

// azureImageRoot is the root of the Azure DevOps that u is on, or "".
func (d *Daemon) azureImageRoot(u *url.URL) string {
	host := publicHost(u)
	if host == "dev.azure.com" || strings.HasSuffix(host, ".visualstudio.com") {
		return azuredevopsmcp.DefaultBase
	}
	_, boards := d.azureBoardsSignIn()
	for _, root := range append(d.azureDevOpsRoots(), azuredevopsmcp.BaseURL(boards)) {
		if onRoot(u, root) {
			return root
		}
	}
	return ""
}

func (azureImages) allows(d *Daemon, u *url.URL) bool {
	return azureImagePath(u) && d.azureImageRoot(u) != ""
}

// authorize sends the token for the Azure DevOps the image is on: Azure Repos', else Azure Boards'.
func (azureImages) authorize(d *Daemon, req *http.Request) {
	root := d.azureImageRoot(req.URL)
	if root == "" || !azureImagePath(req.URL) {
		return
	}
	token := d.azureDevOpsToken(root)
	if token == "" {
		if t, base := d.azureBoardsSignIn(); azuredevopsmcp.BaseURL(base) == root {
			token = t
		}
	}
	if token != "" {
		req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(":"+token)))
	}
}

// jiraImages are Jira Data Center's avatars, on the signed-in site's /secure/useravatar (#4363),
// with its sign-in; Jira Cloud's are on Atlassian's avatar host (publicAvatars).
type jiraImages struct{}

func (d *Daemon) jiraImageAuth(u *url.URL) (jiramcp.Auth, bool) {
	secrets := d.secrets()
	auth := jiramcp.TokenAuth(secrets["JIRA_URL"], secrets["JIRA_EMAIL"], secrets["JIRA_API_TOKEN"])
	ok := auth.Site != "" && auth.Header != "" && onRoot(u, auth.Site) && u.Path == strings.TrimSuffix(siteURLPath(auth.Site), "/")+"/secure/useravatar"
	return auth, ok
}

// siteURLPath is the path of a site's root: a Jira Data Center can be under a context path.
func siteURLPath(site string) string {
	if u, err := url.Parse(site); err == nil {
		return u.Path
	}
	return ""
}

func (jiraImages) allows(d *Daemon, u *url.URL) bool {
	_, ok := d.jiraImageAuth(u)
	return ok
}

func (jiraImages) authorize(d *Daemon, req *http.Request) {
	if auth, ok := d.jiraImageAuth(req.URL); ok {
		req.Header.Set("Authorization", auth.Header)
	}
}

// forgeImageHosts are the forges whose images are read, GitHub first. Bitbucket's and Linear's
// avatars are on publicAvatars' hosts.
var forgeImageHosts = []forgeImageHost{githubImages{}, publicAvatars{}, gitlabImages{}, forgejoImages{}, azureImages{}, jiraImages{}}

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
func (d *Daemon) forgeImageOf(u *url.URL) forgeImageHost {
	for _, h := range forgeImageHosts {
		if h.allows(d, u) {
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
	forge := d.forgeImageOf(u)
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
			if !forge.allows(d, next.URL) {
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
