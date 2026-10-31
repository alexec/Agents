package richtext

import (
	"strings"
	"testing"
)

func TestMarkdownRendersCommonRichText(t *testing.T) {
	rendered := Markdown("## Work\n\n- **Inspect** the _response_.\n- `resume`")
	for _, want := range []string{"<h2>Work</h2>", "<strong>Inspect</strong>", "<em>response</em>", "<code>resume</code>"} {
		if !strings.Contains(rendered, want) {
			t.Errorf("Markdown output %q does not contain %q", rendered, want)
		}
	}
}

func TestMarkdownDoesNotRenderUnsafeHTMLOrLinks(t *testing.T) {
	rendered := Markdown(`<script>alert(1)</script> [unsafe](javascript:alert%281%29)`)
	if strings.Contains(rendered, "<script>") || strings.Contains(rendered, `href="javascript:`) {
		t.Fatalf("unsafe Markdown rendered as active content: %s", rendered)
	}
}
