package hosted

import (
	"strings"
	"testing"
)

// #3500: in dark mode the grey button rule comes after the blue one, so the dark block
// must make the prominent buttons blue again.
func TestProminentButtonsAreBlueInDarkMode(t *testing.T) {
	var b strings.Builder
	if err := pageTemplate.Execute(&b, page{Title: "Agents", Welcome: true}); err != nil {
		t.Fatal(err)
	}
	html := b.String()
	_, dark, ok := strings.Cut(html, "@media (prefers-color-scheme: dark)")
	if !ok {
		t.Fatal("no dark mode styles")
	}
	dark, _, _ = strings.Cut(dark, "</style>")
	grey := strings.Index(dark, "a.button, button")
	blue := strings.Index(dark, "a.prominent, button.prominent { background: #2c5fd6;")
	if grey < 0 || blue < grey {
		t.Fatalf("dark mode does not make prominent buttons blue after the grey rule:\n%s", dark)
	}
}
