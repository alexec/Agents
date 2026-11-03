// Package codespacessh is ssh to a GitHub codespace through gh: the cs.<name>.<branch>
// hosts `gh codespace ssh --config` writes, whose ProxyCommand is gh, kept in an ssh config
// between lines of ours. agentsd keeps one block for every codespace (PrepareSSH); a control
// plane keeps a block for each codespace it reaches, with the provider's token (#3347).
package codespacessh

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
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

// GH is the gh to run.
var GH = "gh"

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
	cmd := exec.CommandContext(ctx, GH, "codespace", "ssh", "--config", "-c", name)
	cmd.Env = append(withoutTokens(env), Token(token))
	var stderr strings.Builder
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		if errors.Is(err, exec.ErrNotFound) || errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("This control plane has no GitHub CLI (gh) to reach the codespace %s over SSH", name)
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
