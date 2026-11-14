package agentsd

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/connections"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// pngBytes start as a PNG does, so the bytes say image/png.
var pngBytes = append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, 64)...)

// fakeImageWeb answers forge/image's reads by URL and keeps what each request asked and sent.
type fakeImageWeb struct {
	mu      sync.Mutex
	answers map[string]func() *http.Response
	asked   []string // url, then " auth" when the request had a token
}

func (f *fakeImageWeb) RoundTrip(req *http.Request) (*http.Response, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	asked := req.URL.String()
	if a := req.Header.Get("Authorization"); a != "" {
		asked += " auth=" + a
	}
	f.asked = append(f.asked, asked)
	answer, ok := f.answers[req.URL.String()]
	if !ok {
		return &http.Response{StatusCode: http.StatusNotFound, Status: "404 Not Found", Body: io.NopCloser(strings.NewReader("")), Request: req}, nil
	}
	res := answer()
	res.Request = req
	return res, nil
}

func (f *fakeImageWeb) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.asked...)
}

func imageAnswer(contentType string, body []byte) func() *http.Response {
	return func() *http.Response {
		return &http.Response{StatusCode: http.StatusOK, Status: "200 OK", Header: http.Header{"Content-Type": {contentType}},
			Body: io.NopCloser(bytes.NewReader(body)), ContentLength: int64(len(body))}
	}
}

func redirectTo(to string) func() *http.Response {
	return func() *http.Response {
		return &http.Response{StatusCode: http.StatusFound, Status: "302 Found", Header: http.Header{"Location": {to}},
			Body: io.NopCloser(strings.NewReader(""))}
	}
}

func imageDaemon(t *testing.T, answers map[string]func() *http.Response) (*conn, *fakeImageWeb) {
	t.Helper()
	d, c, _, _ := forgeDaemon(t)
	web := &fakeImageWeb{answers: answers}
	d.forgeImageTransport = web
	return c, web
}

// #4009: a GitHub attachment is read with the token on github.com, follows its redirect to the
// signed private-user-images URL with no token, and is given as its bytes, typed from them; the
// same image again asks nothing.
func TestForgeImageReadsAGitHubAttachment(t *testing.T) {
	signed := "https://private-user-images.githubusercontent.com/1/abc.png?jwt=signed"
	c, web := imageDaemon(t, map[string]func() *http.Response{
		"https://github.com/user-attachments/assets/abc": redirectTo(signed),
		signed: imageAnswer("application/octet-stream", pngBytes),
	})
	var image wire.ForgeImage
	for i := range 2 {
		json.Unmarshal(c.call(t, 1+i, "forge/image", wire.ForgeImageRequest{URL: "https://github.com/user-attachments/assets/abc"}), &image)
	}
	if image.MimeType != "image/png" || !bytes.Equal(image.Data, pngBytes) {
		t.Fatalf("image: %s, %d bytes", image.MimeType, len(image.Data))
	}
	asked := web.requests()
	if len(asked) != 2 || asked[0] != "https://github.com/user-attachments/assets/abc auth=Bearer ghu_secret" || asked[1] != signed {
		t.Fatalf("asked %q", asked)
	}
}

