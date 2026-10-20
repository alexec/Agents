package agentsd

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// TestLanguageServerHelper is a fake language server when AGENTS_FAKE_LSP is set: each line
// holding TODO is a warning, and it asks the client for its configuration once.
func TestLanguageServerHelper(t *testing.T) {
	if os.Getenv("AGENTS_FAKE_LSP") != "1" {
		return
	}
	in := bufio.NewReader(os.Stdin)
	write := func(m any) {
		b, _ := json.Marshal(m)
		fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(b), b)
	}
	for {
		body, err := readFrame(in)
		if err != nil {
			os.Exit(0)
		}
		var m struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params struct {
				TextDocument struct {
					URI  string `json:"uri"`
					Text string `json:"text"`
				} `json:"textDocument"`
				ContentChanges []struct {
					Text string `json:"text"`
				} `json:"contentChanges"`
			} `json:"params"`
		}
		_ = json.Unmarshal(body, &m)
		switch m.Method {
		case "initialize":
			write(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": map[string]any{"capabilities": map[string]any{}}})
			write(map[string]any{"jsonrpc": "2.0", "id": 99, "method": "workspace/configuration",
				"params": map[string]any{"items": []any{map[string]any{}}}})
		case "textDocument/completion":
			write(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": map[string]any{"isIncomplete": false, "items": []any{
				map[string]any{"label": "Println", "insertText": "Println(${1:a})", "detail": "func(a ...any)"},
				map[string]any{"label": "Sprint", "insertText": "Sprint(a: , b: )"},
				map[string]any{"label": "Printf"},
			}}})
		case "textDocument/didOpen", "textDocument/didChange":
			if os.Getenv("AGENTS_FAKE_LSP_SILENT") == "1" {
				continue // still starting: it says nothing (#1687)
			}
			text := m.Params.TextDocument.Text
			if len(m.Params.ContentChanges) > 0 {
				text = m.Params.ContentChanges[0].Text
			}
			diags := []any{}
			for i, line := range strings.Split(text, "\n") {
				if at := strings.Index(line, "TODO"); at >= 0 {
					diags = append(diags, map[string]any{"range": map[string]any{"start": map[string]any{"line": i, "character": at},
						"end": map[string]any{"line": i, "character": at + 4}}, "severity": 2, "message": "a TODO is left", "source": "fake"})
				}
			}
			write(map[string]any{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
				"params": map[string]any{"uri": m.Params.TextDocument.URI, "diagnostics": diags}})
		}
	}
}

// files/diagnostics' client end (#844): a server started on the first ask and kept, the text
// the editor holds checked rather than the disk's, problems by line and column from 1, and
// a language with no server, or none installed, said.
func TestLanguageServerDiagnostics(t *testing.T) {
	t.Setenv("AGENTS_FAKE_LSP", "1")
	was := installedCommand
	installedCommand = func(s languageServerSpec) []string {
		if s.name == "gopls" {
			return []string{os.Args[0], "-test.run=^TestLanguageServerHelper$"}
		}
		return nil
	}
	defer func() { installedCommand = was }()
	pool := &languageServers{running: map[string]*languageServer{}}
	defer pool.stopAll()
	root := t.TempDir()
	file := filepath.Join(root, "main.go")
	os.WriteFile(file, []byte("package main\n// TODO on disk\n"), 0o644)

	got := pool.diagnose(root, file, nil)
	if len(got.Diagnostics) != 1 || got.Diagnostics[0].Line != 2 || got.Diagnostics[0].Column != 4 ||
		got.Diagnostics[0].Severity != "warning" || *got.Server != "gopls" {
		t.Fatalf("from disk %+v", got)
	}
	held := "package main\n\nfunc main() {} // TODO\n// TODO too\n"
	got = pool.diagnose(root, file, &held)
	if len(got.Diagnostics) != 2 || got.Diagnostics[0].Line != 3 || got.Diagnostics[1].Line != 4 {
		t.Fatalf("as held %+v", got)
	}
	if n := pool.count(); n != 1 {
		t.Fatalf("one server for the folder, kept: %d", n)
	}
	if got := pool.diagnose(root, filepath.Join(root, "notes.txt"), nil); got.Reason == nil {
		t.Fatal("a text file has no server")
	}
	if got := pool.diagnose(root, filepath.Join(root, "app.py"), nil); got.Reason == nil || !strings.Contains(*got.Reason, "not installed") {
		t.Fatalf("pyright is not here: %+v", got)
	}
}

