package whatsappmcp

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The store (#4341): the messages the webhook was sent and the ones the number sent, which
// list_conversations and read_messages read. The Cloud API reads no chat's history, so this
// is the only history there is. It is bounded (the bounded-data rule): the newest maxStored,
// for storedFor, and at most maxStoreBytes of text. On disk it is one JSON file for each
// number, <dir>/<phone number id>.json, written to a temporary file and moved into place
// under a lock, so each copy of the server (one for each session that has it) adds to the
// same file and every copy reads all of it.

const (
	maxStored     = 2000
	storedFor     = 30 * 24 * time.Hour
	maxStoreBytes = 4 << 20
	// storedOverhead is what a message costs on disk beside its text.
	storedOverhead = 256
	storeVersion   = 1
)

// Stored is one message in the store.
type Stored struct {
	ID string `json:"id"`
	// Person is the conversation: the other person's number (wa_id).
	Person string `json:"person"`
	// Name is the person's profile name, when WhatsApp gave it.
	Name string `json:"name,omitempty"`
	// Out is true for a message the number sent.
	Out     bool      `json:"out,omitempty"`
	At      time.Time `json:"at"`
	Text    string    `json:"text"`
	ReplyTo string    `json:"replyTo,omitempty"`
}

type storeFile struct {
	Version  int      `json:"version"`
	Messages []Stored `json:"messages"`
}

// Store keeps the messages. With no Dir, it keeps them in memory only, for this run.
type Store struct {
	Dir    string
	Logger *slog.Logger

	mu  sync.Mutex
	mem map[string][]Stored
}

// DefaultStoreDir is WHATSAPP_STORE_DIR, or ~/.agents/whatsapp.
func DefaultStoreDir(getenv func(string) string) string {
	if dir := strings.TrimSpace(getenv("WHATSAPP_STORE_DIR")); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".agents", "whatsapp")
}

// Add puts messages in the number's store; one it holds already is not kept twice.
func (s *Store) Add(number string, msgs ...Stored) error {
	if len(msgs) == 0 {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.Dir == "" {
		if s.mem == nil {
			s.mem = map[string][]Stored{}
		}
		s.mem[number] = bound(merge(s.mem[number], msgs), time.Now())
		return nil
	}
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return fmt.Errorf("the WhatsApp store: %w", err)
	}
	p := s.path(number)
	lock, err := os.OpenFile(p+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("the WhatsApp store's lock: %w", err)
	}
	defer func() { _ = lock.Close() }()
	if err := flock(lock, syscall.LOCK_EX); err != nil {
		return fmt.Errorf("the WhatsApp store's lock: %w", err)
	}
	defer func() { _ = flock(lock, syscall.LOCK_UN) }()
	held, err := s.read(p)
	if err != nil {
		// A file that cannot be read is kept aside, once, and the store starts again.
		s.warn("the store cannot be read; it is kept aside and started again", err)
		_ = os.Rename(p, strings.TrimSuffix(p, ".json")+".unreadable.json")
		held = nil
	}
	data, err := json.Marshal(storeFile{Version: storeVersion, Messages: bound(merge(held, msgs), time.Now())})
	if err != nil {
		return err
	}
	return writeAtomically(p, data)
}

// Messages is the number's messages, oldest first, none older than storedFor.
func (s *Store) Messages(number string) ([]Stored, error) {
	var held []Stored
	if s.Dir == "" {
		s.mu.Lock()
		held = slices.Clone(s.mem[number])
		s.mu.Unlock()
	} else {
		var err error
		if held, err = s.read(s.path(number)); err != nil {
			return nil, fmt.Errorf("the WhatsApp store: %w", err)
		}
	}
	return bound(held, time.Now()), nil
}

func (s *Store) path(number string) string { return filepath.Join(s.Dir, number+".json") }

// read is the file's messages; none when it is not there.
func (s *Store) read(p string) ([]Stored, error) {
	data, err := os.ReadFile(p)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var f storeFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, err
	}
	if f.Version != storeVersion {
		return nil, fmt.Errorf("%s is version %d, not %d", p, f.Version, storeVersion)
	}
	return f.Messages, nil
}

func (s *Store) warn(msg string, err error) {
	if s.Logger != nil {
		s.Logger.Warn("whatsapp-mcp: "+msg, "err", err)
	}
}

// merge is held with the new messages, oldest first; a message held already is left out.
func merge(held, msgs []Stored) []Stored {
	ids := make(map[string]bool, len(held))
	for _, m := range held {
		ids[m.ID] = true
	}
	out := slices.Clone(held)
	for _, m := range msgs {
		if m.ID == "" || ids[m.ID] {
			continue
		}
		ids[m.ID] = true
		out = append(out, m)
	}
	slices.SortStableFunc(out, func(a, b Stored) int { return a.At.Compare(b.At) })
	return out
}

// bound is the newest of msgs (oldest first) that the store's limits keep.
func bound(msgs []Stored, now time.Time) []Stored {
	from := max(0, len(msgs)-maxStored)
	for from < len(msgs) && now.Sub(msgs[from].At) > storedFor {
		from++
	}
	size := 0
	for i := len(msgs) - 1; i >= from; i-- {
		size += len(msgs[i].Text) + storedOverhead
		if size > maxStoreBytes {
			from = i + 1
			break
		}
	}
	return msgs[from:]
}

func flock(f *os.File, how int) error {
	for {
		err := syscall.Flock(int(f.Fd()), how)
		if err != syscall.EINTR {
			return err
		}
	}
}

// writeAtomically writes data to a temporary file beside p, syncs it, moves it into place
// and syncs the folder, so a reader sees the old file or the new one, never part of one.
func writeAtomically(p string, data []byte) error {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	tmp := filepath.Join(filepath.Dir(p), "."+filepath.Base(p)+"."+hex.EncodeToString(b)+".tmp")
	w, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("the WhatsApp store: %w", err)
	}
	_, err = w.Write(data)
	if err == nil {
		err = w.Sync()
	}
	if cerr := w.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, p)
	}
	if err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("the WhatsApp store: %w", err)
	}
	if d, err := os.Open(filepath.Dir(p)); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}
