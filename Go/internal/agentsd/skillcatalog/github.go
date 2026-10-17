package skillcatalog

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/alexec/agents/Go/wire"
)

// Endpoints is where the catalogue and GitHub are (CatalogEndpoints). A walk points all of
// GitHub at one fixture server with AGENTS_TEST_GITHUB_URL (its hosts under /api, /raw and
// /codeload) and skills.sh at one with AGENTS_TEST_CATALOG_URL; then the person's gh is
// never used.
type Endpoints struct {
	Catalog, Web, API, Raw, Codeload string
}

var Live = Endpoints{Catalog: "https://skills.sh", Web: "https://github.com", API: "https://api.github.com",
	Raw: "https://raw.githubusercontent.com", Codeload: "https://codeload.github.com"}

const (
	CatalogVariable = "AGENTS_TEST_CATALOG_URL"
	GitHubVariable  = "AGENTS_TEST_GITHUB_URL"
)

func EndpointsFrom(env func(string) string) Endpoints {
	e := Live
	if s := env(CatalogVariable); s != "" {
		e.Catalog = strings.TrimSuffix(s, "/")
	}
	if s := env(GitHubVariable); s != "" {
		s = strings.TrimSuffix(s, "/")
		e.Web, e.API, e.Raw, e.Codeload = s, s+"/api", s+"/raw", s+"/codeload"
	}
	return e
}

// IsLive is whether these are the real services, the only time gh may be used.
func (e Endpoints) IsLive() bool { return e == Live }

var knownOwners = map[string]bool{"anthropics": true, "openai": true, "google": true, "google-gemini": true,
	"github": true, "microsoft": true, "vercel": true, "vercel-labs": true, "apple": true, "expo": true,
	"figma": true, "stripe": true, "supabase": true, "cloudflare": true}

// KnownOwner is whether a result carries the known mark: a mark, never a gate.
func KnownOwner(owner string) bool { return knownOwners[strings.ToLower(owner)] }

// GH is the person's own gh, which GitHub is read through when it is signed in, for the
// higher hourly limit and private repositories; nil where it must not be used.
type GH func(ctx context.Context, path string) ([]byte, error)

// GitHub is a skill's repository read without git and, where it can be, without the API
// (GitHubSource): the commit from git's ref list, the file list from the API's tree, a
// file's bytes from raw.githubusercontent.com, and the commit's tarball when the API's
// limit is spent.
type GitHub struct {
	Client    *http.Client
	Endpoints Endpoints
	GH        GH
}

const (
	Timeout      = 10 * time.Second
	tarballLimit = 50 << 20
)

// Head is the default branch's commit.
type Head struct {
	Commit, Branch string
	// SignedIn is a head read through gh because the plain read was refused: its files
	// come that way too.
	SignedIn bool
}

// TreeEntry is one entry of the API's tree.
type TreeEntry struct {
	Path string `json:"path"`
	Mode string `json:"mode"`
	Type string `json:"type"`
	SHA  string `json:"sha"`
	Size *int64 `json:"size,omitempty"`
}

// ErrRateLimited is the API's hourly limit spent.
var ErrRateLimited = errors.New("rate limited")

func (g GitHub) gh() GH {
	if g.Endpoints.IsLive() {
		return g.GH
	}
	return nil
}

// Head is from info/refs?service=git-upload-pack; for a private repository, which refuses
// that read, from the API through gh.
func (g GitHub) Head(ctx context.Context, owner, repo string) (Head, error) {
	u := g.Endpoints.Web + "/" + owner + "/" + repo + ".git/info/refs?service=git-upload-pack"
	if b, err := g.get(ctx, u, false); err == nil {
		if h, ok := ParseRefs(b); ok {
			return h, nil
		}
	}
	if h, ok := g.signedInHead(ctx, owner, repo); ok {
		return h, nil
	}
	return Head{}, Unreachable(host(g.Endpoints.Web))
}

