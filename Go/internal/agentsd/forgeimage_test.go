package agentsd

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/wire"
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
		"https://raw.githubusercontent.com/a/b/main/x.svg": imageAnswer("image/svg+xml", svg),
		"https://raw.githubusercontent.com/a/b/main/y.png": imageAnswer("image/png", svg),
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
