package richtext

import (
	"bytes"
	"net/url"
	"strings"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

// HTML is HTML that an issue provider rendered (Jira's renderedFields, #3247), made safe for
// a view: only the elements of rich text are kept, with no attribute but a link's http,
// https or mailto href; a script, a style, a form or a frame goes with all it holds, and any
// other element leaves only its contents. bluemonday does this too, but it has had no
// release or change since April 2025.
func HTML(source string) string {
	nodes, err := html.ParseFragment(strings.NewReader(source), &html.Node{Type: html.ElementNode, Data: "div", DataAtom: atom.Div})
	if err != nil {
		return "<p>" + html.EscapeString(source) + "</p>\n"
	}
	var out bytes.Buffer
	for _, n := range nodes {
		for _, c := range clean(n) {
			_ = html.Render(&out, c)
		}
	}
	return out.String()
}

// kept are the elements of rich text.
var kept = map[atom.Atom]bool{
	atom.P: true, atom.Br: true, atom.Hr: true, atom.Strong: true, atom.B: true, atom.Em: true, atom.I: true, atom.U: true,
	atom.S: true, atom.Del: true, atom.Ins: true, atom.Sub: true, atom.Sup: true, atom.Code: true, atom.Pre: true, atom.Tt: true,
	atom.Blockquote: true, atom.Ul: true, atom.Ol: true, atom.Li: true, atom.Dl: true, atom.Dt: true, atom.Dd: true,
	atom.H1: true, atom.H2: true, atom.H3: true, atom.H4: true, atom.H5: true, atom.H6: true, atom.A: true,
	atom.Table: true, atom.Thead: true, atom.Tbody: true, atom.Tr: true, atom.Th: true, atom.Td: true, atom.Span: true, atom.Div: true,
}

// dropped are the elements that go with all they hold.
var dropped = map[atom.Atom]bool{
	atom.Script: true, atom.Style: true, atom.Iframe: true, atom.Frame: true, atom.Frameset: true, atom.Object: true,
	atom.Embed: true, atom.Form: true, atom.Input: true, atom.Button: true, atom.Select: true, atom.Textarea: true,
	atom.Noscript: true, atom.Template: true, atom.Svg: true, atom.Math: true, atom.Link: true, atom.Meta: true, atom.Base: true,
}

// clean is n made safe, as new nodes: none, n's own, or its children's.
func clean(n *html.Node) []*html.Node {
	switch n.Type {
	case html.TextNode:
		return []*html.Node{{Type: html.TextNode, Data: n.Data}}
	case html.ElementNode:
	default:
		return nil
	}
	if dropped[n.DataAtom] || n.DataAtom == 0 && n.Namespace != "" {
		return nil
	}
	var children []*html.Node
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		children = append(children, clean(c)...)
	}
	if !kept[n.DataAtom] {
		return children
	}
	out := &html.Node{Type: html.ElementNode, Data: n.DataAtom.String(), DataAtom: n.DataAtom}
	if n.DataAtom == atom.A {
		for _, a := range n.Attr {
			if a.Namespace == "" && a.Key == "href" && safeLink(a.Val) {
				out.Attr = []html.Attribute{{Key: "href", Val: a.Val}}
			}
		}
	}
	for _, c := range children {
		out.AppendChild(c)
	}
	return []*html.Node{out}
}

// safeLink says whether a link goes to a web page or an email: a relative one does too, as
// the page makes it absolute from the issue's own address.
func safeLink(raw string) bool {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return false
	}
	switch strings.ToLower(u.Scheme) {
	case "", "http", "https", "mailto":
		return u.Scheme != "" || u.Opaque == ""
	}
	return false
}
