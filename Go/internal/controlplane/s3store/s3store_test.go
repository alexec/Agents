package s3store

// The bucket cases of StoreConformanceTests.swift, ported. Every case runs on a fake
// bucket in this process. It runs on a real bucket too when AGENTS_TEST_S3 names one, as
// s3://bucket/prefix, with AGENTS_STORE_ENDPOINT, AGENTS_STORE_PATH_STYLE and the usual
// AWS keys in the environment.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/s3store/s3fake"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

var ctx = context.Background()


func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// fake starts a fake bucket and opens a store on it, under a prefix.
func fake(t *testing.T) *Store {
	server := httptest.NewServer(s3fake.New("test"))
	t.Cleanup(server.Close)
	env := map[string]string{
		"AGENTS_STORE_ENDPOINT":   server.URL,
		"AGENTS_STORE_PATH_STYLE": "1",
		"AWS_ACCESS_KEY_ID":       "test",
		"AWS_SECRET_ACCESS_KEY":   "secret",
		"AWS_SESSION_TOKEN":       "",
	}
	s, err := Open("s3://test/conf", func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func each(t *testing.T, test func(t *testing.T, s store.Store)) {
	t.Run("fake", func(t *testing.T) { test(t, fake(t)) })
	t.Run("bucket", func(t *testing.T) {
		text := os.Getenv("AGENTS_TEST_S3")
		if text == "" {
			t.Skip("AGENTS_TEST_S3 names no bucket")
		}
		s, err := Open(strings.TrimRight(text, "/")+"/conf-"+randomHex(4), os.Getenv)
		if err != nil {
			t.Fatal(err)
		}
		test(t, s)
	})
}

func TestCreateOnlyConflicts(t *testing.T) {
	each(t, func(t *testing.T, s store.Store) {
		if _, err := s.Put(ctx, "v1/a.json", []byte("1"), store.Absent); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Put(ctx, "v1/a.json", []byte("2"), store.Absent); !store.IsConflict(err) {
			t.Fatalf("want a conflict, got %v", err)
		}
		o, err := s.Get(ctx, "v1/a.json")
		if err != nil || o == nil || string(o.Data) != "1" {
			t.Fatalf("got %v, %v", o, err)
		}
	})
}

func TestAStaleMatchingConflicts(t *testing.T) {
	each(t, func(t *testing.T, s store.Store) {
		first, _ := s.Put(ctx, "v1/a.json", []byte("1"), store.Absent)
		second, err := s.Put(ctx, "v1/a.json", []byte("2"), store.Matching(first))
		if err != nil || second == first {
			t.Fatalf("second %q first %q err %v", second, first, err)
		}
		if _, err := s.Put(ctx, "v1/a.json", []byte("3"), store.Matching(first)); !store.IsConflict(err) {
			t.Fatalf("want a conflict, got %v", err)
		}
		o, _ := s.Get(ctx, "v1/a.json")
		if o == nil || o.ETag != second || string(o.Data) != "2" {
			t.Fatalf("got %v, want tag %q", o, second)
		}
	})
}

// Rule 8: an If-Match on a key that is gone is a conflict too (404 from a bucket).
func TestMatchingAGoneKeyConflicts(t *testing.T) {
	each(t, func(t *testing.T, s store.Store) {
		tag, _ := s.Put(ctx, "v1/a.json", []byte("1"), store.Absent)
		if err := s.Delete(ctx, "v1/a.json"); err != nil {
			t.Fatal(err)
		}
		if o, err := s.Get(ctx, "v1/a.json"); o != nil || err != nil {
			t.Fatalf("got %v, %v after a delete", o, err)
		}
		if _, err := s.Put(ctx, "v1/a.json", []byte("2"), store.Matching(tag)); !store.IsConflict(err) {
			t.Fatalf("want a conflict, got %v", err)
		}
	})
}

func TestListSeesNewKeys(t *testing.T) {
	each(t, func(t *testing.T, s store.Store) {
		if got, err := s.List(ctx, "v1/clients/"); err != nil || len(got) != 0 {
			t.Fatalf("got %v, %v", got, err)
		}
		tag, _ := s.Put(ctx, "v1/clients/one.json", []byte("1"), store.Absent)
		s.Put(ctx, "v1/machines/mac.json", []byte("2"), store.Absent)
		got, _ := s.List(ctx, "v1/clients/")
		if want := []store.Key{{Key: "v1/clients/one.json", ETag: tag, Size: 1}}; !reflect.DeepEqual(got, want) {
			t.Fatalf("got %v, want %v", got, want)
		}
		if got, _ := s.List(ctx, "v1/"); len(got) != 2 {
			t.Fatalf("got %v", got)
		}
	})
}

// More keys than one page holds: listing follows the continuation tokens.
func TestListFollowsContinuation(t *testing.T) {
	each(t, func(t *testing.T, s store.Store) {
		var want []string
		for n := range 5 {
			key := fmt.Sprintf("v1/codes/%d", n)
			want = append(want, key)
			if _, err := s.Put(ctx, key, []byte("x"), store.Absent); err != nil {
				t.Fatal(err)
			}
		}
		got, err := s.List(ctx, "v1/codes/")
		if err != nil {
			t.Fatal(err)
		}
		var keys []string
		for _, k := range got {
			keys = append(keys, k.Key)
		}
		if !reflect.DeepEqual(keys, want) {
			t.Fatalf("got %v, want %v", keys, want)
		}
	})
}

// A spent code is written once, however many copies race to use it.
func TestOneOfTwentyRacingCreatesWins(t *testing.T) {
	each(t, func(t *testing.T, s store.Store) {
		var wins atomic.Int32
		var wg sync.WaitGroup
		for n := range 20 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := s.Put(ctx, "v1/codes/x.spent", []byte(fmt.Sprint(n)), store.Absent); err == nil {
					wins.Add(1)
				}
			}()
		}
		wg.Wait()
		if wins.Load() != 1 {
			t.Fatalf("%d winners", wins.Load())
		}
	})
}