// A server that has said nothing yet is starting, not clean (#1687): its empty list comes with
// "Starting gopls…", and it is kept for the next ask.
func TestLanguageServerStartingIsNotNoProblems(t *testing.T) {
	t.Setenv("AGENTS_FAKE_LSP", "1")
	t.Setenv("AGENTS_FAKE_LSP_SILENT", "1")
	was := installedCommand
	installedCommand = func(s languageServerSpec) []string {
		if s.name == "gopls" {
			return []string{os.Args[0], "-test.run=^TestLanguageServerHelper$"}
		}
		return nil
	}
	defer func() { installedCommand = was }()
	pool := &languageServers{running: map[string]*languageServer{}}
	defer pool.stopAll()
	root := t.TempDir()
	file := filepath.Join(root, "main.go")
	if err := os.WriteFile(file, []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := pool.diagnose(root, file, nil)
	if got.Reason == nil || *got.Reason != "Starting gopls…" || len(got.Diagnostics) != 0 || *got.Server != "gopls" {
		t.Fatalf("starting %+v", got)
	}
	if n := pool.count(); n != 1 {
		t.Fatalf("a starting server is kept: %d", n)
	}
}

func TestReadFrame(t *testing.T) {
	r := bufio.NewReader(strings.NewReader("Content-Type: x\r\nContent-Length: 2\r\n\r\n{}rest"))
	if b, err := readFrame(r); err != nil || string(b) != "{}" {
		t.Fatalf("%q %v", b, err)
	}
}

// files/complete's client end (#844): the server's items, a snippet cut at its first
// placeholder, the label alone when that is all there is to write.
func TestLanguageServerCompletion(t *testing.T) {
	t.Setenv("AGENTS_FAKE_LSP", "1")
	was := installedCommand
	installedCommand = func(s languageServerSpec) []string {
		return []string{os.Args[0], "-test.run=^TestLanguageServerHelper$"}
	}
	defer func() { installedCommand = was }()
	pool := &languageServers{running: map[string]*languageServer{}}
	defer pool.stopAll()
	root := t.TempDir()
	got := pool.complete(context.Background(), root, filepath.Join(root, "main.go"), wire.FileCompletionRequest{
		Text: "package main\nimport \"fmt\"\nfunc main() { fmt.P }\n", Line: 3, Column: 20})
	if len(got.Items) != 3 || got.Items[0].Label != "Println" || got.Items[0].Insert == nil || *got.Items[0].Insert != "Println(" ||
		got.Items[1].Insert == nil || *got.Items[1].Insert != "Sprint(" || got.Items[2].Insert != nil || got.Items[0].Detail == nil {
		t.Fatalf("%+v", got)
	}
}

// A server that starts slowly holds up no other (#1652): a completion from the running gopls
// answers while sourcekit-lsp starts, and a second ask for sourcekit-lsp waits for the same
// start rather than starting another.
func TestSlowStartHoldsUpNoOtherServer(t *testing.T) {
	t.Setenv("AGENTS_FAKE_LSP", "1")
	var swiftStarts atomic.Int32
	was := installedCommand
	installedCommand = func(s languageServerSpec) []string {
		if s.name == "sourcekit-lsp" {
			swiftStarts.Add(1)
			return []string{"/bin/sleep", "3"} // never answers initialize, and ends in 3 s
		}
		return []string{os.Args[0], "-test.run=^TestLanguageServerHelper$"}
	}
	defer func() { installedCommand = was }()
	pool := &languageServers{running: map[string]*languageServer{}}
	defer pool.stopAll()
	root := t.TempDir()
	goFile := filepath.Join(root, "main.go")
	ask := wire.FileCompletionRequest{Text: "package main\nimport \"fmt\"\nfunc main() { fmt.P }\n", Line: 3, Column: 20}
	if got := pool.complete(context.Background(), root, goFile, ask); len(got.Items) == 0 {
		t.Fatalf("gopls: %+v", got)
	}

	var slow sync.WaitGroup
	reasons := make(chan *string, 2)
	for range 2 {
		slow.Go(func() {
			swift := "let a = 1\n"
			reasons <- pool.diagnose(root, filepath.Join(root, "main.swift"), &swift).Reason
		})
	}
	for deadline := time.Now().Add(2 * time.Second); ; {
		pool.mu.Lock()
		starting := len(pool.starting)
		pool.mu.Unlock()
		if starting == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("sourcekit-lsp did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	began := time.Now()
	if got := pool.complete(context.Background(), root, goFile, ask); len(got.Items) == 0 {
		t.Fatalf("gopls while sourcekit-lsp starts: %+v", got)
	}
	if took := time.Since(began); took > time.Second {
		t.Fatalf("gopls waited %v for sourcekit-lsp to start", took)
	}
	slow.Wait()
	close(reasons)
	for reason := range reasons {
		if reason == nil || !strings.Contains(*reason, "did not start") {
			t.Fatalf("both asks have the start's failure: %v", reason)
		}
	}
	if n := swiftStarts.Load(); n != 1 {
		t.Fatalf("sourcekit-lsp started %d times", n)
	}
}
