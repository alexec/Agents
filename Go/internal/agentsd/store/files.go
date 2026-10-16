package store

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
)

// WriteAtomically writes data whole, as StoreCoding.writeAtomically does: to a temporary
// file beside it, synced, then renamed into place, so a crash leaves the old file or the
// new one and never a torn one.
func WriteAtomically(file string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(file)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b := make([]byte, 16)
	rand.Read(b)
	tmp := filepath.Join(dir, "."+filepath.Base(file)+"."+hex.EncodeToString(b)+".tmp")
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, file)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}
