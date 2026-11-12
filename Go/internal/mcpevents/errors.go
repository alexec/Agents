// Package mcpevents is what the event MCP servers share (#3755, #4187): the forge, tracker,
// mail, health and chat servers. It has the MCP events (#1753) of the events draft
// (experimental-ext-triggers-events), polled only, which the Agents daemon speaks: the
// JSON-RPC error, an event's arguments and their check, the events/list answer, the opaque
// cursor, the two ways of polling (by time and by a state's diff), the stdio front that
// answers events/list and events/poll before the go-sdk server behind it, the servers' one
// time layout, and the tail of a CI log. Each server keeps its own events, words and reads.
package mcpevents

import (
	"fmt"
	"strings"
)

// Error is a JSON-RPC error answer: its code, message and optional data.
type Error struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data,omitempty"`
}

func (e *Error) Error() string { return e.Message }

// InvalidParams is a -32602 answer with its words.
func InvalidParams(format string, args ...any) *Error {
	return &Error{Code: -32602, Message: fmt.Sprintf(format, args...)}
}

// NoEvent is the answer to a poll of an event the server does not offer: -32011, naming those it does.
func NoEvent(name string, offered []string) *Error {
	return &Error{Code: -32011, Message: fmt.Sprintf("no event %s; this server offers %s", name, strings.Join(offered, ", "))}
}
