package mac

import (
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

// A read that waits on a prompt (an item another program made, #4045) is denied after the
// time limit, and a second read of the item is denied at once while the first still waits.
// The fake SecItemCopyMatching never reaches the Keychain.
func TestAKeychainReadThatWaitsOnAPromptIsDenied(t *testing.T) {
	if err := loadKeychain(); err != nil {
		t.Skip(err)
	}
	prompt := make(chan struct{})
	var calls atomic.Int32
	real, limit := keychain.secItemCopyMatching, keychainReadLimit
	keychain.secItemCopyMatching = func(query uintptr, result *uintptr) int32 {
		calls.Add(1)
		<-prompt
		return errSecItemNotFound
	}
	keychainReadLimit = 50 * time.Millisecond
	t.Cleanup(func() { keychain.secItemCopyMatching, keychainReadLimit = real, limit })

	const service = "agents-test-4045-scratch"
	start := time.Now()
	if _, ok, err := KeychainGet(service, "machine"); ok || !errors.Is(err, ErrKeychainDenied) {
		t.Fatalf("not denied: %v %v", ok, err)
	}
	if waited := time.Since(start); waited > 2*time.Second {
		t.Fatalf("waited %v", waited)
	}
	if _, _, err := KeychainGet(service, "machine"); !errors.Is(err, ErrKeychainDenied) || calls.Load() != 1 {
		t.Fatalf("a second read: %v, %d calls", err, calls.Load())
	}

	// Once the prompt goes, the item reads again.
	close(prompt)
	deadline := time.Now().Add(2 * time.Second)
	for {
		_, ok, err := KeychainGet(service, "machine")
		if err == nil && !ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("still denied: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
