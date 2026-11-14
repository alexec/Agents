package hosted

import (
	"regexp"
	"strings"
	"testing"
)

// #3500, #4617: the prominent buttons stay in the accent in light and dark. The dark is in the
// tokens alone, so the page's prominent rule comes after the plain button rule and names the
// accent; the page names no colour or font outside the token file.
func TestProminentButtonsAreTheAccent(t *testing.T) {
	var b strings.Builder
	if err := pageTemplate.Execute(&b, page{Title: "Agent Loops", Welcome: true}); err != nil {
		t.Fatal(err)
	}
	html := b.String()
	_, style, ok := strings.Cut(html, "<style>")
	if !ok {
		t.Fatal("no style")
	}
	style, _, _ = strings.Cut(style, "</style>")
	// html/template drops CSS comments, so the page's rules start at page.css's first rule.
	tokens, rules, ok := strings.Cut(style, "body { font:")
	if !ok || !strings.Contains(tokens, "--paper-ground:") || !strings.Contains(tokens, "prefers-color-scheme: dark") {
		t.Fatalf("the style does not start with the design tokens, light and dark:\n%s", style)
	}
	grey := strings.Index(rules, "a.button, button {")
	blue := strings.Index(rules, "a.prominent, button.prominent { background: var(--accent);")
	if grey < 0 || blue < grey {
		t.Fatalf("the prominent buttons are not the accent after the plain button rule:\n%s", rules)
	}
	rules = regexp.MustCompile(`(?s)/\*.*?\*/`).ReplaceAllString(rules, "")
	if raw := regexp.MustCompile(`#[0-9a-fA-F]{3,8}\b|rgb\(|-apple-system|sans-serif`).FindAllString(rules, -1); len(raw) > 0 {
		t.Fatalf("the page names %v outside the token file", raw)
	}
}
