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
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/internal/bitbucketmcp"
	"github.com/alexec/agents/Go/internal/connections"
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
// Each forge gives its own as Forge.Images (#4544).
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

// gitlabImages are a GitLab's images: its user avatars (#4363), and the uploads that an issue, a
// merge request or a comment links (#4544), as /-/project/<id>/uploads/<secret>/<file> or
// /<namespace>/<project>/uploads/<secret>/<file>, on gitlab.com or the connected GitLab's root.
// An avatar is public, so no token goes. GitLab's web route reads an upload only with a session,
// so the connected GitLab's upload is read from its API instead (GitLab 17.4 and later, a Guest
// can), with the token; gitlab.com's, when another GitLab is connected, is read with none, as a
// public project's is.
type gitlabImages struct{}

// gitlabRoot is the connected GitLab's root, or "".
func (d *Daemon) gitlabImageRoot() string {
	if c, ok := d.gitlabConnection(); ok {
		return gitlabmcp.BaseURL(c.URL)
	}
	return ""
}

// rootSegments are u's path segments below root's path, or nil when u is not under it.
func rootSegments(u *url.URL, root string) []string {
	rest, ok := strings.CutPrefix(u.EscapedPath(), strings.TrimSuffix(siteURLPath(root), "/")+"/")
	if !ok {
		return nil
	}
	return strings.Split(rest, "/")
}

// plainSegments says that every segment is set, and none is a dot segment, also when escaped.
func plainSegments(parts []string) bool {
	for _, p := range parts {
		plain, err := url.PathUnescape(p)
		if p == "" || err != nil || plain == "" || plain == "." || plain == ".." || strings.Contains(plain, "/") {
			return false
		}
	}
	return len(parts) > 0
}

// gitlabSecret says that s is an upload's secret: 32 hex digits.
func gitlabSecret(s string) bool {
	if len(s) != 32 {
		return false
	}
	for _, r := range s {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return false
		}
	}
	return true
}

// gitlabUpload is the project of an upload's web link, its id or its escaped path, and the
// upload's secret and file; ok is false when parts are not one.
func gitlabUpload(parts []string) (project, secret, file string, ok bool) {
	n := len(parts)
	if n < 5 || parts[n-3] != "uploads" || !gitlabSecret(parts[n-2]) || !plainSegments(parts[n-1:]) {
		return "", "", "", false
	}
	secret, file = parts[n-2], parts[n-1]
	// /-/project/<id>/uploads/<secret>/<file>
	if parts[0] == "-" {
		if n != 6 || parts[1] != "project" || strings.Trim(parts[2], "0123456789") != "" || parts[2] == "" {
			return "", "", "", false
		}
		return parts[2], secret, file, true
	}
	// /<namespace>/<project>/uploads/<secret>/<file>: no "-", which starts GitLab's own routes,
	// and not under /api/, a name GitLab keeps for itself.
	space := parts[:n-3]
	if !plainSegments(space) || slices.Contains(space, "-") || space[0] == "api" {
		return "", "", "", false
	}
	plain := make([]string, len(space))
	for i, p := range space {
		plain[i], _ = url.PathUnescape(p)
	}
	return url.PathEscape(strings.Join(plain, "/")), secret, file, true
}

// gitlabAPIUpload says that parts are /api/v4/projects/<project>/uploads/<secret>/<file>.
func gitlabAPIUpload(parts []string) bool {
	return len(parts) == 7 && parts[0] == "api" && parts[1] == "v4" && parts[2] == "projects" && gitlabProject(parts[3]) &&
		parts[4] == "uploads" && gitlabSecret(parts[5]) && plainSegments(parts[6:])
}

// gitlabProject says that p is a project's id, or its path with each "/" escaped.
func gitlabProject(p string) bool {
	plain, err := url.PathUnescape(p)
	return err == nil && !strings.Contains(p, "/") && plainSegments(strings.Split(plain, "/"))
}

