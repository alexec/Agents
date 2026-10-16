// Package demo is a small stdio MCP server, `agentsd mcp-demo`, for walking hosted MCP:
// its one tool says which process answered and how many calls it has had, so two sessions
// sharing one hosted process can be seen to.
package demo

import (
	"context"
	"fmt"
	"os"
	"sync/atomic"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var calls atomic.Int64

type factsIn struct{}

func Serve() error {
	started := time.Now()
	s := mcp.NewServer(&mcp.Implementation{Name: "host-facts", Version: "1"}, nil)
	mcp.AddTool(s, &mcp.Tool{Name: "host_facts", Description: "Which process answered: its pid, how long it has run, and how many calls it has had."},
		func(ctx context.Context, r *mcp.CallToolRequest, in factsIn) (*mcp.CallToolResult, any, error) {
			n := calls.Add(1)
			host, _ := os.Hostname()
			text := fmt.Sprintf("host %s, pid %d, up %s, call number %d", host, os.Getpid(), time.Since(started).Round(time.Second), n)
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil, nil
		})
	return s.Run(context.Background(), &mcp.StdioTransport{})
}
