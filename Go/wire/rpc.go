package wire

// Method is a JSON-RPC method and the Go types of its params and result: what
// methods_gen.go names for each method in Packages/Wire's OpenRPC documents.
type Method[P, R any] struct{ Name string }

// Notification is a JSON-RPC notification the server sends, and the Go type of its params.
type Notification[P any] struct{ Name string }
