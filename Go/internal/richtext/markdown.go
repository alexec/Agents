// Package richtext renders text that comes from issue providers for app views.
package richtext

import (
	"bytes"
	"html"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
)

var issueMarkdown = goldmark.New(goldmark.WithExtensions(extension.GFM))

// Markdown renders GitHub-flavored Markdown to safe HTML. Goldmark leaves raw HTML
// disabled and filters unsafe link targets with its default renderer.
func Markdown(source string) string {
	var rendered bytes.Buffer
	if err := issueMarkdown.Convert([]byte(source), &rendered); err != nil {
		return "<p>" + html.EscapeString(source) + "</p>\n"
	}
	return rendered.String()
}
