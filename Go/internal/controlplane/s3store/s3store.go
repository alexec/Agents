// Package s3store is S3Store.swift: a store in an S3-compatible bucket (058,
// contracts/store.md rule 6). It sends plain HTTPS signed with AWS Signature V4. Every
// change is a conditional put. Path-style addressing is for MinIO.
//
// It uses only the standard library, as the Swift signer used no SDK.
package s3store

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Credentials are the bucket's keys. SessionToken is for temporary keys, and may be
// empty.
type Credentials struct {
	AccessKey    string
	SecretKey    string
	SessionToken string
}

// Location is where the store is.
type Location struct {
	// Endpoint is https://s3.eu-west-2.amazonaws.com, or MinIO's http://127.0.0.1:9000.
	Endpoint *url.URL
	Bucket   string
	// Prefix has no slash at either end. It is empty for the top of the bucket.
	Prefix string
	Region string
	// PathStyle is https://endpoint/bucket/key, not https://bucket.endpoint/key.
	PathStyle bool
}

// NewLocation trims the slashes from the prefix. An empty region is us-east-1.
func NewLocation(endpoint *url.URL, bucket, prefix, region string, pathStyle bool) Location {
	if region == "" {
		region = "us-east-1"
	}
	return Location{Endpoint: endpoint, Bucket: bucket, Prefix: strings.Trim(prefix, "/"),
		Region: region, PathStyle: pathStyle}
}

// ParseLocation reads s3://bucket/prefix. The endpoint, the region and the addressing
// come from the environment (contracts/store.md "Configuration"). It returns false when
// the text is not such a URL.
func ParseLocation(text string, env func(string) string) (Location, bool) {
	u, err := url.Parse(text)
	if err != nil || u.Scheme != "s3" || u.Host == "" {
		return Location{}, false
	}
	// A variable set but empty is unset: compose passes ${X:-} through as "".
	region := first(env("AGENTS_STORE_REGION"), env("AWS_REGION"), env("AWS_DEFAULT_REGION"), "us-east-1")
	var endpoint *url.URL
	if e := env("AGENTS_STORE_ENDPOINT"); e != "" {
		if p, err := url.Parse(e); err == nil && p.Scheme != "" && p.Host != "" {
			endpoint = p
		}
	}
	if endpoint == nil {
		endpoint = &url.URL{Scheme: "https", Host: "s3." + region + ".amazonaws.com"}
	}
	return NewLocation(endpoint, u.Host, u.Path, region, env("AGENTS_STORE_PATH_STYLE") == "1"), true
}

func first(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// CredentialsFrom finds the keys in the order the contract gives: the environment, then
// the standard AWS file (its default profile, or AWS_PROFILE). Never the store.
func CredentialsFrom(env func(string) string) (Credentials, bool) {
	if access, secret := env("AWS_ACCESS_KEY_ID"), env("AWS_SECRET_ACCESS_KEY"); access != "" && secret != "" {
		return Credentials{AccessKey: access, SecretKey: secret, SessionToken: env("AWS_SESSION_TOKEN")}, true
	}
	home := env("HOME")
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	file := first(env("AWS_SHARED_CREDENTIALS_FILE"), filepath.Join(home, ".aws", "credentials"))
	text, err := os.ReadFile(file)
	if err != nil {
		return Credentials{}, false
	}
	wanted := first(env("AWS_PROFILE"), "default")
	profile := ""
	var c Credentials
	for _, raw := range strings.FieldsFunc(string(text), func(r rune) bool { return r == '\n' || r == '\r' }) {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "[") {
			profile = strings.Trim(line, "[]")
			continue
		}
		name, value, ok := strings.Cut(line, "=")
		if profile != wanted || !ok {
			continue
		}
		value = strings.TrimSpace(value)
		switch strings.TrimSpace(name) {
		case "aws_access_key_id":
			c.AccessKey = value
		case "aws_secret_access_key":
			c.SecretKey = value
		case "aws_session_token":
			c.SessionToken = value
		}
	}
	if c.AccessKey == "" || c.SecretKey == "" {
		return Credentials{}, false
	}
	return c, true
}

// Open opens s3://bucket/prefix with the endpoint, region, addressing and keys from env
// (StoreAddress.open for a bucket). env is os.Getenv, or a map's lookup in a test.
func Open(text string, env func(string) string) (*Store, error) {
	loc, ok := ParseLocation(text, env)
	if !ok {
		return nil, fmt.Errorf("%s is not a store: say file:///path or s3://bucket/prefix", text)
	}
	creds, ok := CredentialsFrom(env)
	if !ok {
		return nil, fmt.Errorf("no keys for the bucket: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or ~/.aws/credentials")
	}
	return New(loc, creds, nil), nil
}

// Store is S3Store.
type Store struct {
	Location    Location
	credentials Credentials
	client      *http.Client
}

var _ store.Store = (*Store)(nil)

