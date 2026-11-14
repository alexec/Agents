// Command wiregen makes the wire types from Packages/Wire (#1135): the schema
// (schema/*.schema.json) and the methods (daemon.openrpc.json and daemon/*.openrpc.json, control.openrpc.json).
//
//	wiregen [-root <repo>] [-check]
//
// It writes Go/wire/types_gen.go, Go/wire/methods_gen.go and Web/src/protocol/generated.ts,
// and the capabilities for Go, TypeScript and Swift (#1748).
// With -check it writes nothing and fails when any of them is not what it would write.
// scripts/wire.sh gen runs it.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// The files wiregen reads and writes, from the repository root.
const (
	SchemaDir  = "Packages/Wire/schema"              // one *.schema.json per domain (#5380)
	DaemonRPC  = "Packages/Wire/daemon.openrpc.json" // the host's header: info, declared capabilities, errors
	DaemonDir  = "Packages/Wire/daemon"              // its methods, one *.openrpc.json per group (#5381)
	ControlRPC = "Packages/Wire/control.openrpc.json"
	GoTypes    = "Go/wire/types_gen.go"
	GoMethods  = "Go/wire/methods_gen.go"
	TypeScript = "Web/src/protocol/generated.ts"
	// The app's own tools, as Swift's AppService lists them (AppToolsFileTests), copied in
	// beside the types so a Go host can embed them.
	AppTools   = "Packages/Wire/app-tools.json"
	GoAppTools = "Go/wire/app-tools.json"
	// The app's events, as Swift's EventCatalogue has them, copied in the same way.
	Events   = "Packages/Wire/event-catalogue.json"
	GoEvents = "Go/wire/event-catalogue.json"
	// The capabilities, x-capability on each method (#1748), for each language.
	GoCapabilities    = "Go/wire/capabilities_gen.go"
	TSCapabilities    = "Web/src/protocol/capabilities.generated.ts"
	SwiftCapabilities = "Packages/AgentsKit/Sources/AgentsKitCore/Daemon/Capabilities.generated.swift"
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
	for _, path := range []string{GoTypes, GoMethods, TypeScript, GoAppTools, GoEvents, GoCapabilities, TSCapabilities, SwiftCapabilities} {
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

// withMethodFiles adds the methods of every DaemonDir file to the host document's header, in
// name order (each file keeps its own in name order, and readRPC checks the whole).
func withMethodFiles(root string, header []byte) ([]byte, error) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(header, &top); err != nil {
		return nil, fmt.Errorf("%s: %w", DaemonRPC, err)
	}
	paths, err := filepath.Glob(filepath.Join(root, DaemonDir, "*.openrpc.json"))
	if err != nil || len(paths) == 0 {
		return nil, fmt.Errorf("%s: no method files", DaemonDir)
	}
	type method struct {
		name string
		raw  json.RawMessage
	}
	var all []method
	seen := map[string]string{}
	for _, path := range paths {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var part struct {
			Methods []json.RawMessage `json:"methods"`
		}
		if err := json.Unmarshal(b, &part); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		var names []string
		for _, raw := range part.Methods {
			var n struct {
				Name string `json:"name"`
			}
			if err := json.Unmarshal(raw, &n); err != nil {
				return nil, fmt.Errorf("%s: %w", path, err)
			}
			if other, ok := seen[n.Name]; ok {
				return nil, fmt.Errorf("%s: method %s is also in %s", path, n.Name, other)
			}
			seen[n.Name] = path
			names = append(names, n.Name)
			all = append(all, method{n.Name, raw})
		}
		if err := inNameOrder("methods", names); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].name < all[j].name })
	raws := make([]json.RawMessage, len(all))
	for i, m := range all {
		raws[i] = m.raw
	}
	var err2 error
	if top["methods"], err2 = json.Marshal(raws); err2 != nil {
		return nil, err2
	}
	return json.Marshal(top)
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
	paths, err := filepath.Glob(filepath.Join(root, SchemaDir, "*.schema.json"))
	if err != nil || len(paths) == 0 {
		return nil, fmt.Errorf("%s: no schema files", SchemaDir)
	}
	sort.Strings(paths)
	var parts []Part
	for _, path := range paths {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		parts = append(parts, Part{Path: filepath.ToSlash(path), Data: b})
	}
	doc, err := readDocument(parts...)
	if err != nil {
		return nil, err
	}
	var rpcs []*RPC
	for _, d := range []struct{ path, target string }{{DaemonRPC, "host"}, {ControlRPC, "control"}} {
		b, err := read(d.path)
		if err != nil {
			return nil, err
		}
		if d.path == DaemonRPC {
			if b, err = withMethodFiles(root, b); err != nil {
				return nil, err
			}
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
	caps, err := goCapabilities(rpcs)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", GoCapabilities, err)
	}
	tools, err := read(AppTools)
	if err != nil {
		return nil, err
	}
	events, err := read(Events)
	if err != nil {
		return nil, err
	}
	return map[string]string{GoTypes: types, GoMethods: methods, TypeScript: typescript(doc, rpcs), GoAppTools: string(tools),
		GoEvents: string(events), GoCapabilities: caps, TSCapabilities: tsCapabilities(rpcs), SwiftCapabilities: swiftCapabilities(rpcs)}, nil
}