// #4522: a pr-shots.sh screenshot, a github.com blob link with raw=true, follows GitHub's
// redirects (blob, then raw, then raw.githubusercontent.com) with the token on each, as a
// private repo needs; a /raw/ link is read too.
func TestForgeImageReadsAGitHubBlobLink(t *testing.T) {
	blob := "https://github.com/alexec/Agents/blob/screenshots/pr-4520/mac-ready.png?raw=true"
	raw := "https://github.com/alexec/Agents/raw/screenshots/pr-4520/mac-ready.png"
	file := "https://raw.githubusercontent.com/alexec/Agents/screenshots/pr-4520/mac-ready.png"
	c, web := imageDaemon(t, map[string]func() *http.Response{
		blob: redirectTo(raw),
		raw:  redirectTo(file),
		file: imageAnswer("image/png", pngBytes),
	})
	var image wire.ForgeImage
	json.Unmarshal(c.call(t, 1, "forge/image", wire.ForgeImageRequest{URL: blob}), &image)
	if image.MimeType != "image/png" || !bytes.Equal(image.Data, pngBytes) {
		t.Fatalf("image: %s, %d bytes", image.MimeType, len(image.Data))
	}
	json.Unmarshal(c.call(t, 2, "forge/image", wire.ForgeImageRequest{URL: raw}), &image)
	if image.MimeType != "image/png" {
		t.Fatalf("raw image: %s", image.MimeType)
	}
	asked := web.requests()
	want := []string{blob, raw, file, raw, file}
	if len(asked) != len(want) {
		t.Fatalf("asked %q", asked)
	}
	for i := range want {
		if asked[i] != want[i]+" auth=Bearer ghu_secret" {
			t.Fatalf("asked %q", asked)
		}
	}
}

// #4522: a blob link without raw=true is GitHub's HTML page, and a repo path with a missing or
// dot segment is not a file; all are refused with no request made.
func TestForgeImageRefusesOtherGitHubRepoPaths(t *testing.T) {
	c, web := imageDaemon(t, nil)
	for i, u := range []string{
		"https://github.com/alexec/Agents/blob/main/x.png",
		"https://github.com/alexec/Agents/blob/main/x.png?raw=1",
		"https://github.com/alexec/Agents/raw/main",
		"https://github.com/alexec/Agents/raw/main/",
		"https://github.com/alexec/Agents/raw//x.png",
		"https://github.com/alexec/Agents/raw/main/../../../x.png",
		"https://github.com/alexec/Agents/raw/main/%2e%2e/x.png",
		"https://github.com/alexec/Agents/tree/main/x.png",
	} {
		if msg := c.callErr(t, 1+i, "forge/image", wire.ForgeImageRequest{URL: u}); msg == "" {
			t.Fatalf("%s: no error", u)
		}
	}
	if asked := web.requests(); len(asked) != 0 {
		t.Fatalf("asked %q", asked)
	}
}

// #4009: a host off the list, a github.com page that is not an image path, plain http and a
// redirect off the list are refused; the first three with no request made.
func TestForgeImageRefusesHostsOffTheList(t *testing.T) {
	c, web := imageDaemon(t, map[string]func() *http.Response{
		"https://github.com/alexec/agents/assets/1/x.png": redirectTo("https://evil.example/x.png"),
		"https://evil.example/x.png":                      imageAnswer("image/png", pngBytes),
	})
	for i, u := range []string{"https://evil.example/x.png", "https://github.com/alexec/agents/issues/1", "http://raw.githubusercontent.com/a/b/c.png",
		"https://raw.githubusercontent.com.evil.example/a.png", "https://raw.githubusercontent.com:8443/a.png", "github.com/user-attachments/assets/abc"} {
		if msg := c.callErr(t, 1+i, "forge/image", wire.ForgeImageRequest{URL: u}); msg == "" {
			t.Fatalf("%s: no error", u)
		}
	}
	if asked := web.requests(); len(asked) != 0 {
		t.Fatalf("asked %q", asked)
	}
	if msg := c.callErr(t, 20, "forge/image", wire.ForgeImageRequest{URL: "https://github.com/alexec/agents/assets/1/x.png"}); !strings.Contains(msg, "evil.example") {
		t.Fatalf("redirect: %q", msg)
	}
	if asked := web.requests(); len(asked) != 1 {
		t.Fatalf("asked %q", asked)
	}
}