// Racing If-Match writes from one version: exactly one wins.
func TestOneOfTwentyRacingUpdatesWins(t *testing.T) {
	each(t, func(t *testing.T, s store.Store) {
		first, _ := s.Put(ctx, "v1/a.json", []byte("0"), store.Absent)
		var wins atomic.Int32
		var wg sync.WaitGroup
		for n := range 20 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := s.Put(ctx, "v1/a.json", []byte(fmt.Sprint(n+1)), store.Matching(first)); err == nil {
					wins.Add(1)
				}
			}()
		}
		wg.Wait()
		if wins.Load() != 1 {
			t.Fatalf("%d winners", wins.Load())
		}
	})
}

func TestTheProbePasses(t *testing.T) {
	each(t, func(t *testing.T, s store.Store) {
		if err := store.Probe(ctx, s, "test"); err != nil {
			t.Fatal(err)
		}
	})
}

// A bucket that cannot be reached is unavailable, not absent.
func TestAnUnreachableBucketIsUnavailable(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	endpoint, _ := url.Parse(server.URL)
	server.Close()
	s := New(NewLocation(endpoint, "test", "", "", true), Credentials{AccessKey: "a", SecretKey: "b"}, nil)
	var u *store.UnavailableError
	if _, err := s.Get(ctx, "v1/a.json"); !asUnavailable(err, &u) {
		t.Fatalf("got %v", err)
	}
}

func asUnavailable(err error, u **store.UnavailableError) bool {
	e, ok := err.(*store.UnavailableError)
	*u = e
	return ok
}

