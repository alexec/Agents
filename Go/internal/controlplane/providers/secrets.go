package providers

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"gocloud.dev/secrets"

	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// SecretsFileName is ProviderSecrets.fileName: where a control plane with no keeper for
// secrets keeps them.
const SecretsFileName = "provider-secrets.json"

// SecretsPrefix is where each provider's secrets are in the store, sealed (#2138):
// v1/providersecrets/<provider>.json. Not under ProvidersPrefix, which lists records.
const SecretsPrefix = "v1/providersecrets/"

// Secrets is ProviderSecrets: each provider's secrets (research R3). With a keeper, each
// provider's are sealed in the store by the keeper that seals people's secrets (#1760), so
// they go with a store copy, a handover and a backup, and no value is in the store in
// clear (#2138). With none, they are in provider-secrets.json in the control plane's own
// home, readable by its user only. Never on the wire; never in the log. Values go only to
// the provider's own server, as its environment or its headers.
type Secrets struct {
	file string
	// The store and the keeper, when they are sealed there.
	store     store.Store
	keeper    *secrets.Keeper
	keeperURL string
	mu        sync.Mutex
	held      map[string]map[string]string
}

// NewSecrets keeps secrets in home.
func NewSecrets(home string) *Secrets { return &Secrets{file: filepath.Join(home, SecretsFileName)} }

// NewSealedSecrets keeps secrets in st, each provider's sealed by k (#2138).
func NewSealedSecrets(st store.Store, k *secrets.Keeper, keeperURL string) *Secrets {
	return &Secrets{store: st, keeper: k, keeperURL: keeperURL}
}

func secretsKey(provider string) string { return SecretsPrefix + provider + ".json" }

// sealedTimeout bounds a keeper's or a store's call: Values has no context of its own.
const sealedTimeout = 30 * time.Second

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
	if s.store != nil {
		return s.seal(provider, mine, all)
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
	if s.store != nil {
		return s.seal(provider, nil, all)
	}
	return s.write(all)
}

// seal writes one provider's secrets to the store, sealed and bound to their key, or
// deletes them when there are none; all is what is held once it has.
func (s *Secrets) seal(provider string, values map[string]string, all map[string]map[string]string) error {
	ctx, cancel := context.WithTimeout(context.Background(), sealedTimeout)
	defer cancel()
	key := secretsKey(provider)
	if len(values) == 0 {
		if err := s.store.Delete(ctx, key); err != nil {
			return &ProviderFailure{"the provider secrets could not be written"}
		}
		s.held = all
		return nil
	}
	plain, err := json.Marshal(values)
	if err != nil {
		return err
	}
	sealed, err := kms.SealFor(ctx, s.keeper, s.keeperURL, plain, []byte(key))
	if err != nil {
		return &ProviderFailure{"the provider secrets could not be sealed"}
	}
	data, err := records.Encode(sealed)
	if err != nil {
		return err
	}
	// Providers run at one copy only, so this one's write is the only one.
	when := store.Absent
	if held, err := s.store.Get(ctx, key); err != nil {
		return &ProviderFailure{"the provider secrets could not be written"}
	} else if held != nil {
		when = store.Matching(held.ETag)
	}
	if _, err := s.store.Put(ctx, key, data, when); err != nil {
		return &ProviderFailure{"the provider secrets could not be written"}
	}
	s.held = all
	return nil
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
	if s.store != nil {
		s.held = s.unseal()
		return s.held
	}
	if data, err := os.ReadFile(s.file); err == nil {
		var read map[string]map[string]string
		if json.Unmarshal(data, &read) == nil && read != nil {
			s.held = read
		}
	}
	return s.held
}

// unseal reads every provider's secrets from the store. One that does not open is left
// out: its provider asks for them again.
func (s *Secrets) unseal() map[string]map[string]string {
	ctx, cancel := context.WithTimeout(context.Background(), sealedTimeout)
	defer cancel()
	out := map[string]map[string]string{}
	listed, err := s.store.List(ctx, SecretsPrefix)
	if err != nil {
		return out
	}
	for _, k := range listed {
		object, err := s.store.Get(ctx, k.Key)
		if err != nil || object == nil {
			continue
		}
		var sealed kms.Sealed
		if json.Unmarshal(object.Data, &sealed) != nil {
			continue
		}
		plain, err := kms.OpenFor(ctx, s.keeper, &sealed, []byte(k.Key))
		if err != nil {
			continue
		}
		var values map[string]string
		if json.Unmarshal(plain, &values) == nil && len(values) > 0 {
			out[strings.TrimSuffix(strings.TrimPrefix(k.Key, SecretsPrefix), ".json")] = values
		}
	}
	return out
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
