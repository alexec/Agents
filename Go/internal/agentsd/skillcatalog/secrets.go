package skillcatalog

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// Secrets is ~/.agents-secrets/secrets.env (SecretsEnv): NAME=value lines, mode 0600, every
// other line kept as it is.
type Secrets struct{ lines []string }

var secretName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func SecretsPath(home string) string { return filepath.Join(home, ".agents-secrets", "secrets.env") }

// UnreadableSecrets is a secrets.env there that could not be read: nothing is written over
// it, since every other secret in it would go.
type UnreadableSecrets struct{ Path string }

func (e UnreadableSecrets) Error() string {
	return "secrets.env could not be read, so nothing was written to it and the secrets in it are kept. Check its permissions and contents at " +
		e.Path + ", then try again"
}

// LoadSecrets is what is set, for reading: an unreadable file reads as nothing set.
func LoadSecrets(path string) Secrets {
	s, _ := LoadSecretsForChange(path)
	return s
}

// LoadSecretsForChange is what is set, to change and save: a missing file is empty, one
// that does not read is refused.
func LoadSecretsForChange(path string) (Secrets, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Secrets{}, nil
	}
	if err != nil {
		if b, err = os.ReadFile(path); err != nil {
			return Secrets{}, UnreadableSecrets{path}
		}
	}
	if !utf8.Valid(b) {
		return Secrets{}, UnreadableSecrets{path}
	}
	text := string(b)
	if text == "" {
		return Secrets{}, nil
	}
	return Secrets{lines: strings.Split(strings.TrimSuffix(text, "\n"), "\n")}, nil
}

func assignment(line string) (string, string, bool) {
	if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
		return "", "", false
	}
	name, value, ok := strings.Cut(line, "=")
	if !ok || !secretName.MatchString(name) {
		return "", "", false
	}
	return name, value, true
}

// Value is the first value of name.
func (s Secrets) Value(name string) (string, bool) {
	for _, l := range s.lines {
		if n, v, ok := assignment(l); ok && n == name {
			return v, true
		}
	}
	return "", false
}

func (s Secrets) IsSet(name string) bool { _, ok := s.Value(name); return ok }

// Set replaces or appends one name; other lines stay in order.
func (s *Secrets) Set(name, value string) {
	for i, l := range s.lines {
		if n, _, ok := assignment(l); ok && n == name {
			s.lines[i] = name + "=" + value
			return
		}
	}
	s.lines = append(s.lines, name+"="+value)
}

func (s *Secrets) Remove(name string) {
	var out []string
	for _, l := range s.lines {
		if n, _, ok := assignment(l); ok && n == name {
			continue
		}
		out = append(out, l)
	}
	s.lines = out
}

// Save writes it whole, mode 0600, in a folder only its owner can open.
func (s Secrets) Save(path string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	os.Chmod(dir, 0o700)
	text := strings.Join(s.lines, "\n")
	if text != "" && !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	return store.WriteAtomically(path, []byte(text), 0o600)
}
