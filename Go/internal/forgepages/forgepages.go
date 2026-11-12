// Package forgepages is the look the connectors' MCP App pages share (#4607): the design
// tokens that scripts/design.sh gen writes from design/tokens.json (tokens.css), and the MCP
// Apps variables the pages read, mapped onto those tokens once (pages.css). Each connector's
// views.go puts Style in front of its own common.css, so a page has no palette of its own.
// The host's hostContext.styles.variables still replace these when it sends them.
package forgepages

import (
	_ "embed"
)

//go:embed tokens.css
var tokens string

//go:embed pages.css
var pages string

// Style is the CSS a connector's page starts with: the tokens, then the pages' variables.
var Style = tokens + "\n" + pages
