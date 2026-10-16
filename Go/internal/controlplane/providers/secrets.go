package providers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// SecretsFileName is ProviderSecrets.fileName.
const SecretsFileName = "provider-secrets.json"

// Secrets is ProviderSecrets: each provider's secrets (research R3), in
// provider-secrets.json in the control plane's own home, readable by its user only. Never
// in the store, which may be a bucket; never on the wire; never in the log. Values go only
// to the provider's own server, as its environment or its headers.
type Secrets struct {
	file string
	mu   sync.Mutex
	held map[string]map[string]string
}

// NewSecrets keeps secrets in home.
func NewSecrets(home string) *Secrets { return &Secrets{file: filepath.Join(home, SecretsFileName)} }

// Values is a provider's secrets, by name.
func (s *Secrets) Values(provider string) map[string]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]string{}
	for k, v := range s.load()[provider] {
		out[k] = v
	}
	return out
}

// Set lays secrets over what the provider had; an empty value takes one away.
func (s *Secrets) Set(provider string, secrets map[string]string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	all := clone(s.load())
	mine := map[string]string{}
	for k, v := range all[provider] {
		mine[k] = v
	}
	for name, value := range secrets {
		if value == "" {
			delete(mine, name)
		} else {
			mine[name] = value
		}
	}
	if len(mine) == 0 {
		delete(all, provider)
	} else {
		all[provider] = mine
	}
	return s.write(all)
}

// Remove takes a provider's secrets away.
func (s *Secrets) Remove(provider string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	all := clone(s.load())
	if _, ok := all[provider]; !ok {
		return nil
	}
	delete(all, provider)
	return s.write(all)
}

func clone(all map[string]map[string]string) map[string]map[string]string {
	out := make(map[string]map[string]string, len(all))
	for k, v := range all {
		out[k] = v
	}
	return out
}

func (s *Secrets) load() map[string]map[string]string {
	if s.held != nil {
		return s.held
	}
	s.held = map[string]map[string]string{}
	if data, err := os.ReadFile(s.file); err == nil {
		var read map[string]map[string]string
		if json.Unmarshal(data, &read) == nil && read != nil {
			s.held = read
		}
	}
	return s.held
}

// write makes the file 0600 before anything is in it, then moves it over the old one.
func (s *Secrets) write(all map[string]map[string]string) error {
	data, err := records.Encode(all)
	if err != nil {
		return err
	}
	folder := filepath.Dir(s.file)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return err
	}
	scratch, err := os.CreateTemp(folder, "."+SecretsFileName+".*")
	if err != nil {
		return &ProviderFailure{"the provider secrets could not be written"}
	}
	name := scratch.Name()
	ok := false
	defer func() {
		if !ok {
			os.Remove(name)
		}
	}()
	if err := scratch.Chmod(0o600); err != nil {
		scratch.Close()
		return err
	}
	if _, err := scratch.Write(data); err != nil {
		scratch.Close()
		return err
	}
	if err := scratch.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, s.file); err != nil {
		return err
	}
	ok = true
	os.Chmod(s.file, 0o600)
	s.held = all
	return nil
}
