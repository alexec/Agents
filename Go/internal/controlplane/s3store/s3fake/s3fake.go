// Package s3fake is a bucket in the process for tests: path-style, with If-Match and
// If-None-Match kept, as S3 and MinIO keep them.
package s3fake

import (
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// New is an empty bucket named bucket.
func New(bucket string) *Bucket { return &Bucket{bucket: bucket, objects: map[string][]byte{}} }

// Bucket is a path-style bucket that keeps If-Match and If-None-Match, as S3 and MinIO
// do. It lists two keys a page, so that listing must follow continuation tokens.
type Bucket struct {
	mu      sync.Mutex
	bucket  string
	objects map[string][]byte
}

// ServeHTTP answers GET, PUT (with its conditions), DELETE and ListObjectsV2.
func (f *Bucket) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential=") {
		http.Error(w, "<Error><Code>AccessDenied</Code></Error>", http.StatusForbidden)
		return
	}
	body, _ := io.ReadAll(r.Body)
	if r.Header.Get("X-Amz-Content-Sha256") != hexSHA256(body) {
		http.Error(w, "<Error><Code>XAmzContentSHA256Mismatch</Code></Error>", http.StatusBadRequest)
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/"+f.bucket)
	f.mu.Lock()
	defer f.mu.Unlock()
	if path == "" || path == "/" {
		f.list(w, r)
		return
	}
	key := strings.TrimPrefix(path, "/")
	data, there := f.objects[key]
	switch r.Method {
	case "GET":
		if !there {
			http.Error(w, "<Error><Code>NoSuchKey</Code></Error>", http.StatusNotFound)
			return
		}
		w.Header().Set("ETag", etag(data))
		w.Write(data)
	case "PUT":
		if r.Header.Get("If-None-Match") == "*" && there {
			http.Error(w, "<Error><Code>PreconditionFailed</Code></Error>", http.StatusPreconditionFailed)
			return
		}
		if tag := r.Header.Get("If-Match"); tag != "" {
			if !there {
				http.Error(w, "<Error><Code>NoSuchKey</Code></Error>", http.StatusNotFound)
				return
			}
			if tag != etag(data) {
				http.Error(w, "<Error><Code>PreconditionFailed</Code></Error>", http.StatusPreconditionFailed)
				return
			}
		}
		f.objects[key] = body
		w.Header().Set("ETag", etag(body))
	case "DELETE":
		delete(f.objects, key)
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (f *Bucket) list(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("list-type") != "2" {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	var keys []string
	for k := range f.objects {
		if strings.HasPrefix(k, q.Get("prefix")) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	start := 0
	if t := q.Get("continuation-token"); t != "" {
		start, _ = strconv.Atoi(t)
	}
	end := min(start+2, len(keys))
	type content struct {
		Key  string
		ETag string
	}
	page := struct {
		XMLName               xml.Name `xml:"http://s3.amazonaws.com/doc/2006-03-01/ ListBucketResult"`
		Contents              []content
		IsTruncated           bool
		NextContinuationToken string `xml:",omitempty"`
	}{IsTruncated: end < len(keys)}
	for _, k := range keys[min(start, len(keys)):end] {
		page.Contents = append(page.Contents, content{k, etag(f.objects[k])})
	}
	if page.IsTruncated {
		page.NextContinuationToken = strconv.Itoa(end)
	}
	w.Header().Set("Content-Type", "application/xml")
	io.WriteString(w, xml.Header)
	xml.NewEncoder(w).Encode(page)
}

func etag(data []byte) string {
	sum := md5.Sum(data)
	return `"` + hex.EncodeToString(sum[:]) + `"`
}

func hexSHA256(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
