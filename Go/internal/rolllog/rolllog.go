// Package rolllog is the one log roller (#1555): a file kept open for appending that,
// past its limit, becomes <name>.previous.log, as DaemonLog and ControlLog do. agentsd's
// daemon.log and the control plane's control.log both go through it.
package rolllog

import (
	"os"
	"strings"
	"sync"
)

// Limit is the size a log rolls at: DaemonLog.limit and ControlLog.limit.
const Limit = 4 * 1024 * 1024

// File is a rolled log. Its path is looked at before each write, so a log rolled by
// another process (the supervisor and agentsd share daemon.log), moved or removed is
// opened again, and the other process's lines count towards the limit.
type File struct {
	mu    sync.Mutex
	path  string
	limit int64
	std   bool
	out   *os.File
	info  os.FileInfo
}

// Open opens path for appending, rolling it first when it is already past limit. With
// std, the process's standard output and error go to the file too, opened again at each
// roll, so what the runtime itself writes (a panic) lands beside the lines.
func Open(path string, limit int64, std bool) (*File, error) {
	f := &File{path: path, limit: limit, std: std}
	if err := f.reopen(); err != nil {
		return nil, err
	}
	if f.info.Size() > limit {
		f.roll()
	}
	return f, nil
}

// Previous is where path goes when it rolls: daemon.log is daemon.previous.log.
func Previous(path string) string { return strings.TrimSuffix(path, ".log") + ".previous.log" }

// Write appends p, rolling first when p would take the log past its limit. A log that
// is empty takes p whatever its size.
func (f *File) Write(p []byte) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	now, err := os.Stat(f.path)
	switch {
	case err != nil || !os.SameFile(now, f.info):
		f.reopen()
	case now.Size() > 0 && now.Size()+int64(len(p)) > f.limit:
		f.roll()
	}
	if f.out == nil {
		return 0, os.ErrClosed
	}
	return f.out.Write(p)
}

// File is the open file, to hand to a child process as its output.
func (f *File) File() *os.File {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.out
}

// Close closes the file.
func (f *File) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.out == nil {
		return nil
	}
	err := f.out.Close()
	f.out = nil
	return err
}

// roll makes the log the previous one, replacing the one before, and starts a new one.
func (f *File) roll() {
	os.Rename(f.path, Previous(f.path))
	f.reopen()
}

func (f *File) reopen() error {
	out, err := os.OpenFile(f.path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	info, err := out.Stat()
	if err != nil {
		out.Close()
		return err
	}
	if f.std {
		dupTo(int(out.Fd()), 1)
		dupTo(int(out.Fd()), 2)
	}
	if f.out != nil {
		f.out.Close()
	}
	f.out, f.info = out, info
	return nil
}
