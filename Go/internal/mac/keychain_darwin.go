package mac

import (
	"errors"
	"fmt"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

// A generic-password item in the login Keychain, made, read and deleted by this process
// through Security.framework's SecItem calls. agentsd is built without cgo, so the calls go
// through purego. An item made this way trusts only the program that made it: its code
// signature (agentsd's identifier and team) reads it without a prompt, and any other
// program, /usr/bin/security too, gets a prompt for the person's password. That is the
// difference from connections.Keychain, whose items /usr/bin/security makes and so trusts.
// A read never shows a prompt here: the daemon has nobody to answer it.

// ErrKeychainDenied is a Keychain that would ask the person, or refused this program.
var ErrKeychainDenied = errors.New("the Keychain did not let this program read the item")

const (
	errSecSuccess               = 0
	errSecItemNotFound          = -25300
	errSecDuplicateItem         = -25299
	errSecInteractionNotAllowed = -25308
	errSecAuthFailed            = -25293
	kCFStringEncodingUTF8       = 0x08000100
)

var keychain struct {
	once sync.Once
	err  error

	cfStringCreateWithBytes func(alloc uintptr, bytes *byte, n int, encoding uint32, external bool) uintptr
	cfDataCreate            func(alloc uintptr, bytes *byte, n int) uintptr
	cfDataGetLength         func(data uintptr) int
	cfDataGetBytePtr        func(data uintptr) uintptr
	cfDictionaryCreate      func(alloc uintptr, keys, values *uintptr, n int, keyCallBacks, valueCallBacks uintptr) uintptr
	cfRelease               func(cf uintptr)
	secItemAdd              func(query uintptr, result *uintptr) int32
	secItemCopyMatching     func(query uintptr, result *uintptr) int32
	secItemDelete           func(query uintptr) int32

	keyCallBacks, valueCallBacks uintptr
	booleanTrue                  uintptr
	class, genericPassword       uintptr
	service, account, label      uintptr
	valueData, returnData        uintptr
	matchLimit, matchLimitOne    uintptr
	authenticationUI, uiFail     uintptr
}

func loadKeychain() error {
	k := &keychain
	k.once.Do(func() {
		cf, err := purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			k.err = err
			return
		}
		sec, err := purego.Dlopen("/System/Library/Frameworks/Security.framework/Security", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			k.err = err
			return
		}
		purego.RegisterLibFunc(&k.cfStringCreateWithBytes, cf, "CFStringCreateWithBytes")
		purego.RegisterLibFunc(&k.cfDataCreate, cf, "CFDataCreate")
		purego.RegisterLibFunc(&k.cfDataGetLength, cf, "CFDataGetLength")
		purego.RegisterLibFunc(&k.cfDataGetBytePtr, cf, "CFDataGetBytePtr")
		purego.RegisterLibFunc(&k.cfDictionaryCreate, cf, "CFDictionaryCreate")
		purego.RegisterLibFunc(&k.cfRelease, cf, "CFRelease")
		purego.RegisterLibFunc(&k.secItemAdd, sec, "SecItemAdd")
		purego.RegisterLibFunc(&k.secItemCopyMatching, sec, "SecItemCopyMatching")
		purego.RegisterLibFunc(&k.secItemDelete, sec, "SecItemDelete")
		// The callbacks are structs: their addresses. The rest are CFTypeRef variables.
		for _, s := range []struct {
			to     *uintptr
			lib    uintptr
			name   string
			direct bool
		}{
			{&k.keyCallBacks, cf, "kCFTypeDictionaryKeyCallBacks", true},
			{&k.valueCallBacks, cf, "kCFTypeDictionaryValueCallBacks", true},
			{&k.booleanTrue, cf, "kCFBooleanTrue", false},
			{&k.class, sec, "kSecClass", false},
			{&k.genericPassword, sec, "kSecClassGenericPassword", false},
			{&k.service, sec, "kSecAttrService", false},
			{&k.account, sec, "kSecAttrAccount", false},
			{&k.label, sec, "kSecAttrLabel", false},
			{&k.valueData, sec, "kSecValueData", false},
			{&k.returnData, sec, "kSecReturnData", false},
			{&k.matchLimit, sec, "kSecMatchLimit", false},
			{&k.matchLimitOne, sec, "kSecMatchLimitOne", false},
			{&k.authenticationUI, sec, "kSecUseAuthenticationUI", false},
			{&k.uiFail, sec, "kSecUseAuthenticationUIFail", false},
		} {
			at, err := purego.Dlsym(s.lib, s.name)
			if err != nil {
				k.err = err
				return
			}
			if s.direct {
				*s.to = at
			} else {
				*s.to = *pointerAt[uintptr](at)
			}
		}
	})
	return k.err
}

