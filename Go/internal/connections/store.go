// Package connections is the person's sign-ins to tools such as GitHub (#1335): one
// connection per provider, kept by the host. The host signs in (the device flow), keeps the
// tokens and refreshes them; a server that uses one (the github server) only reads it.
//
// Secrets are not configuration (#1035): a connection is kept in this Mac's Keychain, one
// generic-password item per provider under a service of the root's own, or on Linux in
// ~/.agents-secrets/connections.json (0600, in a 0700 folder). Never in ~/.agents, a URL, a
// log or an error: an error says what failed, in words, and holds no token.
package connections

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// GitHub is the one provider so far. Linear comes next (#1336).
const GitHub = "github"

// Providers is every provider a store is asked about when it lists.
var Providers = []string{GitHub}

// Connection is one provider's sign-in. Access and Refresh are secrets: they leave the
// store only to the host's refresh and to a server's Authorization header.
type Connection struct {
	Provider string `json:"provider"`
	// Login is the account's name on the provider, such as alexec.
	Login            string    `json:"login,omitempty"`
	Access           string    `json:"access,omitempty"`
	Refresh          string    `json:"refresh,omitempty"`
	AccessExpiresAt  time.Time `json:"accessExpiresAt,omitzero"`
	RefreshExpiresAt time.Time `json:"refreshExpiresAt,omitzero"`
	ConnectedAt      time.Time `json:"connectedAt"`
	// SignInAgain is set when the provider refused the refresh: the tokens are gone, the
	// row stays and says "Sign in again".
	SignInAgain bool `json:"signInAgain,omitempty"`
}

// Usable is a connection with an access token that has not ended at now.
func (c Connection) Usable(now time.Time) bool {
	return !c.SignInAgain && c.Access != "" && (c.AccessExpiresAt.IsZero() || now.Before(c.AccessExpiresAt))
}

// Store keeps connections, one per provider.
type Store interface {
	// Get is the provider's connection; ok is false when there is none.
	Get(provider string) (c Connection, ok bool, err error)
	Put(c Connection) error
	Delete(provider string) error
}

// List is every provider's connection that the store has.
func List(s Store) ([]Connection, error) {
	var out []Connection
	for _, p := range Providers {
		c, ok, err := s.Get(p)
		if err != nil {
			return out, err
		}
		if ok {
			out = append(out, c)
		}
	}
	return out, nil
}

// ErrUnreadable is a kept connection that does not read: nothing is written over it.
var ErrUnreadable = errors.New("the connection could not be read")

// MARK: Where the store is

// EnvName is the variable the host sets for every process it starts, so a server (the
// github server) reads the host's store and not the real one's on a scratch root. Its value
// is a Locator: where the store is, never a secret.
const EnvName = "AGENTS_CONNECTIONS"

// Locator says where a store is: "keychain:<service>" or "file:<path>".
type Locator string

// ForHost is the store of the host at root, for the person whose home is personalHome:
// the Keychain on a Mac, ~/.agents-secrets on Linux.
func ForHost(root, personalHome string) Locator {
	if runtime.GOOS == "darwin" {
		return Locator("keychain:" + KeychainService(root))
	}
	return Locator("file:" + filepath.Join(personalHome, ".agents-secrets", FileName))
}

// FromEnv is the host's store as EnvName says, or the ordinary host's when it is not set.
func FromEnv() Locator {
	if l := os.Getenv(EnvName); l != "" {
		return Locator(l)
	}
	home, _ := os.UserHomeDir()
	root := os.Getenv("AGENTS_ROOT")
	if root == "" {
		root = store.StandardRoot(home)
	}
	personal := os.Getenv("AGENTS_PERSONAL_HOME")
	if personal == "" {
		personal = home
	}
	return ForHost(root, personal)
}

// Open is the store l names.
func Open(l Locator) (Store, error) {
	switch kind, where, _ := strings.Cut(string(l), ":"); kind {
	case "keychain":
		return &Keychain{Service: where}, nil
	case "file":
		return &File{Path: where}, nil
	}
	return nil, fmt.Errorf("%s is not a place for connections", EnvName)
}

// KeychainService is the root's own service, as CredentialStore's: the first four bytes of
// the root path's SHA-256, so a scratch root never reads or writes the real one's items.
func KeychainService(root string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(root)))
	return "agents.connection." + hex.EncodeToString(sum[:4])
}