func (g GitHub) signedInHead(ctx context.Context, owner, repo string) (Head, bool) {
	gh := g.gh()
	if gh == nil {
		return Head{}, false
	}
	b, err := gh(ctx, "repos/"+owner+"/"+repo)
	var r struct {
		DefaultBranch string `json:"default_branch"`
	}
	if err != nil || json.Unmarshal(b, &r) != nil || r.DefaultBranch == "" {
		return Head{}, false
	}
	b, err = gh(ctx, "repos/"+owner+"/"+repo+"/git/ref/heads/"+r.DefaultBranch)
	var ref struct {
		Object struct {
			SHA string `json:"sha"`
		} `json:"object"`
	}
	if err != nil || json.Unmarshal(b, &ref) != nil || !isSHA(ref.Object.SHA) {
		return Head{}, false
	}
	return Head{Commit: strings.ToLower(ref.Object.SHA), Branch: r.DefaultBranch, SignedIn: true}, true
}

// ParseRefs reads pkt-line text: the first ref line is "<sha> HEAD\0<capabilities>", and
// the capabilities name the branch as symref=HEAD:refs/heads/<branch>.
func ParseRefs(b []byte) (Head, bool) {
	for _, line := range strings.Split(string(b), "\n") {
		i := strings.Index(line, " HEAD")
		if i < 40 {
			continue
		}
		sha := line[i-40 : i]
		if !isSHA(sha) {
			continue
		}
		h := Head{Commit: strings.ToLower(sha)}
		if j := strings.Index(line, "symref=HEAD:refs/heads/"); j >= 0 {
			rest := line[j+len("symref=HEAD:refs/heads/"):]
			if k := strings.IndexAny(rest, " \x00\n"); k >= 0 {
				rest = rest[:k]
			}
			h.Branch = rest
		}
		return h, true
	}
	return Head{}, false
}

func isSHA(s string) bool {
	if len(s) != 40 {
		return false
	}
	for _, r := range s {
		if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
			return false
		}
	}
	return true
}

// Tree is every blob and folder in the repository at commit.
func (g GitHub) Tree(ctx context.Context, owner, repo, commit string) ([]TreeEntry, error) {
	var answer struct {
		Tree []TreeEntry `json:"tree"`
	}
	path := "repos/" + owner + "/" + repo + "/git/trees/" + commit
	if gh := g.gh(); gh != nil {
		if b, err := gh(ctx, path+"?recursive=1"); err == nil && json.Unmarshal(b, &answer) == nil {
			return answer.Tree, nil
		}
	}
	b, err := g.get(ctx, g.Endpoints.API+"/"+path+"?recursive=1", true)
	if err != nil {
		return nil, err
	}
	if json.Unmarshal(b, &answer) != nil {
		return nil, Unreachable(host(g.Endpoints.API))
	}
	return answer.Tree, nil
}

// Raw is one file at commit; for a repository whose head came through gh, its blob
// through gh.
func (g GitHub) Raw(ctx context.Context, owner, repo, commit, path, blob string, signedIn bool) ([]byte, error) {
	if gh := g.gh(); signedIn && gh != nil && blob != "" {
		b, err := gh(ctx, "repos/"+owner+"/"+repo+"/git/blobs/"+blob)
		var answer struct {
			Content  string `json:"content"`
			Encoding string `json:"encoding"`
		}
		if err != nil || json.Unmarshal(b, &answer) != nil || answer.Encoding != "base64" {
			return nil, Unreachable("github.com")
		}
		data, err := base64.StdEncoding.DecodeString(strings.NewReplacer("\n", "", "\r", "").Replace(answer.Content))
		if err != nil {
			return nil, Unreachable("github.com")
		}
		return data, nil
	}
	return g.get(ctx, g.Endpoints.Raw+"/"+owner+"/"+repo+"/"+commit+"/"+path, false)
}

// CommitDate is when the skill's folder last changed, for "Taken at": only through gh,
// since anonymously it would spend a second request of sixty.
func (g GitHub) CommitDate(ctx context.Context, owner, repo, commit, folder string) *time.Time {
	gh := g.gh()
	if gh == nil {
		return nil
	}
	b, err := gh(ctx, "repos/"+owner+"/"+repo+"/commits?path="+url.QueryEscape(folder)+"&sha="+commit+"&per_page=1")
	var list []struct {
		Commit struct {
			Committer struct {
				Date string `json:"date"`
			} `json:"committer"`
		} `json:"commit"`
	}
	if err != nil || json.Unmarshal(b, &list) != nil || len(list) == 0 {
		return nil
	}
	t, err := time.Parse(time.RFC3339, list[0].Commit.Committer.Date)
	if err != nil {
		return nil
	}
	return &t
}