func (gitlabImages) allows(d *Daemon, u *url.URL) bool {
	if publicHost(u) == "gitlab.com" {
		if pathUnder(u, "/uploads/-/system/user/avatar/") {
			return true
		}
		if _, _, _, ok := gitlabUpload(rootSegments(u, gitlabmcp.DefaultBase)); ok {
			return true
		}
	}
	root := d.gitlabImageRoot()
	if root == "" || !onRoot(u, root) {
		return false
	}
	if pathUnder(u, strings.TrimSuffix(siteURLPath(root), "/")+"/uploads/-/system/user/avatar/") {
		return true
	}
	parts := rootSegments(u, root)
	_, _, _, upload := gitlabUpload(parts)
	return upload || gitlabAPIUpload(parts)
}

// source is the connected GitLab's API URL of an upload on its root; any other URL as it is.
func (gitlabImages) source(d *Daemon, u *url.URL) *url.URL {
	root := d.gitlabImageRoot()
	if root == "" || !onRoot(u, root) {
		return u
	}
	project, secret, file, ok := gitlabUpload(rootSegments(u, root))
	if !ok {
		return u
	}
	api := *u
	prefix := strings.TrimSuffix(siteURLPath(root), "/") + "/api/v4/projects/"
	api.RawPath = prefix + project + "/uploads/" + secret + "/" + file
	api.Path, _ = url.PathUnescape(api.RawPath)
	api.RawQuery, api.Fragment = "", ""
	return &api
}

// authorize sends the connected GitLab's token to its API's uploads, and nowhere else.
func (gitlabImages) authorize(d *Daemon, req *http.Request) {
	root := d.gitlabImageRoot()
	if root == "" || !onRoot(req.URL, root) || !gitlabAPIUpload(rootSegments(req.URL, root)) {
		return
	}
	if c, ok := d.gitlabConnection(); ok && c.Usable(nowFunc()) && c.Access != "" {
		req.Header.Set("Authorization", "Bearer "+c.Access)
	}
}

// forgejoImages are a Forgejo's images on Codeberg or the connected Forgejo's own root: its
// avatars (#4363; /avatars/ are uploaded, /avatar/ made from the e-mail), which are public, and
// the attachments an issue, a pull request or a comment links (#4544), /attachments/<uuid> or
// /<owner>/<repo>/attachments/<uuid>. Forgejo takes a token on an attachment's web route, so the
// connected Forgejo's token goes to its attachments, and nowhere else.
type forgejoImages struct{}

// forgejoImageRoot is the connected Forgejo's root, or "".
func (d *Daemon) forgejoImageRoot() string {
	if c, ok := d.forgejoConnection(); ok {
		return forgejomcp.BaseURL(c.URL)
	}
	return ""
}

// forgejoAttachment says that parts are attachments/<uuid> or <owner>/<repo>/attachments/<uuid>.
func forgejoAttachment(parts []string) bool {
	if !plainSegments(parts) {
		return false
	}
	switch {
	case len(parts) == 2 && parts[0] == "attachments":
	case len(parts) == 4 && parts[2] == "attachments":
	default:
		return false
	}
	id := parts[len(parts)-1]
	return len(id) == 36 && strings.Trim(id, "0123456789abcdef-") == ""
}

// forgejoAvatar says that parts are avatars/<…> or avatar/<…>.
func forgejoAvatar(parts []string) bool {
	return len(parts) >= 2 && (parts[0] == "avatars" || parts[0] == "avatar") && plainSegments(parts[1:])
}

func (forgejoImages) allows(d *Daemon, u *url.URL) bool {
	if publicHost(u) == "codeberg.org" {
		parts := rootSegments(u, forgejomcp.DefaultBase)
		return forgejoAvatar(parts) || forgejoAttachment(parts)
	}
	root := d.forgejoImageRoot()
	if root == "" || !onRoot(u, root) {
		return false
	}
	parts := rootSegments(u, root)
	return forgejoAvatar(parts) || forgejoAttachment(parts)
}

