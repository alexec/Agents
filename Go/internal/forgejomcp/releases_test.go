package forgejomcp

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// #4426: a repository's releases; a draft's time is when it was saved, so it has no PublishedAt.
func TestReleases(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/repos/walkalex/app/releases" || r.URL.Query().Get("limit") != "50" {
			http.NotFound(w, r)
			return
		}
		_, _ = io.WriteString(w, `[{"tag_name": "v0.3.0", "draft": true, "published_at": "2026-11-09T10:00:00Z", "assets": []},
			{"tag_name": "v0.2.0", "name": "Two", "body": "b", "published_at": "2026-11-06T10:00:00Z", "author": {"login": "walkalex"},
			 "assets": [{}], "html_url": "u"}]`)
	}))
	t.Cleanup(s.Close)
	got, err := NewRealForgejo(s.URL, func() string { return token }, nil).Releases(context.Background(), "walkalex/app", 500)
	if err != nil || len(got) != 2 {
		t.Fatalf("%+v %v", got, err)
	}
	if got[0].PublishedAt != "" || !got[0].Draft {
		t.Errorf("draft: %+v", got[0])
	}
	if r := got[1]; r.Name != "Two" || r.Author != "walkalex" || r.Assets != 1 || r.URL != "u" || r.PublishedAt != "2026-11-06T10:00:00Z" {
		t.Errorf("release: %+v", r)
	}
}