// TarballTree is the rate-limit fallback: the commit's tarball, unpacked into work, and its
// tree read back off the files in the API's shape. Refused over 50 MB; links are listed as
// 120000 so they are skipped where the API's would be.
func (g GitHub) TarballTree(ctx context.Context, owner, repo, commit, work string) (string, []TreeEntry, error) {
	b, err := g.get(ctx, g.Endpoints.Codeload+"/"+owner+"/"+repo+"/tar.gz/"+commit, false)
	if err != nil {
		return "", nil, err
	}
	if len(b) > tarballLimit {
		return "", nil, CannotAdd([]wire.PreviewProblem{{TooLarge: &wire.PreviewProblemTooLarge{Bytes: int64(len(b))}}})
	}
	unpacked := filepath.Join(work, "unpacked")
	if err := untar(b, unpacked); err != nil {
		return "", nil, Unreachable(host(g.Endpoints.Codeload))
	}
	root := filepath.Join(unpacked, repo+"-"+commit)
	var tree []TreeEntry
	filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || path == root {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		zero := int64(0)
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			tree = append(tree, TreeEntry{Path: rel, Mode: "120000", Type: "blob", Size: &zero})
		case info.IsDir():
			tree = append(tree, TreeEntry{Path: rel, Mode: "040000", Type: "tree"})
		case info.Mode().IsRegular():
			data, err := os.ReadFile(path)
			if err != nil {
				return nil
			}
			mode := "100644"
			if info.Mode()&0o111 != 0 {
				mode = "100755"
			}
			size := int64(len(data))
			tree = append(tree, TreeEntry{Path: rel, Mode: mode, Type: "blob", SHA: BlobSHA(data), Size: &size})
		}
		return nil
	})
	return root, tree, nil
}

// untar unpacks a .tar.gz, every entry kept inside dir.
func untar(b []byte, dir string) error {
	z, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return err
	}
	r := tar.NewReader(z)
	for {
		h, err := r.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if !IsSafe(strings.TrimSuffix(h.Name, "/")) {
			continue
		}
		path := filepath.Join(dir, h.Name)
		switch h.Typeflag {
		case tar.TypeDir:
			os.MkdirAll(path, 0o755)
		case tar.TypeReg:
			os.MkdirAll(filepath.Dir(path), 0o755)
			mode := os.FileMode(0o644)
			if h.Mode&0o111 != 0 {
				mode = 0o755
			}
			f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
			if err != nil {
				return err
			}
			_, err = io.Copy(f, io.LimitReader(r, tarballLimit))
			f.Close()
			if err != nil {
				return err
			}
		case tar.TypeSymlink:
			os.MkdirAll(filepath.Dir(path), 0o755)
			os.Symlink(h.Linkname, path)
		}
	}
}

func (g GitHub) get(ctx context.Context, u string, api bool) ([]byte, error) {
	return get(ctx, g.Client, u, api)
}

func get(ctx context.Context, client *http.Client, u string, api bool) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, Unreachable(host(u))
	}
	req.Header.Set("User-Agent", "agents-app")
	if api {
		req.Header.Set("Accept", "application/vnd.github+json")
	}
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, Unreachable(host(u))
	}
	defer resp.Body.Close()
	if api && (resp.StatusCode == 429 || resp.StatusCode == 403 && resp.Header.Get("x-ratelimit-remaining") == "0") {
		return nil, ErrRateLimited
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, Unreachable(host(u))
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, tarballLimit+1))
	if err != nil {
		return nil, Unreachable(host(u))
	}
	return b, nil
}

func host(u string) string {
	if p, err := url.Parse(u); err == nil && p.Host != "" {
		return p.Hostname()
	}
	return u
}

// GitHubSource is owner/repo and nothing else: no scheme, no host, two plain parts,
// neither . nor ... It goes into URL paths, so a catalogue row must not steer one.
func GitHubSource(source string) (string, string, bool) {
	parts := strings.Split(source, "/")
	if len(parts) != 2 || strings.Contains(source, ":") {
		return "", "", false
	}
	for _, p := range parts {
		if !plainName(p) {
			return "", "", false
		}
	}
	return parts[0], parts[1], true
}

// plainName is letters, digits, - _ and ., and not . or ...
func plainName(p string) bool {
	if p == "" || p == "." || p == ".." {
		return false
	}
	for _, r := range p {
		if !(unicode.IsLetter(r) || unicode.IsNumber(r) || strings.ContainsRune("-_.", r)) {
			return false
		}
	}
	return true
}
