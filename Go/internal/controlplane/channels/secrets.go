package channels

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

// SecretsFolder is PersonalSecrets.folder: the person's secrets, apart from ~/.agents.
const SecretsFolder = ".agents-secrets"

// SecretsPath is PersonalSecrets.url(home:file:): <home>/.agents-secrets/<file>.
func SecretsPath(home, file string) string { return filepath.Join(home, SecretsFolder, file) }

// SecretsEnv is SecretsEnv: KEY=value lines, mode 0600. Lines that are not an assignment
// (comments, blanks, anything else) are kept as they are.
type SecretsEnv struct {
	lines []envLine
}

// envLine is SecretsEnv.Line: an assignment, or other text kept whole.
type envLine struct {
	name, value string
	other       string
	assignment  bool
}

// UnreadableError is SecretsEnv.Unreadable: a file that is there and could not be read.
// Nothing is written over it.
type UnreadableError struct{ Path string }

func (e *UnreadableError) Error() string {
	return "secrets.env could not be read, so nothing was written to it and the secrets in it are kept. Check its permissions and contents at " + e.Path + ", then try again"
}

// LoadSecrets is SecretsEnv.load(from:): for reading only, an unreadable file is empty.
func LoadSecrets(path string) SecretsEnv {
	env, err := LoadSecretsForChange(path)
	if err != nil {
		return SecretsEnv{}
	}
	return env
}

// LoadSecretsForChange is SecretsEnv.loadForChange(from:): a missing file is empty; one
// that is there and does not read (after one more try) is refused.
func LoadSecretsForChange(path string) (SecretsEnv, error) {
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return SecretsEnv{}, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		data, err = os.ReadFile(path)
	}
	if err != nil || !utf8.Valid(data) {
		return SecretsEnv{}, &UnreadableError{Path: path}
	}
	return ParseSecrets(string(data)), nil
}

var envName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// ParseSecrets is SecretsEnv.parse.
func ParseSecrets(text string) SecretsEnv {
	raws := strings.Split(text, "\n")
	// The newline that ends the file ends its last line; it is not a blank line.
	if strings.HasSuffix(text, "\n") {
		raws = raws[:len(raws)-1]
	}
	var env SecretsEnv
	for _, raw := range raws {
		eq := strings.IndexByte(raw, '=')
		if strings.HasPrefix(raw, "#") || strings.Trim(raw, " \t") == "" || eq < 0 || !envName.MatchString(raw[:eq]) {
			env.lines = append(env.lines, envLine{other: raw})
			continue
		}
		env.lines = append(env.lines, envLine{name: raw[:eq], value: raw[eq+1:], assignment: true})
	}
	return env
}

// Names is SecretsEnv.names: names that have a value, in file order.
func (e SecretsEnv) Names() []string {
	var names []string
	for _, l := range e.lines {
		if l.assignment {
			names = append(names, l.name)
		}
	}
	return names
}

// Value is SecretsEnv.value(of:).
func (e SecretsEnv) Value(name string) (string, bool) {
	for _, l := range e.lines {
		if l.assignment && l.name == name {
			return l.value, true
		}
	}
	return "", false
}

// Set is SecretsEnv.set(_:value:): replace or append one name; other lines stay in order.
func (e *SecretsEnv) Set(name, value string) {
	for i, l := range e.lines {
		if l.assignment && l.name == name {
			e.lines[i].value = value
			return
		}
	}
	e.lines = append(e.lines, envLine{name: name, value: value, assignment: true})
}

// Remove is SecretsEnv.remove.
func (e *SecretsEnv) Remove(name string) {
	kept := e.lines[:0]
	for _, l := range e.lines {
		if !(l.assignment && l.name == name) {
			kept = append(kept, l)
		}
	}
	e.lines = kept
}

// Text is SecretsEnv.text(): the file's contents, ending in a newline when not empty.
func (e SecretsEnv) Text() string {
	parts := make([]string, len(e.lines))
	for i, l := range e.lines {
		if l.assignment {
			parts[i] = l.name + "=" + l.value
		} else {
			parts[i] = l.other
		}
	}
	out := strings.Join(parts, "\n")
	if out != "" && !strings.HasSuffix(out, "\n") {
		out += "\n"
	}
	return out
}

// Save is SecretsEnv.save(to:) with PersonalSecrets.write: the folder made (or put back)
// 0700, and the file written whole, 0600 from the start, by a synced temporary file
// renamed over the old one.
func (e SecretsEnv) Save(path string) error {
	folder := filepath.Dir(path)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(folder, 0o700); err != nil {
		return err
	}
	temporary := filepath.Join(folder, "."+filepath.Base(path)+"."+NewUUID()+".tmp")
	f, err := os.OpenFile(temporary, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, err = f.WriteString(e.Text())
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(temporary, path)
	}
	if err != nil {
		_ = os.Remove(temporary)
	}
	return err
}
