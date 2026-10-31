package acp

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	sdk "github.com/coder/acp-go-sdk"
)

// asker answers every permission card with option, and keeps what it was asked.
type asker struct {
	option string
	asked  []sdk.RequestPermissionRequest
}

func (a *asker) Update(sdk.SessionNotification) {}
func (a *asker) Permission(_ context.Context, r sdk.RequestPermissionRequest) string {
	a.asked = append(a.asked, r)
	return a.option
}
func (a *asker) Served(string, string) {}
func (a *asker) Elicitation(context.Context, json.RawMessage) (string, map[string]any) {
	return "cancel", nil
}
func (a *asker) ElicitationComplete(string) {}

// folders is an agent's folder and a folder outside it, with a link in the agent's folder
// to the outside one (proj/x -> ~).
func folders(t *testing.T) (dir, outside string) {
	root := t.TempDir()
	dir, outside = filepath.Join(root, "proj"), filepath.Join(root, "home")
	for _, d := range []string{dir, outside} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(outside, filepath.Join(dir, "x")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "secret"), []byte("s"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir, outside
}

// A link in the agent's folder is followed before the folder check: a read or write
// through it to a path outside is refused, also for a file that does not exist yet.
func TestAFileThroughALinkOutOfTheFolderIsRefused(t *testing.T) {
	dir, outside := folders(t)
	sink := &asker{option: "allow_once"}
	c := &client{sink: sink, dir: dir, terminals: map[string]*terminal{}}
	ctx := context.Background()
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: filepath.Join(dir, "x", ".zshrc"), Content: "evil"}); err == nil {
		t.Fatal("a write through proj/x was let through")
	}
	if _, err := os.Stat(filepath.Join(outside, ".zshrc")); err == nil {
		t.Fatal("the write landed outside the folder")
	}
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: filepath.Join(dir, "x", "new", "f"), Content: "evil"}); err == nil {
		t.Fatal("a write into a new folder through proj/x was let through")
	}
	if _, err := os.Stat(filepath.Join(outside, "new")); err == nil {
		t.Fatal("a folder was made outside the folder")
	}
	if _, err := c.ReadTextFile(ctx, sdk.ReadTextFileRequest{Path: filepath.Join(dir, "x", "secret")}); err == nil {
		t.Fatal("a read through proj/x was let through")
	}
	// A dangling link names a file outside that does not exist yet: writing it would make it.
	if err := os.Symlink(filepath.Join(outside, "made"), filepath.Join(dir, "dangling")); err != nil {
		t.Fatal(err)
	}
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: filepath.Join(dir, "dangling"), Content: "evil"}); err == nil {
		t.Fatal("a write through a dangling link was let through")
	}
	if _, err := os.Stat(filepath.Join(outside, "made")); err == nil {
		t.Fatal("the write through a dangling link landed outside the folder")
	}
	if len(sink.asked) != 0 {
		t.Fatalf("a refused write was asked about: %d", len(sink.asked))
	}
	// Inside the folder, a new file in a new folder is still made.
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: filepath.Join(dir, "a", "b.txt"), Content: "ok"}); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a", "b.txt")); string(b) != "ok" {
		t.Fatalf("%q", b)
	}
}

// A write asks the person first, on the same card any change is asked on, with the diff.
func TestAWriteWaitsForPermission(t *testing.T) {
	dir, _ := folders(t)
	path := filepath.Join(dir, "f.txt")
	if err := os.WriteFile(path, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	refuse := &asker{option: "reject_once"}
	c := &client{sink: refuse, dir: dir, terminals: map[string]*terminal{}}
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: path, Content: "new"}); err == nil {
		t.Fatal("a refused write was done")
	}
	if b, _ := os.ReadFile(path); string(b) != "old" {
		t.Fatalf("a refused write changed the file: %q", b)
	}
	if len(refuse.asked) != 1 {
		t.Fatalf("asked %d times", len(refuse.asked))
	}
	r := refuse.asked[0]
	if r.ToolCall.Kind == nil || *r.ToolCall.Kind != sdk.ToolKindEdit || len(r.ToolCall.Content) != 1 || r.ToolCall.Content[0].Diff == nil {
		t.Fatalf("no diff on the card: %+v", r.ToolCall)
	}
	diff := r.ToolCall.Content[0].Diff
	if diff.NewText != "new" || diff.OldText == nil || *diff.OldText != "old" || diff.Path != path {
		t.Fatalf("%+v", diff)
	}
	// Stopped (no answer) is no.
	c.sink = &asker{option: ""}
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: path, Content: "new"}); err == nil {
		t.Fatal("a write with no answer was done")
	}
	c.sink = &asker{option: "allow_once"}
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: path, Content: "new"}); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); string(b) != "new" {
		t.Fatalf("%q", b)
	}
}

