package paperpage

import (
	"regexp"
	"strings"
	"testing"
)

// TestStyleNamesOnlyTokens checks page.css names no raw colour or font (#4617): every colour
// and font comes from tokens.css, which scripts/design.sh gen makes.
func TestStyleNamesOnlyTokens(t *testing.T) {
	if !strings.Contains(tokens, "--paper-ground:") || !strings.Contains(tokens, "prefers-color-scheme: dark") {
		t.Fatalf("tokens.css has no Paper ground or no dark: %q", tokens[:min(len(tokens), 200)])
	}
	raw := regexp.MustCompile(`#[0-9a-fA-F]{3,8}\b|rgb\(|hsl\(|-apple-system|system-ui|sans-serif|monospace`)
	rules := regexp.MustCompile(`(?s)/\*.*?\*/`).ReplaceAllString(page, "")
	if found := raw.FindAllString(rules, -1); len(found) > 0 {
		t.Fatalf("page.css names %v; use a token from tokens.css", found)
	}
	if !strings.HasPrefix(Style, tokens) || !strings.HasSuffix(Style, page) {
		t.Fatal("Style is not the tokens, then the page's rules")
	}
	if !strings.HasPrefix(StyleSource, "'sha256-") || !strings.HasSuffix(StyleSource, "='") {
		t.Fatalf("StyleSource = %s", StyleSource)
	}
}
