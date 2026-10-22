package store

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// #2292: a file set aside again and again keeps its newest 3 copies of each kind.
func TestTheNewestSetAsidesAreKept(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "events.jsonl")
	other := filepath.Join(dir, "devices.json.corrupt-1")
	os.WriteFile(file, []byte("{}"), 0o644)
	os.WriteFile(other, []byte("{}"), 0o644)
	// 9 and 10 sort below 8 as text: the time is a number.
	for _, at := range []int{1, 2, 8, 9, 10} {
		os.WriteFile(fmt.Sprintf("%s.unreadable-%d", file, at), []byte("{}"), 0o644)
		os.WriteFile(fmt.Sprintf("%s.corrupt-%d", file, at), []byte("{}"), 0o644)
	}
	TrimSetAsides(file)
	entries, _ := os.ReadDir(dir)
	var got []string
	for _, e := range entries {
		got = append(got, e.Name())
	}
	want := []string{"devices.json.corrupt-1", "events.jsonl",
		"events.jsonl.corrupt-10", "events.jsonl.corrupt-8", "events.jsonl.corrupt-9",
		"events.jsonl.unreadable-10", "events.jsonl.unreadable-8", "events.jsonl.unreadable-9"}
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Fatalf("%v\nwant %v", got, want)
	}
}
