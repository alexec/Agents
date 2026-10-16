package wire

import _ "embed"

// AppTools is the app's own MCP tools, names, descriptions and input schemas, as the Swift
// host's AppService lists them for a runtime that can move itself: a JSON array, copied from
// Packages/Wire/app-tools.json by scripts/wire.sh gen.
//
//go:embed app-tools.json
var AppTools []byte

// EventCatalogue is every event the app raises, as the Swift host's EventCatalogue has
// them: {"kinds": [{name, scope, macOnly, meaning, inputSchema, payloadSchema}], "listText"},
// the list text being what wait_for_event's list says with no server's events. Copied from
// Packages/Wire/event-catalogue.json by scripts/wire.sh gen.
//
//go:embed event-catalogue.json
var EventCatalogue []byte
