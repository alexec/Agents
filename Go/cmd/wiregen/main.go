// Command wiregen makes the wire types from Packages/Wire (#1135): the schema
// (daemon.schema.json) and the methods (daemon.openrpc.json, control.openrpc.json).
//
//	wiregen [-root <repo>] [-check]
//
// It writes Go/wire/types_gen.go, Go/wire/methods_gen.go and Web/src/protocol/generated.ts.
// With -check it writes nothing and fails when any of them is not what it would write.
// scripts/wire.sh gen runs it.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

// The files wiregen reads and writes, from the repository root.
const (
	SchemaFile = "Packages/Wire/daemon.schema.json"
	DaemonRPC  = "Packages/Wire/daemon.openrpc.json"
	ControlRPC = "Packages/Wire/control.openrpc.json"
	GoTypes    = "Go/wire/types_gen.go"
	GoMethods  = "Go/wire/methods_gen.go"
	TypeScript = "Web/src/protocol/generated.ts"
)

func main() {
	root := flag.String("root", "..", "the repository")
	check := flag.Bool("check", false, "write nothing; fail if a generated file is stale")
	flag.Parse()
	files, err := generate(*root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "wiregen:", err)
		os.Exit(1)
	}
	stale := false
	for _, path := range []string{GoTypes, GoMethods, TypeScript} {
		full := filepath.Join(*root, path)
		current, _ := os.ReadFile(full)
		if bytes.Equal(current, []byte(files[path])) {
			continue
		}
		if *check {
			fmt.Fprintf(os.Stderr, "wiregen: %s is not what Packages/Wire makes; run scripts/wire.sh gen\n", path)
			stale = true
			continue
		}
		if err := os.WriteFile(full, []byte(files[path]), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "wiregen:", err)
			os.Exit(1)
		}
		fmt.Println("wiregen: wrote", path)
	}
	if stale {
		os.Exit(1)
	}
}

// generate makes every generated file from the documents under root, by path.
func generate(root string) (map[string]string, error) {
	read := func(path string) ([]byte, error) {
		b, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			return nil, err
		}
		return b, nil
	}
	b, err := read(SchemaFile)
	if err != nil {
		return nil, err
	}
	doc, err := readDocument(b)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", SchemaFile, err)
	}
	var rpcs []*RPC
	for _, d := range []struct{ path, target string }{{DaemonRPC, "host"}, {ControlRPC, "control"}} {
		b, err := read(d.path)
		if err != nil {
			return nil, err
		}
		rpc, err := readRPC(b, d.target, doc)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", d.path, err)
		}
		rpcs = append(rpcs, rpc)
	}
	types, err := goTypes(doc)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", GoTypes, err)
	}
	methods, err := goMethods(doc, rpcs)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", GoMethods, err)
	}
	return map[string]string{GoTypes: types, GoMethods: methods, TypeScript: typescript(doc, rpcs)}, nil
}
