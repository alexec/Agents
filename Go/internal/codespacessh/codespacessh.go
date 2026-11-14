// Package codespacessh is ssh to a GitHub codespace through gh: the cs.<name>.<branch>
// hosts `gh codespace ssh --config` writes, whose ProxyCommand is gh, kept in an ssh config
// between lines of ours. agentsd keeps one block for every codespace (PrepareSSH); a control
// plane keeps a block for each codespace it reaches, with the provider's token (#3347).
package codespacessh

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
)

const (
	beginLine = "# BEGIN Agents Codespaces SSH"
	endLine   = "# END Agents Codespaces SSH"
)

// Begin and End are the lines around a block: label "" is agentsd's one block.
func Begin(label string) string { return marker(beginLine, label) }
func End(label string) string   { return marker(endLine, label) }

func marker(line, label string) string {
	if label == "" {
		return line
	}
	return line + " " + label
}

var mu sync.Mutex

// Merge puts generated in the ssh config at path, in place of what an earlier Merge with
// the same label put there, and leaves every other line as it was.
func Merge(path, label string, generated []byte) error {
	config := strings.TrimSpace(string(generated))
	if config == "" {
		return fmt.Errorf("GitHub CLI returned no Codespaces SSH configuration")
	}
	mu.Lock()
	defer mu.Unlock()

	current, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("Could not read SSH configuration")
	}
	block := Begin(label) + "\n" + config + "\n" + End(label)
	text := replace(string(current), Begin(label), End(label), block)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("Could not prepare the SSH configuration folder")
	}
	mode := os.FileMode(0o600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	if err := store.WriteAtomically(path, []byte(text), mode); err != nil {
		return fmt.Errorf("Could not save the Codespaces SSH configuration")
	}
	return nil
}

// Remove takes the block for label out of the ssh config at path, as Merge put it there,
// and leaves every other line as it was (#3746). It says whether there was one; with
// none, the file is not written.
func Remove(path, label string) (bool, error) {
	mu.Lock()
	defer mu.Unlock()
	current, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("Could not read SSH configuration")
	}
	lines := strings.Split(string(current), "\n")
	first, last := -1, -1
	for i, line := range lines {
		if first < 0 && line == Begin(label) {
			first = i
		} else if first >= 0 && line == End(label) {
			last = i
			break
		}
	}
	if first < 0 || last < 0 {
		return false, nil
	}
	// The blank line Merge put before the block goes with it.
	if first > 0 && lines[first-1] == "" {
		first--
	}
	text := strings.Join(append(append([]string{}, lines[:first]...), lines[last+1:]...), "\n")
	if strings.TrimSpace(text) == "" {
		text = ""
	}
	mode := os.FileMode(0o600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	if err := store.WriteAtomically(path, []byte(text), mode); err != nil {
		return false, fmt.Errorf("Could not save the SSH configuration")
	}
	return true, nil
}

// replace puts block in place of the lines from begin to end, each a whole line, or after
// the text when there are none.
func replace(text, begin, end, block string) string {
	lines := strings.Split(text, "\n")
	first, last := -1, -1
	for i, line := range lines {
		switch {
		case first < 0 && line == begin:
			first = i
		case first >= 0 && line == end:
			last = i
		}
		if last >= 0 {
			break
		}
	}
	if first >= 0 && last >= 0 {
		return strings.Join(append(append(append([]string{}, lines[:first]...), block), lines[last+1:]...), "\n")
	}
	text = strings.TrimRight(text, "\n")
	if text != "" {
		text += "\n\n"
	}
	return text + block + "\n"
}

// Has is whether the ssh config at path has a block for label with a Host line for
// destination.
func Has(path, label, destination string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	inside := false
	for _, line := range strings.Split(string(data), "\n") {
		switch {
		case line == Begin(label):
			inside = true
		case line == End(label):
			inside = false
		case inside && strings.TrimSpace(line) == "Host "+destination:
			return true
		}
	}
	return false
}