// pointerAt is the C address p as a Go pointer (for memory C owns).
func pointerAt[T any](p uintptr) *T { return *(**T)(unsafe.Pointer(&p)) }

// cfString is s as a CFString; s is never empty here (a service, an account, a label).
func cfString(s string) uintptr {
	b := []byte(s + "\x00")
	return keychain.cfStringCreateWithBytes(0, &b[0], len(s), kCFStringEncodingUTF8, false)
}

// query is a CFDictionary of pairs; release releases it and every value it made.
type query struct {
	keys, values []uintptr
	made         []uintptr
}

func (q *query) set(key, value uintptr) {
	q.keys = append(q.keys, key)
	q.values = append(q.values, value)
}
func (q *query) setMade(key, value uintptr) { q.set(key, value); q.made = append(q.made, value) }

func (q *query) dictionary() uintptr {
	d := keychain.cfDictionaryCreate(0, &q.keys[0], &q.values[0], len(q.keys), keychain.keyCallBacks, keychain.valueCallBacks)
	q.made = append(q.made, d)
	return d
}

func (q *query) release() {
	for _, cf := range q.made {
		if cf != 0 {
			keychain.cfRelease(cf)
		}
	}
}

func item(service, account string) *query {
	q := &query{}
	q.set(keychain.class, keychain.genericPassword)
	q.setMade(keychain.service, cfString(service))
	q.setMade(keychain.account, cfString(account))
	return q
}

// KeychainGet is the item's data, or false when there is no such item.
func KeychainGet(service, account string) ([]byte, bool, error) {
	if err := loadKeychain(); err != nil {
		return nil, false, err
	}
	q := item(service, account)
	defer q.release()
	q.set(keychain.returnData, keychain.booleanTrue)
	q.set(keychain.matchLimit, keychain.matchLimitOne)
	q.set(keychain.authenticationUI, keychain.uiFail)
	var data uintptr
	switch status := keychain.secItemCopyMatching(q.dictionary(), &data); status {
	case errSecSuccess:
	case errSecItemNotFound:
		return nil, false, nil
	case errSecInteractionNotAllowed, errSecAuthFailed:
		return nil, false, ErrKeychainDenied
	default:
		return nil, false, fmt.Errorf("the Keychain: OSStatus %d", status)
	}
	defer keychain.cfRelease(data)
	n := keychain.cfDataGetLength(data)
	out := make([]byte, n)
	if n > 0 {
		copy(out, unsafe.Slice(pointerAt[byte](keychain.cfDataGetBytePtr(data)), n))
	}
	return out, true, nil
}

// KeychainAdd makes the item, trusted by this program alone. An item already there is an
// error: it may be another program's, so it is never written over.
func KeychainAdd(service, account, label string, data []byte) error {
	if err := loadKeychain(); err != nil {
		return err
	}
	if len(data) == 0 {
		return errors.New("the Keychain: nothing to keep")
	}
	q := item(service, account)
	defer q.release()
	q.setMade(keychain.label, cfString(label))
	q.setMade(keychain.valueData, keychain.cfDataCreate(0, &data[0], len(data)))
	switch status := keychain.secItemAdd(q.dictionary(), nil); status {
	case errSecSuccess:
		return nil
	case errSecInteractionNotAllowed, errSecAuthFailed:
		return ErrKeychainDenied
	case errSecDuplicateItem:
		return errors.New("the Keychain has that item already")
	default:
		return fmt.Errorf("the Keychain: OSStatus %d", status)
	}
}

// KeychainDelete deletes the item; no such item is not an error.
func KeychainDelete(service, account string) error {
	if err := loadKeychain(); err != nil {
		return err
	}
	q := item(service, account)
	defer q.release()
	switch status := keychain.secItemDelete(q.dictionary()); status {
	case errSecSuccess, errSecItemNotFound:
		return nil
	default:
		return fmt.Errorf("the Keychain: OSStatus %d", status)
	}
}
