// Package paperpage is the look of the small HTML pages that Agents serves with no other
// assets (#4617): the hosted service's sign-in pages, the connector sign-in loopback page and
// the org OIDC page. Each inlines Style in a <style> element. tokens.css is made by
// scripts/design.sh gen from design/tokens.json; page.css names colours and fonts only by
// those tokens.
package paperpage

import (
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
)

//go:embed tokens.css
var tokens string

//go:embed page.css
var page string

// Style is the CSS for a page's <style> element: the design tokens, then the page's rules.
var Style = tokens + page

// StyleSource is Style's hash as a Content-Security-Policy source, for a page whose policy
// lets no other style in: style-src StyleSource.
var StyleSource = func() string {
	sum := sha256.Sum256([]byte(Style))
	return "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
}()