func (forgejoImages) authorize(d *Daemon, req *http.Request) {
	root := d.forgejoImageRoot()
	if root == "" || !onRoot(req.URL, root) || !forgejoAttachment(rootSegments(req.URL, root)) {
		return
	}
	if c, ok := d.forgejoConnection(); ok && c.Usable(nowFunc()) && c.Access != "" {
		req.Header.Set("Authorization", "token "+c.Access)
	}
}

// bitbucketImages are Bitbucket Cloud's attachments (#4544): an image in an issue's, a pull
// request's or a comment's words, bitbucket.org/repo/<id>/images/<file>, and an issue's
// attachment from the API, /2.0/repositories/<workspace>/<repo>/issues/<n>/attachments/<file>.
// Both redirect to a signed URL on Bitbucket's upload bucket, which takes no token. Bitbucket's
// avatars are on publicAvatars' hosts.
type bitbucketImages struct{}

// bitbucketUploads is the bucket Bitbucket Cloud's attachments redirect to.
const bitbucketUploads = "bbuseruploads.s3.amazonaws.com"

// bitbucketNeedsToken says that u is a Bitbucket Cloud attachment that is read with the token.
func bitbucketNeedsToken(u *url.URL) bool {
	switch publicHost(u) {
	case "bitbucket.org":
		parts := rootSegments(u, "https://bitbucket.org/")
		return len(parts) == 4 && parts[0] == "repo" && parts[2] == "images" && plainSegments(parts)
	case "api.bitbucket.org":
		parts := rootSegments(u, bitbucketmcp.DefaultBase)
		return len(parts) == 7 && parts[0] == "repositories" && parts[3] == "issues" && strings.Trim(parts[4], "0123456789") == "" &&
			parts[5] == "attachments" && plainSegments(parts)
	}
	return false
}

func (bitbucketImages) allows(_ *Daemon, u *url.URL) bool {
	if publicHost(u) == bitbucketUploads {
		return pathUnder(u, "/")
	}
	return bitbucketNeedsToken(u)
}

// authorize sends the Bitbucket connection's token as its API takes it: with its e-mail, an API
// token; without, an OAuth token.
func (bitbucketImages) authorize(d *Daemon, req *http.Request) {
	if !bitbucketNeedsToken(req.URL) {
		return
	}
	c, ok := d.bitbucketConnection()
	if !ok || !c.Usable(nowFunc()) || c.Access == "" {
		return
	}
	if email := strings.TrimSpace(c.User); email != "" {
		req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(email+":"+c.Access)))
	} else {
		req.Header.Set("Authorization", "Bearer "+c.Access)
	}
}

// azureImages are Azure DevOps' images, for Azure Repos and Azure Boards, on dev.azure.com, an
// organization's visualstudio.com, or the connected Azure DevOps Server: an identity's picture
// (#4363), /<organization>/_apis/GraphProfile/MemberAvatars/<descriptor> or
// _api/_common/identityImage; a work item's attachment (#4544), …/_apis/wit/attachments/<id>; and
// a pull request's, …/_apis/git/repositories/<repo>/pullRequests/<n>/attachments/<file>. Each
// needs the token, as the API does.
type azureImages struct{}