// #4009: an SVG is refused, also when its server says it is a PNG; so is an image past the cap,
// whether its length says so or not.
func TestForgeImageRefusesSVGAndBigImages(t *testing.T) {
	svg := []byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`)
	big := append(append([]byte(nil), pngBytes...), make([]byte, forgeImageMost)...)
	c, _ := imageDaemon(t, map[string]func() *http.Response{
		"https://raw.githubusercontent.com/a/b/main/x.svg":   imageAnswer("image/svg+xml", svg),
		"https://raw.githubusercontent.com/a/b/main/y.png":   imageAnswer("image/png", svg),
		"https://raw.githubusercontent.com/a/b/main/big.png": imageAnswer("image/png", big),
		"https://raw.githubusercontent.com/a/b/main/unsaid.png": func() *http.Response {
			r := imageAnswer("image/png", big)()
			r.ContentLength = -1
			return r
		},
	})
	for i, u := range []string{"x.svg", "y.png"} {
		if msg := c.callErr(t, 1+i, "forge/image", wire.ForgeImageRequest{URL: "https://raw.githubusercontent.com/a/b/main/" + u}); !strings.Contains(msg, "not a PNG") {
			t.Fatalf("%s: %q", u, msg)
		}
	}
	for i, u := range []string{"big.png", "unsaid.png"} {
		if msg := c.callErr(t, 10+i, "forge/image", wire.ForgeImageRequest{URL: "https://raw.githubusercontent.com/a/b/main/" + u}); !strings.Contains(msg, "more than 10 MB") {
			t.Fatalf("%s: %q", u, msg)
		}
	}
}

// #4009: the token goes to github.com and raw.githubusercontent.com only, never to the avatars
// or user-images hosts.
func TestForgeImageSendsTheTokenOnlyWhereNeeded(t *testing.T) {
	urls := []string{"https://raw.githubusercontent.com/a/b/main/x.png", "https://avatars.githubusercontent.com/u/1?v=4",
		"https://user-images.githubusercontent.com/1/x.png"}
	answers := map[string]func() *http.Response{}
	for _, u := range urls {
		answers[u] = imageAnswer("image/png", pngBytes)
	}
	c, web := imageDaemon(t, answers)
	for i, u := range urls {
		c.call(t, 1+i, "forge/image", wire.ForgeImageRequest{URL: u})
	}
	asked := web.requests()
	want := []string{urls[0] + " auth=Bearer ghu_secret", urls[1], urls[2]}
	if strings.Join(asked, "\n") != strings.Join(want, "\n") {
		t.Fatalf("asked %q", asked)
	}
}

// #4009: the cache keeps at most forgeImagesKept images, the least recently read going first.
func TestForgeImageCacheIsBounded(t *testing.T) {
	var c forgeImageCache
	for i := range forgeImagesKept + 1 {
		c.put(string(rune('a'+i)), wire.ForgeImage{MimeType: "image/png", Data: []byte{1}})
		if i == 0 {
			continue
		}
		c.get("a") // a stays the most recently read
	}
	if _, ok := c.get("a"); !ok {
		t.Fatal("a went")
	}
	if _, ok := c.get("b"); ok {
		t.Fatal("b stayed")
	}
	if c.order.Len() != forgeImagesKept || c.bytes != forgeImagesKept {
		t.Fatalf("%d kept, %d bytes", c.order.Len(), c.bytes)
	}
	c.put("huge", wire.ForgeImage{Data: make([]byte, forgeImageBytesKept)})
	if c.bytes > forgeImageBytesKept {
		t.Fatalf("%d bytes", c.bytes)
	}
}

// #4363: each forge's avatar hosts are read: GitHub's, Gravatar, Atlassian's (Bitbucket, Jira
// Cloud), Linear's, gitlab.com's and the connected GitLab's, Codeberg's and the connected
// Forgejo's (on http too, its own root), Azure DevOps' and a Jira Data Center's. Only Azure
// DevOps and Jira get a token, each its own; a host or path off the lists asks nothing.
func TestForgeImageReadsEachForgesAvatars(t *testing.T) {
	d, c, _, file := forgeDaemon(t)
	web := &fakeImageWeb{answers: map[string]func() *http.Response{}}
	d.forgeImageTransport = web
	for _, conn := range []connections.Connection{
		{Provider: connections.GitLab, Login: "kim", Access: "gloas-secret", URL: "https://gitlab.acme.test/",
			AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()},
		{Provider: connections.Forgejo, Login: "kim", Access: "forgejo-secret", URL: "http://localhost:3753/", ConnectedAt: time.Now()},
	} {
		if err := file.Put(conn); err != nil {
			t.Fatal(err)
		}
	}
	secrets := filepath.Join(os.Getenv("AGENTS_PERSONAL_HOME"), ".agents-secrets")
	os.MkdirAll(secrets, 0o700)
	os.WriteFile(filepath.Join(secrets, "secrets.env"), []byte("AZURE_DEVOPS_URL=https://dev.azure.com/\nAZURE_DEVOPS_TOKEN=ado\n"+
		"JIRA_URL=https://jira.acme.test/jira\nJIRA_API_TOKEN=pat\n"), 0o600)
	ado := "Basic " + base64.StdEncoding.EncodeToString([]byte(":ado"))
	read := map[string]string{
		"https://avatars.githubusercontent.com/u/1?v=4":                                           "",
		"https://secure.gravatar.com/avatar/abc?s=80&d=identicon":                                 "",
		"https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/u1/48":             "",
		"https://public.linear.app/k/avatar":                                                      "",
		"https://gitlab.com/uploads/-/system/user/avatar/7/avatar.png":                            "",
		"https://gitlab.acme.test/uploads/-/system/user/avatar/7/avatar.png":                      "",
		"https://codeberg.org/avatars/abc":                                                        "",
		"http://localhost:3753/avatar/abc":                                                        "",
		"https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.ZGV2":                    ado,
		"https://acme.visualstudio.com/_api/_common/identityImage?id=1":                           ado,
		"https://jira.acme.test/jira/secure/useravatar?ownerId=kim&avatarId=1":                    "Bearer pat",
		"https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/redirected/48.png": "",
	}
	for u := range read {
		web.answers[u] = imageAnswer("image/png", pngBytes)
	}
	// Atlassian's Gravatar URL falls back to its own host.
	gravatar := "https://secure.gravatar.com/avatar/def?d=https%3A%2F%2Favatar-management--avatars.us-west-2.prod.public.atl-paas.net%2Fredirected%2F48.png"
	web.answers[gravatar] = redirectTo("https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/redirected/48.png")
	n := 0
	for u, auth := range read {
		n++
		c.call(t, n, "forge/image", wire.ForgeImageRequest{URL: u})
		asked := web.requests()
		want := u
		if auth != "" {
			want += " auth=" + auth
		}
		if asked[len(asked)-1] != want {
			t.Fatalf("%s: asked %q", u, asked[len(asked)-1])
		}
	}
	c.call(t, 50, "forge/image", wire.ForgeImageRequest{URL: gravatar})
	before := len(web.requests())
	for i, u := range []string{
		"https://gitlab.acme.test/uploads/-/system/project/avatar/1/a.png", "https://gitlab.other.test/uploads/-/system/user/avatar/7/a.png",
		"http://gitlab.acme.test/uploads/-/system/user/avatar/7/a.png", "https://secure.gravatar.com/other", "https://localhost:3753/avatars/abc",
		"http://localhost:3753/user/abc", "https://codeberg.org/kim", "https://avatar-management--avatars.evil.example/u1/48",
		"https://evil.example/_apis/GraphProfile/MemberAvatars/aad.x", "https://dev.azure.com/acme/_apis/git/repositories",
		"https://jira.other.test/jira/secure/useravatar?ownerId=kim", "https://jira.acme.test/secure/useravatar?ownerId=kim",
		"https://gitlab.com/uploads/-/system/user/avatar/../../x.png",
	} {
		if msg := c.callErr(t, 60+i, "forge/image", wire.ForgeImageRequest{URL: u}); msg == "" {
			t.Errorf("%s: no error", u)
		}
	}
	if asked := web.requests(); len(asked) != before {
		t.Fatalf("asked %q", asked[before:])
	}
}

// #4544: each forge's attachment links are read, with each forge's own token only on the hosts
// that need it, never on the signed URL a redirect goes to: GitLab's uploads (the connected
// GitLab's from its API), Forgejo's and Codeberg's attachments, Bitbucket's images and issue
// attachments, Azure DevOps' work item and pull request attachments, Linear's uploads, and Jira's
// attachments. Every forge in the registry gives its image hosts.
func TestForgeImageReadsEachForgesAttachments(t *testing.T) {
	d, c, _, file := forgeDaemon(t)
	for _, f := range d.forges() {
		if f.Images() == nil {
			t.Errorf("%s gives no image hosts", f.Name())
		}
	}
	web := &fakeImageWeb{answers: map[string]func() *http.Response{}}
	d.forgeImageTransport = web
	for _, conn := range []connections.Connection{
		{Provider: connections.GitLab, Login: "kim", Access: "gloas-secret", URL: "https://gitlab.acme.test/",
			AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()},
		{Provider: connections.Forgejo, Login: "kim", Access: "forgejo-secret", URL: "http://localhost:3753/", ConnectedAt: time.Now()},
		{Provider: connections.Bitbucket, Login: "kim", User: "kim@example.com", Access: "bb-secret", ConnectedAt: time.Now()},
		{Provider: connections.Linear, Login: "kim", Access: "lin-secret", ConnectedAt: time.Now()},
	} {
		if err := file.Put(conn); err != nil {
			t.Fatal(err)
		}
	}
	secrets := filepath.Join(os.Getenv("AGENTS_PERSONAL_HOME"), ".agents-secrets")
	os.MkdirAll(secrets, 0o700)
	os.WriteFile(filepath.Join(secrets, "secrets.env"), []byte("AZURE_DEVOPS_URL=https://dev.azure.com/\nAZURE_DEVOPS_TOKEN=ado\n"+
		"JIRA_URL=https://jira.acme.test/jira\nJIRA_API_TOKEN=pat\n"), 0o600)
	ado := " auth=Basic " + base64.StdEncoding.EncodeToString([]byte(":ado"))
	bb := " auth=Basic " + base64.StdEncoding.EncodeToString([]byte("kim@example.com:bb-secret"))
	secret := "0123456789abcdef0123456789abcdef"
	uuid := "0f8fad5b-d9cb-469f-a165-70867728950e"
	bucket := "https://bbuseruploads.s3.amazonaws.com/abc/shot.png?Signature=signed"
	media := "https://api.media.atlassian.com/file/abc/binary?token=signed"
	// Each link, and what it asks: the URL, then the token it sends.
	read := map[string][]string{
		"https://gitlab.acme.test/-/project/7/uploads/" + secret + "/shot.png": {"https://gitlab.acme.test/api/v4/projects/7/uploads/" + secret + "/shot.png auth=Bearer gloas-secret"},
		"https://gitlab.acme.test/acme/tools/app/uploads/" + secret + "/shot.png": {
			"https://gitlab.acme.test/api/v4/projects/acme%2Ftools%2Fapp/uploads/" + secret + "/shot.png auth=Bearer gloas-secret"},
		"https://gitlab.com/kim/app/uploads/" + secret + "/shot.png":                                  {"https://gitlab.com/kim/app/uploads/" + secret + "/shot.png"},
		"http://localhost:3753/attachments/" + uuid:                                                   {"http://localhost:3753/attachments/" + uuid + " auth=token forgejo-secret"},
		"http://localhost:3753/kim/app/attachments/" + uuid:                                           {"http://localhost:3753/kim/app/attachments/" + uuid + " auth=token forgejo-secret"},
		"https://codeberg.org/attachments/" + uuid:                                                    {"https://codeberg.org/attachments/" + uuid},
		"https://bitbucket.org/repo/aKq8Ep/images/123-shot.png":                                       {"https://bitbucket.org/repo/aKq8Ep/images/123-shot.png" + bb, bucket},
		"https://api.bitbucket.org/2.0/repositories/kim/app/issues/3/attachments/shot.png":            {"https://api.bitbucket.org/2.0/repositories/kim/app/issues/3/attachments/shot.png" + bb},
		"https://dev.azure.com/acme/proj/_apis/wit/attachments/" + uuid + "?fileName=shot.png":        {"https://dev.azure.com/acme/proj/_apis/wit/attachments/" + uuid + "?fileName=shot.png" + ado},
		"https://dev.azure.com/acme/proj/_apis/git/repositories/app/pullRequests/4/attachments/x.png": {"https://dev.azure.com/acme/proj/_apis/git/repositories/app/pullRequests/4/attachments/x.png" + ado},
		"https://uploads.linear.app/org/" + uuid + "/" + uuid:                                         {"https://uploads.linear.app/org/" + uuid + "/" + uuid + " auth=Bearer lin-secret"},
		"https://jira.acme.test/jira/secure/attachment/10001/shot.png":                                {"https://jira.acme.test/jira/secure/attachment/10001/shot.png auth=Bearer pat"},
		"https://jira.acme.test/jira/rest/api/3/attachment/content/10001":                             {"https://jira.acme.test/jira/rest/api/3/attachment/content/10001 auth=Bearer pat", media},
	}
	for _, asks := range read {
		u, _, _ := strings.Cut(asks[len(asks)-1], " auth=")
		web.answers[u] = imageAnswer("image/png", pngBytes)
	}
	web.answers["https://bitbucket.org/repo/aKq8Ep/images/123-shot.png"] = redirectTo(bucket)
	web.answers["https://jira.acme.test/jira/rest/api/3/attachment/content/10001"] = redirectTo(media)
	n := 0
	for u, want := range read {
		n++
		before := len(web.requests())
		var image wire.ForgeImage
		json.Unmarshal(c.call(t, n, "forge/image", wire.ForgeImageRequest{URL: u}), &image)
		if image.MimeType != "image/png" {
			t.Errorf("%s: %s", u, image.MimeType)
		}
		if asked := web.requests()[before:]; strings.Join(asked, "\n") != strings.Join(want, "\n") {
			t.Errorf("%s: asked %q, want %q", u, asked, want)
		}
	}
	before := len(web.requests())
	for i, u := range []string{
		"https://gitlab.acme.test/-/project/x/uploads/" + secret + "/a.png", "https://gitlab.acme.test/acme/app/uploads/0123/a.png",
		"https://gitlab.acme.test/acme/app/-/uploads/" + secret + "/a.png", "https://gitlab.acme.test/acme/../uploads/" + secret + "/a.png",
		"https://gitlab.acme.test/acme/app/uploads/" + secret + "/%2e%2e", "https://gitlab.other.test/acme/app/uploads/" + secret + "/a.png",
		"https://gitlab.com/api/v4/projects/7/uploads/" + secret + "/a.png", "http://gitlab.com/kim/app/uploads/" + secret + "/a.png",
		"http://localhost:3753/attachments/not-a-uuid", "https://codeberg.org/kim/app/attachments/" + uuid + "/x",
		"http://localhost:3753/kim/app/raw/branch/main/x.png", "https://bitbucket.org/kim/app/issues/1",
		"https://bbuseruploads.s3.amazonaws.com.evil.example/x", "https://api.bitbucket.org/2.0/repositories/kim/app/issues/x/attachments/a.png",
		"https://dev.azure.com/acme/proj/_apis/wit/workitems/1", "https://dev.azure.com/acme/proj/_apis/wit/attachments/..",
		"https://evil.example/acme/proj/_apis/wit/attachments/" + uuid, "https://linear.app/acme/issue/ENG-1", "http://uploads.linear.app/a",
		"https://jira.acme.test/jira/secure/attachment/abc/x.png", "https://jira.acme.test/jira/rest/api/2/attachment/10001",
		"https://jira.other.test/jira/secure/attachment/10001/x.png", "https://api.media.atlassian.com/other",
	} {
		if msg := c.callErr(t, 100+i, "forge/image", wire.ForgeImageRequest{URL: u}); msg == "" {
			t.Errorf("%s: no error", u)
		}
	}
	if asked := web.requests(); len(asked) != before {
		t.Fatalf("asked %q", asked[before:])
	}
}
