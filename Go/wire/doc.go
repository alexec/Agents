// Package wire is every type on the wire between the clients, the hosts (agentsd) and the
// control plane (#1135).
//
// types_gen.go and methods_gen.go are made from Packages/Wire by scripts/wire.sh gen: change
// the schema there, never the generated files. The five meaning-types (meaning.go) and the
// method types (rpc.go) are written by hand.
package wire