// A file the person just allowed on the runtime's own card is written with no second card,
// once (Antigravity asks with the diff, then writes through fs/write_text_file).
func TestAWriteTheRuntimesCardAllowedIsNotAskedAgain(t *testing.T) {
	dir, _ := folders(t)
	path := filepath.Join(dir, "f.txt")
	sink := &asker{option: "allow"}
	c := &client{sink: sink, dir: dir, terminals: map[string]*terminal{}}
	ctx := context.Background()
	edit := sdk.ToolKindEdit
	if _, err := c.RequestPermission(ctx, sdk.RequestPermissionRequest{
		ToolCall: sdk.ToolCallUpdate{ToolCallId: "t1", Kind: &edit, Content: []sdk.ToolCallContent{sdk.ToolDiffContent(path, "new")}},
		Options:  []sdk.PermissionOption{{OptionId: "allow", Name: "Allow", Kind: sdk.PermissionOptionKindAllowOnce}, {OptionId: "no", Name: "No", Kind: sdk.PermissionOptionKindRejectOnce}},
	}); err != nil {
		t.Fatal(err)
	}
	sink.option = "reject_once"
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: path, Content: "new"}); err != nil {
		t.Fatal(err)
	}
	if len(sink.asked) != 1 {
		t.Fatalf("the allowed write was asked about again: %d", len(sink.asked))
	}
	// Only once.
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: path, Content: "again"}); err == nil {
		t.Fatal("a second write rode on the first card")
	}
	// A card answered no allows nothing.
	sink.option = "no"
	other := filepath.Join(dir, "g.txt")
	_, _ = c.RequestPermission(ctx, sdk.RequestPermissionRequest{
		ToolCall: sdk.ToolCallUpdate{ToolCallId: "t2", Kind: &edit, Content: []sdk.ToolCallContent{sdk.ToolDiffContent(other, "x")}},
		Options:  []sdk.PermissionOption{{OptionId: "allow", Name: "Allow", Kind: sdk.PermissionOptionKindAllowOnce}, {OptionId: "no", Name: "No", Kind: sdk.PermissionOptionKindRejectOnce}},
	})
	sink.option = "reject_once"
	if _, err := c.WriteTextFile(ctx, sdk.WriteTextFileRequest{Path: other, Content: "x"}); err == nil {
		t.Fatal("a write rode on a card answered no")
	}
}

// A terminal's folder is checked as a file is, links followed.
func TestATerminalOutsideTheFolderIsRefused(t *testing.T) {
	dir, outside := folders(t)
	c := &client{sink: &asker{}, dir: dir, terminals: map[string]*terminal{}}
	defer c.closeTerminals()
	ctx := context.Background()
	for _, cwd := range []string{outside, filepath.Join(dir, "x"), "relative"} {
		if _, err := c.CreateTerminal(ctx, sdk.CreateTerminalRequest{Command: "/bin/sh", Args: []string{"-c", "true"}, Cwd: &cwd}); err == nil {
			t.Fatalf("a terminal in %s was started", cwd)
		}
	}
	inside := dir
	if _, err := c.CreateTerminal(ctx, sdk.CreateTerminalRequest{Command: "/bin/sh", Args: []string{"-c", "true"}, Cwd: &inside}); err != nil {
		t.Fatal(err)
	}
}

// A terminal gets the runtime's environment and what it asks for, never the daemon's own.
func TestATerminalGetsTheRuntimesEnvironmentNotTheDaemons(t *testing.T) {
	dir, _ := folders(t)
	t.Setenv("S20261018_DAEMON_ONLY", "1")
	c := &client{sink: &asker{}, dir: dir, terminals: map[string]*terminal{}}
	defer c.closeTerminals()
	r, err := c.CreateTerminal(context.Background(), sdk.CreateTerminalRequest{Command: "/bin/sh", Args: []string{"-c", "true"},
		Env: []sdk.EnvVariable{{Name: "ASKED", Value: "1"}}})
	if err != nil {
		t.Fatal(err)
	}
	env := c.terminals[r.TerminalId].cmd.Env
	if env == nil || slices.ContainsFunc(env, func(kv string) bool { return strings.HasPrefix(kv, "S20261018_DAEMON_ONLY=") }) {
		t.Fatalf("the daemon's environment reached the terminal: %v", env)
	}
	if !slices.Contains(env, "ASKED=1") {
		t.Fatalf("%v", env)
	}
}

// Grok sends `/bin/bash -lc '…'` as one command field instead of separate argv fields.
func TestAGrokTerminalRunsItsSingleShellCommandField(t *testing.T) {
	dir, _ := folders(t)
	c := &client{sink: &asker{}, dir: dir, runtime: "Grok", terminals: map[string]*terminal{}}
	defer c.closeTerminals()

	r, err := c.CreateTerminal(context.Background(), sdk.CreateTerminalRequest{Command: "/bin/bash -lc 'printf grok-terminal-ok'"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.WaitForTerminalExit(context.Background(), sdk.WaitForTerminalExitRequest{TerminalId: r.TerminalId}); err != nil {
		t.Fatal(err)
	}
	out, err := c.TerminalOutput(context.Background(), sdk.TerminalOutputRequest{TerminalId: r.TerminalId})
	if err != nil {
		t.Fatal(err)
	}
	if out.Output != "grok-terminal-ok" || out.ExitStatus == nil || out.ExitStatus.ExitCode == nil || *out.ExitStatus.ExitCode != 0 {
		t.Fatalf("terminal output = %+v", out)
	}
}
