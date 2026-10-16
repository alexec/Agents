package wire

import _ "embed"

// AppTools is the app's own MCP tools, names, descriptions and input schemas, as the Swift
// host's AppService lists them for a runtime that can move itself: a JSON array, copied from
// Packages/Wire/app-tools.json by scripts/wire.sh gen.
//
//go:embed app-tools.json
var AppTools []byte