func azureImagePath(u *url.URL) bool {
	if strings.Contains(u.Path, "/_apis/GraphProfile/MemberAvatars/") || strings.HasSuffix(u.Path, "/_api/_common/identityImage") {
		return true
	}
	parts := strings.Split(strings.TrimPrefix(u.EscapedPath(), "/"), "/")
	at := slices.Index(parts, "_apis")
	if at < 0 || !plainSegments(parts) {
		return false
	}
	rest := parts[at+1:]
	switch {
	case len(rest) == 3 && rest[0] == "wit" && rest[1] == "attachments":
		return true
	case len(rest) == 7 && rest[0] == "git" && rest[1] == "repositories" && rest[3] == "pullRequests" && rest[5] == "attachments":
		return strings.Trim(rest[4], "0123456789") == ""
	}
	return false
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

// linearImages are Linear's uploads (#4544): an image in an issue's or a comment's words, on
// uploads.linear.app, which takes the connection's token. Linear's avatars are on publicAvatars'
// hosts.
type linearImages struct{}

func (linearImages) allows(_ *Daemon, u *url.URL) bool {
	return publicHost(u) == "uploads.linear.app" && pathUnder(u, "/")
}

func (linearImages) authorize(d *Daemon, req *http.Request) {
	if publicHost(req.URL) != "uploads.linear.app" {
		return
	}
	s, err := d.connectionStore()
	if err != nil {
		return
	}
	// The connection's token is OAuth's, which says Bearer.
	if c, ok, err := s.Get(connections.Linear); err == nil && ok && c.Usable(nowFunc()) && c.Access != "" {
		req.Header.Set("Authorization", "Bearer "+c.Access)
	}
}

// jiraImages are Jira's images on the signed-in site, with its sign-in: Jira Data Center's
// avatars, /secure/useravatar (#4363; Jira Cloud's are on Atlassian's avatar host, publicAvatars),
// and an issue's attachments (#4544): /secure/attachment/<id>/<file> and /secure/thumbnail/<id>/<file>,
// as Jira renders them, and /rest/api/<2|3>/attachment/<content|thumbnail>/<id>. Jira Cloud
// redirects an attachment to a signed URL on Atlassian's media host, which takes no token.
type jiraImages struct{}

// jiraMedia is the host Jira Cloud's attachments redirect to.
const jiraMedia = "api.media.atlassian.com"

// jiraImagePath says that parts, below the site's root, are one of Jira's image paths.
func jiraImagePath(parts []string) bool {
	switch {
	case len(parts) == 2 && parts[0] == "secure" && parts[1] == "useravatar":
		return true
	case len(parts) == 4 && parts[0] == "secure" && (parts[1] == "attachment" || parts[1] == "thumbnail"):
		return strings.Trim(parts[2], "0123456789") == "" && plainSegments(parts)
	case len(parts) == 6 && parts[0] == "rest" && parts[1] == "api" && (parts[2] == "2" || parts[2] == "3") && parts[3] == "attachment" &&
		(parts[4] == "content" || parts[4] == "thumbnail"):
		return parts[5] != "" && strings.Trim(parts[5], "0123456789") == ""
	}
	return false
}

func (d *Daemon) jiraImageAuth(u *url.URL) (jiramcp.Auth, bool) {
	secrets := d.secrets()
	auth := jiramcp.TokenAuth(secrets["JIRA_URL"], secrets["JIRA_EMAIL"], secrets["JIRA_API_TOKEN"])
	ok := auth.Site != "" && auth.Header != "" && onRoot(u, auth.Site) && jiraImagePath(rootSegments(u, auth.Site))
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
	if publicHost(u) == jiraMedia {
		return pathUnder(u, "/file/")
	}
	_, ok := d.jiraImageAuth(u)
	return ok
}

func (jiraImages) authorize(d *Daemon, req *http.Request) {
	if auth, ok := d.jiraImageAuth(req.URL); ok {
		req.Header.Set("Authorization", auth.Header)
	}
}

// forgeImageSource is a forge whose image is read from another URL than the one a page links:
// GitLab's upload, from its API. The URL it gives is checked as a redirect is.
type forgeImageSource interface {
	source(d *Daemon, u *url.URL) *url.URL
}

// forgeImageHosts are the hosts whose images are read: the shared avatar hosts, then each
// forge's own (Forge.Images), in the registry's order, GitHub first.
func (d *Daemon) forgeImageHosts() []forgeImageHost {
	hosts := []forgeImageHost{publicAvatars{}}
	for _, f := range d.forges() {
		if h := f.Images(); h != nil {
			hosts = append(hosts, h)
		}
	}
	return hosts
}

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
	for _, h := range d.forgeImageHosts() {
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
	read := u
	if s, ok := forge.(forgeImageSource); ok {
		if read = s.source(d, u); !forge.allows(d, read) {
			return wire.ForgeImage{}, fmt.Errorf("forge/image: %s is not a forge's image host", read.Hostname())
		}
	}
	ctx, cancel := context.WithTimeout(ctx, forgeImageWait)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, read.String(), nil)
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
