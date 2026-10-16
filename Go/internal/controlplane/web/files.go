// Package web is the web remote's door (071, research R2–R3,
// contracts/loopback-listener.md), as LoopbackListener.swift has it. It is plain HTTP on
// 127.0.0.1 and ::1 only. It serves the built web app and its WebSocket at /v1/connect.
// Its origin is http://localhost:<port>. The key exchange on it is bound to that origin.
package web

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// DefaultPort is Loopback.defaultPort: the port where Agents Host's single copy serves it.
const DefaultPort = 8792

// OriginFor is Loopback.origin(port:).
func OriginFor(port int) string { return fmt.Sprintf("http://localhost:%d", port) }

// File is WebFiles.File: the bytes of one file and its type.
type File struct {
	Data        []byte
	ContentType string
}

// Files is WebFiles: the built web app, held in memory by its path ("/index.html").
type Files map[string]File

// FilesError is WebFiles.Failure. Its words are the Swift's words.
type FilesError struct{ Words string }

func (e *FilesError) Error() string { return e.Words }

// types is WebFiles.types: the only types the web remote serves.
var types = map[string]string{
	"html":        "text/html; charset=utf-8",
	"js":          "text/javascript; charset=utf-8",
	"css":         "text/css; charset=utf-8",
	"svg":         "image/svg+xml",
	"png":         "image/png",
	"woff2":       "font/woff2",
	"webmanifest": "application/manifest+json",
}

// LoadFiles is WebFiles.load(from:). It reads each "out <sha256> Web/dist/<path>" line of
// folder/MANIFEST. It keeps only the files the manifest lists, and only when their bytes
// have the hash the manifest records. Other lines ("agents-web 1", "src ...") are skipped.
func LoadFiles(folder string) (Files, error) {
	manifest := filepath.Join(folder, "MANIFEST")
	text, err := os.ReadFile(manifest)
	if err != nil {
		return nil, &FilesError{manifest + " is missing"}
	}
	files := Files{}
	for _, line := range strings.Split(string(text), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, " ", 3)
		if len(parts) != 3 || parts[0] != "out" {
			continue
		}
		hash, p := parts[1], parts[2]
		if !strings.HasPrefix(p, "Web/dist/") {
			return nil, &FilesError{p + " is not under Web/dist"}
		}
		relative := strings.TrimPrefix(p, "Web/dist/")
		kind, ok := types[strings.ToLower(strings.TrimPrefix(path.Ext(relative), "."))]
		if !ok {
			return nil, &FilesError{relative + " has a type the web remote never serves"}
		}
		data, err := os.ReadFile(filepath.Join(folder, filepath.FromSlash(relative)))
		sum := sha256.Sum256(data)
		if err != nil || hex.EncodeToString(sum[:]) != hash {
			return nil, &FilesError{relative + " does not match its manifest"}
		}
		files["/"+relative] = File{Data: data, ContentType: kind}
	}
	if _, ok := files["/index.html"]; !ok {
		return nil, &FilesError{"the manifest lists no index.html"}
	}
	return files, nil
}