// Token is the environment gh takes the provider's token from, for gh alone: a control
// plane is never signed in to gh (#3347).
func Token(token string) string { return "GH_TOKEN=" + token }

// GH is the gh to run when Find is nil or finds none.
var GH = "gh"

// Find, when set, is where gh is: a daemon started by launchd has only
// /usr/bin:/bin:/usr/sbin:/sbin on its PATH, so a gh in /usr/local/bin or Homebrew's
// folder is not found by name. It says "" when it finds none.
var Find func() string

// gh is the gh to run: what Find says, else GH.
func gh() string {
	if Find != nil {
		if path := Find(); path != "" {
			return path
		}
	}
	return GH
}

// prepareTimeout bounds `gh codespace ssh --config`, which connects to the codespace to
// learn its user.
const prepareTimeout = 60 * time.Second

// Prepare is the control plane's PrepareSSH (#3347): the codespace name, reached as
// destination, gets a block of its own in the ssh config at path, from
// `gh codespace ssh --config -c <name>` run with token. Nothing is done when the block is
// there already. env is the environment gh runs in, less any token of its own.
func Prepare(ctx context.Context, path, name, destination, token string, env []string) error {
	if Has(path, name, destination) {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, prepareTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, gh(), "codespace", "ssh", "--config", "-c", name)
	cmd.Env = append(withoutTokens(env), Token(token))
	var stderr strings.Builder
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		if errors.Is(err, exec.ErrNotFound) || errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("This machine has no GitHub CLI (gh) to reach the codespace %s over SSH", name)
		}
		said := strings.TrimSpace(stderr.String())
		if said == "" {
			said = err.Error()
		}
		return fmt.Errorf("GitHub CLI could not prepare SSH to the codespace %s: %s", name, said)
	}
	return Merge(path, name, output)
}

// withoutTokens is env less what gh would take over GH_TOKEN.
func withoutTokens(env []string) []string {
	var out []string
	for _, kv := range env {
		key, _, _ := strings.Cut(kv, "=")
		if key == "GH_TOKEN" || key == "GITHUB_TOKEN" || key == "GH_ENTERPRISE_TOKEN" || key == "GITHUB_ENTERPRISE_TOKEN" {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// KeepAwakeEvery is how often KeepAwake's session says a line: well under GitHub's smallest
// idle timeout, 5 minutes (#4637).
var KeepAwakeEvery = 4 * time.Minute

// KeepAwake holds `gh codespace ssh -c <name>`, run with token, saying a line each
// KeepAwakeEvery until ctx ends (#4637). GitHub counts the session's output as use, so the
// codespace is not stopped by its idle timeout while the session runs; tested on a real
// codespace with a 5-minute timeout. It returns when the session ends: nil when ctx ended it.
func KeepAwake(ctx context.Context, name, token string, env []string) error {
	every := int(KeepAwakeEvery / time.Second)
	if every < 1 {
		every = 1
	}
	cmd := exec.CommandContext(ctx, gh(), "codespace", "ssh", "-c", name, "--",
		fmt.Sprintf("while :; do echo keepalive; sleep %d; done", every))
	cmd.Env = append(withoutTokens(env), Token(token))
	cmd.Stdout = io.Discard
	var stderr strings.Builder
	cmd.Stderr = &stderr
	// A cancelled session's gh gets a moment to close its connection.
	cmd.WaitDelay = 5 * time.Second
	err := cmd.Run()
	if ctx.Err() != nil {
		return nil
	}
	if errors.Is(err, exec.ErrNotFound) || errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("This machine has no GitHub CLI (gh) to keep the codespace %s awake", name)
	}
	said := strings.TrimSpace(stderr.String())
	if said == "" && err != nil {
		said = err.Error()
	}
	if said == "" {
		said = "the session ended"
	}
	return fmt.Errorf("GitHub CLI's session to keep the codespace %s awake ended: %s", name, said)
}