// MARK: Linux: a file

// FileName is the file in ~/.agents-secrets.
const FileName = "connections.json"

// File is the Linux store: one JSON file of every connection, mode 0600.
type File struct {
	Path string
	mu   sync.Mutex
}

func (f *File) read() (map[string]Connection, error) {
	b, err := os.ReadFile(f.Path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]Connection{}, nil
	}
	all := map[string]Connection{}
	if err != nil || json.Unmarshal(b, &all) != nil {
		return nil, ErrUnreadable
	}
	return all, nil
}

func (f *File) write(all map[string]Connection) error {
	b, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(f.Path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	_ = os.Chmod(dir, 0o700)
	return store.WriteAtomically(f.Path, b, 0o600)
}

func (f *File) Get(provider string) (Connection, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	all, err := f.read()
	if err != nil {
		return Connection{}, false, err
	}
	c, ok := all[provider]
	return c, ok, nil
}

func (f *File) Put(c Connection) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	all, err := f.read()
	if err != nil {
		return err
	}
	all[c.Provider] = c
	return f.write(all)
}

func (f *File) Delete(provider string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	all, err := f.read()
	if err != nil {
		return err
	}
	if _, ok := all[provider]; !ok {
		return nil
	}
	delete(all, provider)
	return f.write(all)
}

// MARK: macOS: the Keychain

// Keychain is the Mac's store: one generic-password item per provider (the account), under
// Service. The items are made, read and deleted by /usr/bin/security for this host alone, so
// macOS asks nobody (an item made by another program would make it ask, #1035). The secret
// goes to security on its stdin (`security -i`), never in its arguments, where ps shows it.
type Keychain struct {
	Service string
	// Security is the security tool; /usr/bin/security when empty.
	Security string
	mu       sync.Mutex
}

// keychainNotFound is security's exit for no such item.
const keychainNotFound = 44

func (k *Keychain) tool() string {
	if k.Security != "" {
		return k.Security
	}
	return "/usr/bin/security"
}

// run is security with args (and stdin), ten seconds at most: a call waiting on a prompt
// nobody answers must not hang (#207). Its output is never put in an error.
func (k *Keychain) run(stdin string, args ...string) ([]byte, int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, k.tool(), args...)
	cmd.Stdin = strings.NewReader(stdin)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return nil, exit.ExitCode(), err
	}
	return out.Bytes(), 0, err
}

func (k *Keychain) Get(provider string) (Connection, bool, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.get(provider)
}

func (k *Keychain) get(provider string) (Connection, bool, error) {
	out, code, err := k.run("", "find-generic-password", "-s", k.Service, "-a", provider, "-w")
	if code == keychainNotFound {
		return Connection{}, false, nil
	}
	if err != nil {
		return Connection{}, false, ErrUnreadable
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(out)))
	var c Connection
	if err != nil || json.Unmarshal(raw, &c) != nil {
		return Connection{}, false, ErrUnreadable
	}
	return c, true, nil
}

func (k *Keychain) Put(c Connection) error {
	if !plainWord(k.Service) || !plainWord(c.Provider) {
		return errors.New("a connection's service and provider are plain words")
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	// base64 has no space or quote, so the line needs no quoting in security's own shell.
	line := fmt.Sprintf("add-generic-password -U -s %s -a %s -l %s -w %s\n",
		k.Service, c.Provider, "Agents-"+c.Provider, base64.StdEncoding.EncodeToString(b))
	if _, _, err := k.run(line, "-i"); err != nil {
		return errors.New("the Keychain did not keep the connection")
	}
	// security -i goes on after a failed command: read it back to be sure.
	got, ok, err := k.get(c.Provider)
	if err != nil || !ok || got.Access != c.Access || got.Refresh != c.Refresh || got.SignInAgain != c.SignInAgain {
		return errors.New("the Keychain did not keep the connection")
	}
	return nil
}

func (k *Keychain) Delete(provider string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	_, code, err := k.run("", "delete-generic-password", "-s", k.Service, "-a", provider)
	if err != nil && code != keychainNotFound {
		return errors.New("the Keychain did not delete the connection")
	}
	return nil
}

// plainWord is letters, digits, dot, dash and underscore only.
func plainWord(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '-' || r == '_') {
			return false
		}
	}
	return true
}