// The signer, against AWS's published example (SigV4 "GET Object" with a range).
func TestTheSignatureMatchesAWSsExample(t *testing.T) {
	endpoint, _ := url.Parse("https://s3.amazonaws.com")
	s := New(NewLocation(endpoint, "examplebucket", "", "", false),
		Credentials{AccessKey: "AKIAIOSFODNN7EXAMPLE", SecretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"}, nil)
	date, _ := time.Parse(time.RFC3339, "2013-05-24T00:00:00Z")
	target, headers := s.request("GET", "test.txt", true, nil, [][2]string{{"range", "bytes=0-9"}}, nil, date)
	authorization := ""
	for _, h := range headers {
		if h[0] == "authorization" {
			authorization = h[1]
		}
	}
	if !strings.HasSuffix(authorization, "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41") {
		t.Fatalf("authorization %q", authorization)
	}
	if target != "https://examplebucket.s3.amazonaws.com/test.txt" {
		t.Fatalf("url %q", target)
	}
}

// s3://bucket/prefix, with the endpoint, region, addressing and keys from the
// environment. Set but empty is unset.
func TestOpenReadsTheEnvironment(t *testing.T) {
	env := map[string]string{
		"AWS_REGION":              "eu-west-2",
		"AGENTS_STORE_REGION":     "",
		"AGENTS_STORE_ENDPOINT":   "",
		"AGENTS_STORE_PATH_STYLE": "",
		"AWS_ACCESS_KEY_ID":       "a",
		"AWS_SECRET_ACCESS_KEY":   "b",
		"AWS_SESSION_TOKEN":       "c",
	}
	s, err := Open("s3://bucket/some/prefix/", func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	l := s.Location
	if l.Bucket != "bucket" || l.Prefix != "some/prefix" || l.Region != "eu-west-2" || l.PathStyle ||
		l.Endpoint.String() != "https://s3.eu-west-2.amazonaws.com" {
		t.Fatalf("got %+v", l)
	}
	if s.credentials != (Credentials{"a", "b", "c"}) {
		t.Fatalf("got %+v", s.credentials)
	}
	_, headers := s.request("GET", "k", true, nil, nil, nil, time.Now())
	signed := false
	for _, h := range headers {
		if h[0] == "x-amz-security-token" && h[1] == "c" {
			signed = true
		}
	}
	if !signed {
		t.Fatal("the session token was not sent")
	}

	env["AGENTS_STORE_ENDPOINT"] = "http://127.0.0.1:9000"
	env["AGENTS_STORE_PATH_STYLE"] = "1"
	s, _ = Open("s3://bucket", func(k string) string { return env[k] })
	target, _ := s.request("GET", "v1/a b.json", true, nil, nil, nil, time.Now())
	if target != "http://127.0.0.1:9000/bucket/v1/a%20b.json" {
		t.Fatalf("url %q", target)
	}

	for _, text := range []string{"file:///tmp/x", "s3:///prefix", "bucket/prefix"} {
		if _, err := Open(text, func(k string) string { return env[k] }); err == nil {
			t.Fatalf("%s opened", text)
		}
	}
}

// The keys come from the AWS file when the environment has none: its default profile,
// or AWS_PROFILE.
func TestCredentialsFromTheAWSFile(t *testing.T) {
	file := t.TempDir() + "/credentials"
	os.WriteFile(file, []byte("[default]\naws_access_key_id = one\naws_secret_access_key = two\n\n"+
		"[work]\naws_access_key_id=three\naws_secret_access_key=four\naws_session_token=five\n"), 0o600)
	env := map[string]string{"AWS_SHARED_CREDENTIALS_FILE": file}
	get := func(k string) string { return env[k] }
	if c, ok := CredentialsFrom(get); !ok || c != (Credentials{"one", "two", ""}) {
		t.Fatalf("got %+v", c)
	}
	env["AWS_PROFILE"] = "work"
	if c, ok := CredentialsFrom(get); !ok || c != (Credentials{"three", "four", "five"}) {
		t.Fatalf("got %+v", c)
	}
	env["AWS_PROFILE"] = "none"
	if _, ok := CredentialsFrom(get); ok {
		t.Fatal("keys from a profile that is not there")
	}
}
