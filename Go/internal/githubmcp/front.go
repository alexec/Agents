package githubmcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"sync"

	ghErrors "github.com/github/github-mcp-server/v2/pkg/errors"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The front: MCP's stdio transport, one JSON-RPC message a line. It answers events/list and
// events/poll itself, and hands every other message to the official server as it came, and
// that server's messages back as they come. MCP's SDKs have no events (a working-group
// draft), so the front also adds the `events` capability and the events' words to the
// official server's answer to initialize.

// Instructions are the events' words, put before the official server's own.
const Instructions = "This repo's pull requests, their CI, and its issues as events, polled as the person signed in to GitHub in Agents: " +
	"checks.failed, checks.passed, pr.opened, pr.merged, pr.conflicted, pr.closed, issue.opened, issue.labelled, issue.commented, issue.closed, " +
	"and CodeRabbit's review.posted and review.comment. " +
	"coderabbit_review, coderabbit_reply and coderabbit_resolve speak to CodeRabbit on a pull request, as the person. " +
	"show_pull_requests, show_issues and show_pull_request show a page to the person. " +
	"Merging and reviewing a pull request are a person's, from its page: those tools are not for agents."

// maxLine is the longest message read; a longer one ends the connection, as the SDK's does.
const maxLine = 64 << 20

// Front serves one client over stdio.
type Front struct {
	Events   *Events
	Upstream *mcp.Server
	Version  string
	Logger   *slog.Logger
}

type message struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
}

// Serve reads in until it ends and writes to out, then stops the official server.
func (f *Front) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	ctx, cancel := context.WithCancel(ghErrors.ContextWithGitHubErrors(ctx))
	defer cancel()
	toUpstream, upstreamIn := io.Pipe()
	upstreamOut, fromUpstream := io.Pipe()
	upstreamDone := make(chan error, 1)
	go func() {
		upstreamDone <- f.Upstream.Run(ctx, &mcp.IOTransport{Reader: toUpstream, Writer: fromUpstream})
		_ = fromUpstream.Close()
	}()

	var writeMu sync.Mutex
	write := func(line []byte) {
		writeMu.Lock()
		defer writeMu.Unlock()
		_, _ = out.Write(append(bytes.TrimRight(line, "\r\n"), '\n'))
	}
	var initMu sync.Mutex
	initIDs := map[string]bool{}

	relayed := make(chan struct{})
	go func() {
		defer close(relayed)
		r := bufio.NewReaderSize(upstreamOut, 64<<10)
		for {
			line, err := readLine(r)
			if len(line) > 0 {
				var m message
				if json.Unmarshal(line, &m) == nil && len(m.ID) > 0 && m.Method == "" && len(m.Result) > 0 {
					initMu.Lock()
					isInit := initIDs[string(m.ID)]
					delete(initIDs, string(m.ID))
					initMu.Unlock()
					if isInit {
						line = f.initialized(line)
					}
				}
				write(line)
			}
			if err != nil {
				return
			}
		}
	}()

	var answering sync.WaitGroup
	r := bufio.NewReaderSize(in, 64<<10)
	var readErr error
	for {
		line, err := readLine(r)
		if len(bytes.TrimSpace(line)) > 0 {
			var m message
			parsed := json.Unmarshal(line, &m) == nil
			switch {
			case parsed && (m.Method == "events/list" || m.Method == "events/poll"):
				if len(m.ID) == 0 {
					break // a notification is answered with nothing
				}
				answering.Add(1)
				go func() {
					defer answering.Done()
					write(f.answer(ctx, m))
				}()
			default:
				if parsed && m.Method == "initialize" && len(m.ID) > 0 {
					initMu.Lock()
					initIDs[string(m.ID)] = true
					initMu.Unlock()
				}
				if _, werr := upstreamIn.Write(append(bytes.TrimRight(line, "\r\n"), '\n')); werr != nil {
					readErr = werr
				}
			}
		}
		if err != nil || readErr != nil {
			if err != nil && err != io.EOF {
				readErr = err
			}
			break
		}
	}
	answering.Wait()
	_ = upstreamIn.Close()
	<-relayed
	cancel()
	<-upstreamDone
	return readErr
}

// readLine is the next line without its newline; err is set at the end.
func readLine(r *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		part, more, err := r.ReadLine()
		line = append(line, part...)
		if len(line) > maxLine {
			return nil, io.ErrShortBuffer
		}
		if err != nil {
			return line, err
		}
		if !more {
			return line, nil
		}
	}
}

// answer is the line answering an events request.
func (f *Front) answer(ctx context.Context, m message) []byte {
	reply := map[string]any{"jsonrpc": "2.0", "id": m.ID}
	if m.Method == "events/list" {
		reply["result"] = eventsList()
	} else if result, err := f.Events.Poll(ctx, m.Params); err != nil {
		reply["error"] = err
	} else {
		reply["result"] = result
	}
	line, err := json.Marshal(reply)
	if err != nil {
		line, _ = json.Marshal(map[string]any{"jsonrpc": "2.0", "id": m.ID,
			"error": rpcError{Code: -32603, Message: err.Error()}})
	}
	return line
}

// initialized is the official server's answer to initialize with the events added: the
// capability, which the Agents daemon looks for before it lists them, their words, and this
// server's name.
func (f *Front) initialized(line []byte) []byte {
	var reply map[string]json.RawMessage
	if json.Unmarshal(line, &reply) != nil {
		return line
	}
	var result map[string]json.RawMessage
	if json.Unmarshal(reply["result"], &result) != nil {
		return line
	}
	capabilities := map[string]json.RawMessage{}
	_ = json.Unmarshal(result["capabilities"], &capabilities)
	capabilities["events"] = json.RawMessage(`{"listChanged":false}`)
	result["capabilities"], _ = json.Marshal(capabilities)
	var theirs string
	_ = json.Unmarshal(result["instructions"], &theirs)
	words := Instructions
	if theirs != "" {
		words += "\n\n" + theirs
	}
	result["instructions"], _ = json.Marshal(words)
	result["serverInfo"], _ = json.Marshal(map[string]string{"name": "github-mcp", "title": "GitHub", "version": f.Version})
	reply["result"], _ = json.Marshal(result)
	out, err := json.Marshal(reply)
	if err != nil {
		return line
	}
	return out
}