// maxBody is the most of a reply that is read: 16 MiB.
const maxBody = 16 << 20

// New makes a store. A nil client is one with a 10 second timeout.
func New(loc Location, creds Credentials, client *http.Client) *Store {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &Store{Location: loc, credentials: creds, client: client}
}

func (s *Store) Get(ctx context.Context, key string) (*store.Object, error) {
	r, err := s.send(ctx, "GET", key, true, nil, nil, nil)
	if err != nil {
		return nil, err
	}
	switch r.status {
	case 200:
		if r.etag == "" {
			return nil, store.Unavailable("the bucket gave %s no ETag", key)
		}
		return &store.Object{Data: r.body, ETag: r.etag}, nil
	case 404:
		return nil, nil
	}
	return nil, r.unavailable("reading " + key)
}

func (s *Store) Put(ctx context.Context, key string, data []byte, when store.Condition) (string, error) {
	headers := [][2]string{{"content-type", "application/json"}}
	if when.IsAbsent() {
		headers = append(headers, [2]string{"if-none-match", "*"})
	} else if tag, ok := when.Matching(); ok {
		// Sent exactly as the bucket gave it, quotes and all (rule 9).
		headers = append(headers, [2]string{"if-match", tag})
	}
	if data == nil {
		data = []byte{}
	}
	r, err := s.send(ctx, "PUT", key, true, data, headers, nil)
	if err != nil {
		return "", err
	}
	switch {
	case r.status == 200:
		if r.etag == "" {
			return "", store.Unavailable("the bucket gave %s no ETag", key)
		}
		return r.etag, nil
	// Rule 8: a condition that did not hold, in whatever way the bucket says it.
	case r.status == 412, r.status == 409, r.status == 404 && !when.IsAlways():
		return "", &store.ConflictError{Key: key}
	}
	return "", r.unavailable("writing " + key)
}

func (s *Store) Delete(ctx context.Context, key string) error {
	r, err := s.send(ctx, "DELETE", key, true, nil, nil, nil)
	if err != nil {
		return err
	}
	if r.status != 204 && r.status != 200 && r.status != 404 {
		return r.unavailable("deleting " + key)
	}
	return nil
}

func (s *Store) List(ctx context.Context, prefix string) ([]store.Key, error) {
	found := []store.Key{}
	strip := 0
	if s.Location.Prefix != "" {
		strip = len(s.Location.Prefix) + 1
	}
	token := ""
	for {
		query := [][2]string{{"list-type", "2"}, {"prefix", s.objectKey(prefix)}}
		if token != "" {
			query = append(query, [2]string{"continuation-token", token})
		}
		r, err := s.send(ctx, "GET", "", false, nil, nil, query)
		if err != nil {
			return nil, err
		}
		if r.status != 200 {
			return nil, r.unavailable("listing " + prefix)
		}
		var page listPage
		if err := xml.Unmarshal(r.body, &page); err != nil {
			return nil, store.Unavailable("the bucket's listing of %s could not be read: %v", prefix, err)
		}
		for _, o := range page.Contents {
			if len(o.Key) >= strip {
				found = append(found, store.Key{Key: o.Key[strip:], ETag: o.ETag, Size: o.Size})
			}
		}
		if !page.IsTruncated || page.NextContinuationToken == "" {
			break
		}
		token = page.NextContinuationToken
	}
	sort.Slice(found, func(i, j int) bool { return found[i].Key < found[j].Key })
	return found, nil
}

// listPage is one page of ListObjectsV2.
type listPage struct {
	Contents []struct {
		Key  string
		ETag string
		Size int64
	}
	IsTruncated           bool
	NextContinuationToken string
}

// reply is what the bucket answered.
type reply struct {
	status int
	etag   string
	body   []byte
}

// code is S3's error code, out of the XML body.
func (r reply) code() string {
	text := string(r.body)
	start := strings.Index(text, "<Code>")
	end := strings.Index(text, "</Code>")
	if start < 0 || end < start {
		return ""
	}
	return text[start+len("<Code>") : end]
}

func (r reply) unavailable(doing string) error {
	code := r.code()
	if code != "" {
		code = " " + code
	}
	return store.Unavailable("the bucket answered %d%s %s", r.status, code, doing)
}

func (s *Store) objectKey(key string) string {
	if s.Location.Prefix == "" {
		return key
	}
	return s.Location.Prefix + "/" + key
}

