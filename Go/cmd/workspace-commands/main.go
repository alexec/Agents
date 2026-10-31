// workspace-commands: the command machine provider (#691), an MCP server on stdio, in Go
// since #1364. The control plane runs it from beside itself for a provider of kind
// "commands". Its configuration is the JSON in WORKSPACE_COMMANDS_CONFIG
// (specs/691-workspace-providers/contracts/command-provider.md); any secret its commands use
// comes in as another environment variable.
//
//	workspace-commands               serve on stdio
//	workspace-commands --version     (or -v)
package main

import (
	"fmt"
	"log"
	"os"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/workspacecommands"
)

func main() {
	log.SetFlags(0)
	for _, arg := range os.Args[1:] {
		if arg == "--version" || arg == "-v" || arg == "-version" {
			fmt.Println("workspace-commands " + buildinfo.String())
			return
		}
	}
	config, err := workspacecommands.Parse(os.Getenv("WORKSPACE_COMMANDS_CONFIG"))
	if err != nil {
		log.Print("workspace-commands: ", err)
		os.Exit(2)
	}
	server := workspacecommands.NewServer(config, workspacecommands.StandardTiming, workspacecommands.Shell, buildinfo.Version)
	log.Printf("workspace-commands %s on stdio", buildinfo.String())
	if err := server.Serve(os.Stdin, os.Stdout); err != nil {
		log.Print("workspace-commands: ", err)
		os.Exit(1)
	}
}
