package service

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/coder/websocket"
)

// The web remote's door (071, contracts/loopback-listener.md), as LoopbackListener.swift
// keeps it: plain HTTP on 127.0.0.1 and ::1 only, the built Web/dist its MANIFEST lists
// and nothing else, and its WebSocket at /v1/connect, from that page only. Its origin is
// http://localhost:<port>, and the key exchange on it is bound to that.

type WebConfig struct {
	Folder string
	Port   int
}

// WebStatus is DaemonAPI.WebRemoteStatus.
type WebStatus struct {
	Port   int    `json:"port"`
	Served bool   `json:"served"`
	Reason string `json:"reason,omitempty"`
	Detail string `json:"detail,omitempty"`
}

type webFile struct {
	data []byte
	kind string
}

var webTypes = map[string]string{
	"html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
	"svg": "image/svg+xml", "png": "image/png", "woff2": "font/woff2", "webmanifest": "application/manifest+json",
}

// loadWeb reads every out line of folder/MANIFEST, each file checked against its hash.
func loadWeb(folder string) (map[string]webFile, error) {
	text, err := os.ReadFile(filepath.Join(folder, "MANIFEST"))
	if err != nil {
		return nil, fmt.Errorf("%s is missing", filepath.Join(folder, "MANIFEST"))
	}
	files := map[string]webFile{}
	for _, line := range strings.Split(string(text), "\n") {
		parts := strings.SplitN(line, " ", 3)
		if len(parts) != 3 || parts[0] != "out" {
			continue
		}
		hash, p := parts[1], parts[2]
		if !strings.HasPrefix(p, "Web/dist/") {
			return nil, fmt.Errorf("%s is not under Web/dist", p)
		}
		rel := strings.TrimPrefix(p, "Web/dist/")
		kind, ok := webTypes[strings.ToLower(strings.TrimPrefix(path.Ext(rel), "."))]
		if !ok {
			return nil, fmt.Errorf("%s has a type the web remote never serves", rel)
		}
		data, err := os.ReadFile(filepath.Join(folder, filepath.FromSlash(rel)))
		sum := sha256.Sum256(data)
		if err != nil || hex.EncodeToString(sum[:]) != hash {
			return nil, fmt.Errorf("%s does not match its manifest", rel)
		}
		files["/"+rel] = webFile{data, kind}
	}
	if _, ok := files["/index.html"]; !ok {
		return nil, errors.New("the manifest lists no index.html")
	}
	return files, nil
}

type webGate struct {
	port  int
	files map[string]webFile
	s     *Service
}

func (g *webGate) origin() string { return fmt.Sprintf("http://localhost:%d", g.port) }

func (g *webGate) headers(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Content-Security-Policy", fmt.Sprintf("default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; "+
		"font-src 'self'; connect-src ws://localhost:%d; base-uri 'none'; form-action 'none'; "+
		"frame-ancestors 'none'; frame-src http://127.0.0.1:%d; object-src 'none'; worker-src 'none'; manifest-src 'self'; "+
		"require-trusted-types-for 'script'; trusted-types 'none'", g.port, g.port))
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Cross-Origin-Resource-Policy", "same-origin")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Cache-Control", "no-cache")
}

// ServeHTTP is LoopbackGate.judge, in the contract's order.
func (g *webGate) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	host := strings.ToLower(r.Host)
	canonical := fmt.Sprintf("localhost:%d", g.port)
	g.headers(w)
	// 1. DNS rebinding: a name that only resolves here is still refused.
	if host != canonical && host != fmt.Sprintf("127.0.0.1:%d", g.port) && host != fmt.Sprintf("[::1]:%d", g.port) {
		w.WriteHeader(http.StatusMisdirectedRequest)
		return
	}
	// 2. Nothing here changes anything.
	if r.Method != http.MethodGet {
		g.s.log(fmt.Sprintf("web %s %s 405", r.Method, r.URL.Path))
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	p := r.URL.Path
	upgrading := strings.EqualFold(r.Header.Get("Upgrade"), "websocket")
	// The sandbox proxy (#187): at its own origin only. Served with the page's headers here,
	// not the view's own policy (see the report).
	if p == "/sandbox.html" || p == "/sandbox.js" {
		f, ok := g.files[p]
		if host != fmt.Sprintf("127.0.0.1:%d", g.port) || upgrading || !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Security-Policy", "frame-ancestors "+g.origin())
		w.Header().Del("X-Frame-Options")
		w.Header().Set("Content-Type", f.kind)
		w.Write(f.data)
		return
	}
	// 3. One origin, so one key: the addresses go to the name.
	if host != canonical {
		if upgrading {
			w.WriteHeader(http.StatusMisdirectedRequest)
			return
		}
		http.Redirect(w, r, "http://"+canonical+p, http.StatusPermanentRedirect)
		return
	}
	// 4–5. The socket, from this page only.
	if p == "/v1/connect" || upgrading {
		if p != "/v1/connect" || !upgrading {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if r.Header.Get("Origin") != g.origin() {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: []string{canonical}})
		if err != nil {
			return
		}
		go g.s.accept(newConn(ws, r.RemoteAddr), g.origin())
		return
	}
	// 6–7. The files the manifest lists, and nothing else.
	if p == "/" {
		p = "/index.html"
	}
	f, ok := g.files[p]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", f.kind)
	w.Write(f.data)
}

// startWeb binds 127.0.0.1 and ::1 on one port. A build that doesn't match its manifest,
// or a port that's taken, leaves it off and says so; the TLS listener carries on.
func (s *Service) startWeb(cfg WebConfig) {
	files, err := loadWeb(cfg.Folder)
	if err != nil {
		s.log("web: not serving, " + err.Error())
		s.web = &WebStatus{Port: cfg.Port, Reason: "build", Detail: err.Error()}
		return
	}
	v4, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", cfg.Port))
	if err != nil {
		reason := "failed"
		if errors.Is(err, syscall.EADDRINUSE) {
			reason = "portInUse"
		}
		s.log(fmt.Sprintf("web: port %d not bound (%v); not serving the web remote", cfg.Port, err))
		s.web = &WebStatus{Port: cfg.Port, Reason: reason, Detail: err.Error()}
		return
	}
	port := v4.Addr().(*net.TCPAddr).Port
	gate := &webGate{port: port, files: files, s: s}
	srv := &http.Server{Handler: gate}
	s.servers = append(s.servers, srv)
	go srv.Serve(v4)
	if v6, err := net.Listen("tcp", fmt.Sprintf("[::1]:%d", port)); err == nil {
		go srv.Serve(v6)
	} else if !errors.Is(err, syscall.EADDRNOTAVAIL) && !errors.Is(err, syscall.EAFNOSUPPORT) {
		// Something else holds ::1 here, where a browser may well go for localhost.
		srv.Close()
		s.log(fmt.Sprintf("web: ::1 port %d is held (%v); not serving the web remote", port, err))
		s.web = &WebStatus{Port: port, Reason: "portInUse", Detail: err.Error()}
		return
	}
	s.web = &WebStatus{Port: port, Served: true}
	s.log(fmt.Sprintf("web: serving the web remote at http://localhost:%d", port))
}