func (s *Store) send(ctx context.Context, method, key string, hasKey bool, body []byte,
	extra, query [][2]string) (reply, error) {
	target, headers := s.request(method, key, hasKey, body, extra, query, time.Now())
	req, err := http.NewRequestWithContext(ctx, method, target, bytes.NewReader(body))
	if err != nil {
		return reply{}, store.Unavailable("cannot make a request to the bucket: %v", err)
	}
	for _, h := range headers {
		req.Header.Set(h[0], h[1])
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return reply{}, store.Unavailable("the bucket at %s could not be reached: %v", s.Location.Endpoint.Hostname(), err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBody+1))
	if err != nil {
		return reply{}, store.Unavailable("the bucket at %s could not be reached: %v", s.Location.Endpoint.Hostname(), err)
	}
	if len(data) > maxBody {
		return reply{}, store.Unavailable("the bucket answered more than %d bytes", maxBody)
	}
	return reply{status: resp.StatusCode, etag: resp.Header.Get("ETag"), body: data}, nil
}

// request signs a request but does not send it. It returns the URL and every header to
// send, apart from host, which the client sets from the URL.
func (s *Store) request(method, key string, hasKey bool, body []byte, extra, query [][2]string,
	now time.Time) (string, [][2]string) {
	loc := s.Location
	host := loc.Endpoint.Hostname()
	path := strings.TrimSuffix(loc.Endpoint.Path, "/")
	if loc.PathStyle {
		path += "/" + loc.Bucket
	} else {
		host = loc.Bucket + "." + host
	}
	if hasKey {
		path += "/" + s.objectKey(key)
	}
	if path == "" {
		path = "/"
	}
	authority := host
	if port := loc.Endpoint.Port(); port != "" {
		authority = host + ":" + port
	}

	amzDate := now.UTC().Format("20060102T150405Z")
	day := amzDate[:8]
	payloadHash := hexSHA256(body)
	headers := [][2]string{{"host", authority}, {"x-amz-content-sha256", payloadHash}, {"x-amz-date", amzDate}}
	if s.credentials.SessionToken != "" {
		headers = append(headers, [2]string{"x-amz-security-token", s.credentials.SessionToken})
	}
	for _, h := range extra {
		headers = append(headers, [2]string{strings.ToLower(h[0]), strings.TrimSpace(h[1])})
	}
	sort.SliceStable(headers, func(i, j int) bool { return headers[i][0] < headers[j][0] })
	var canonicalHeaders strings.Builder
	names := make([]string, len(headers))
	for i, h := range headers {
		canonicalHeaders.WriteString(h[0] + ":" + h[1] + "\n")
		names[i] = h[0]
	}
	signedHeaders := strings.Join(names, ";")

	canonicalURI := uriEncode(path, false)
	pairs := make([][2]string, len(query))
	for i, q := range query {
		pairs[i] = [2]string{uriEncode(q[0], true), uriEncode(q[1], true)}
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i][0] == pairs[j][0] {
			return pairs[i][1] < pairs[j][1]
		}
		return pairs[i][0] < pairs[j][0]
	})
	parts := make([]string, len(pairs))
	for i, p := range pairs {
		parts[i] = p[0] + "=" + p[1]
	}
	canonicalQuery := strings.Join(parts, "&")
	canonicalRequest := strings.Join([]string{method, canonicalURI, canonicalQuery,
		canonicalHeaders.String(), signedHeaders, payloadHash}, "\n")
	scope := day + "/" + loc.Region + "/s3/aws4_request"
	stringToSign := strings.Join([]string{"AWS4-HMAC-SHA256", amzDate, scope,
		hexSHA256([]byte(canonicalRequest))}, "\n")
	signingKey := hmacSHA256([]byte("AWS4"+s.credentials.SecretKey), day)
	for _, part := range []string{loc.Region, "s3", "aws4_request"} {
		signingKey = hmacSHA256(signingKey, part)
	}
	signature := hex.EncodeToString(hmacSHA256(signingKey, stringToSign))
	headers = append(headers, [2]string{"authorization", "AWS4-HMAC-SHA256 Credential=" + s.credentials.AccessKey +
		"/" + scope + ", SignedHeaders=" + signedHeaders + ", Signature=" + signature})

	scheme := loc.Endpoint.Scheme
	if scheme == "" {
		scheme = "https"
	}
	target := scheme + "://" + authority + canonicalURI
	if canonicalQuery != "" {
		target += "?" + canonicalQuery
	}
	out := headers[:0:0]
	for _, h := range headers {
		if h[0] != "host" {
			out = append(out, h)
		}
	}
	return target, out
}

func hexSHA256(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key []byte, message string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(message))
	return m.Sum(nil)
}

// uriEncode keeps RFC 3986's unreserved characters, and the slash when encodeSlash is
// false. Every other byte becomes %XX, in upper case.
func uriEncode(text string, encodeSlash bool) string {
	var out strings.Builder
	for i := 0; i < len(text); i++ {
		b := text[i]
		switch {
		case 'A' <= b && b <= 'Z', 'a' <= b && b <= 'z', '0' <= b && b <= '9',
			b == '-', b == '.', b == '_', b == '~', b == '/' && !encodeSlash:
			out.WriteByte(b)
		default:
			fmt.Fprintf(&out, "%%%02X", b)
		}
	}
	return out.String()
}
