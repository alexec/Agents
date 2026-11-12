package controlplane

import (
	"crypto/sha256"
	"encoding/base64"
	"net/http/httptest"
	"strings"
	"testing"
)

// #4617: the fallback page is on Paper, and its policy lets in its own inline style and no other.
func TestOIDCPageStyleMatchesItsPolicy(t *testing.T) {
	rec := httptest.NewRecorder()
	page(rec, 400, "This sign-in is <done>.")
	body := rec.Body.String()
	_, style, ok := strings.Cut(body, "<style>")
	style, _, ok2 := strings.Cut(style, "</style>")
	if !ok || !ok2 || !strings.Contains(style, "--paper-ground:") {
		t.Fatalf("no Paper style: %s", body)
	}
	sum := sha256.Sum256([]byte(style))
	want := "default-src 'none'; style-src 'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
	if got := rec.Header().Get("Content-Security-Policy"); got != want {
		t.Fatalf("policy %q, want %q", got, want)
	}
	if !strings.Contains(body, "This sign-in is &lt;done&gt;.") {
		t.Fatalf("text not escaped: %s", body)
	}
}
