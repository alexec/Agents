package forgepages

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Each connector page's CSS reads only variables that Style defines, and has no colour of
// its own (#4607): its look is the design tokens'.
func TestPagesReadOnlyTheTokens(t *testing.T) {
	defined := map[string]bool{}
	for _, m := range regexp.MustCompile(`(--[a-z0-9-]+)\s*:`).FindAllStringSubmatch(Style, -1) {
		defined[m[1]] = true
	}
	files, err := filepath.Glob("../*/pages/*.css")
	if err != nil || len(files) == 0 {
		t.Fatalf("no connector page CSS found: %v", err)
	}
	files = append(files, "pages.css")
	uses := regexp.MustCompile(`var\((--[a-z0-9-]+)\s*[,)]`)
	colour := regexp.MustCompile(`#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(`)
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		css := string(b)
		for _, m := range uses.FindAllStringSubmatch(css, -1) {
			if !defined[m[1]] && !strings.Contains(css, m[1]+":") {
				t.Errorf("%s reads %s, which forgepages.Style does not define", f, m[1])
			}
		}
		if colour.MatchString(regexp.MustCompile(`(?s)/\*.*?\*/`).ReplaceAllString(css, "")) {
			t.Errorf("%s has a colour of its own: put it in design/tokens.json", f)
		}
	}
}
