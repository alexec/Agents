package richtext

import (
	"strings"
	"testing"
)

// Jira's renderedFields description, as Jira Cloud and Data Center render wiki markup (#3247).
func TestHTMLKeepsRichText(t *testing.T) {
	rendered := HTML(`<h2><a name="Work"></a>Work</h2><p>Read <b>this</b> and <a href="https://example.com/x" class="external-link" rel="nofollow">that</a>.</p>` +
		`<ul><li><tt>resume</tt></li></ul><table class="confluenceTable"><tbody><tr><td>1</td></tr></tbody></table>`)
	for _, w := range []string{"Work</h2>", "<b>this</b>", `<a href="https://example.com/x">that</a>`, "<li><tt>resume</tt></li>", "<td>1</td>"} {
		if !strings.Contains(rendered, w) {
			t.Errorf("HTML output %q does not contain %q", rendered, w)
		}
	}
	if !strings.HasPrefix(rendered, "<h2><a></a>Work</h2>") || strings.Contains(rendered, "class=") || strings.Contains(rendered, "name=") || strings.Contains(rendered, "rel=") {
		t.Errorf("no attribute but a link's href is kept: %s", rendered)
	}
}

func TestHTMLDropsActiveContent(t *testing.T) {
	rendered := HTML(`<p onclick="x()">Hi<script>alert(1)</script><style>p{}</style></p>` +
		`<a href="javascript:alert(1)">bad</a><a href="//evil.example/x">ok</a><iframe src="https://x"></iframe>` +
		`<img src="x" onerror="alert(1)"><svg><script>alert(2)</script></svg><form><input value="v"></form><blink>text</blink>`)
	for _, bad := range []string{"script", "alert", "onclick", "style", "javascript:", "iframe", "img", "onerror", "svg", "form", "input", "blink"} {
		if strings.Contains(rendered, bad) {
			t.Errorf("%q is left in %s", bad, rendered)
		}
	}
	for _, w := range []string{"<p>Hi</p>", "<a>bad</a>", `<a href="//evil.example/x">ok</a>`, "text"} {
		if !strings.Contains(rendered, w) {
			t.Errorf("HTML output %q does not contain %q", rendered, w)
		}
	}
}
