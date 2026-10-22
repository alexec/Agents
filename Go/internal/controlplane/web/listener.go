package web

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
)

// maxMessage is the largest message a WebSocket takes until it proves a key; Accept's
// owner raises it once one has (#2150).
const maxMessage = 64 * 1024

// The listener's timeouts and header limit (#2150). A WebSocket clears them once the gate
// lets it through, so they close only a slow request, never a socket in use.
const (
	readTimeout  = 30 * time.Second
	writeTimeout = 60 * time.Second
	idleTimeout  = 2 * time.Minute
	headerMost   = 64 << 10
)

// Config is what Start needs: ControlService.Configuration.Web, and the two closures
// startWeb gives LoopbackListener.start.
type Config struct {
	// Folder is the built web app: Web/dist, with its MANIFEST.
	Folder string
	// Port is the port to bind on both addresses. With 0, the system picks it.
	Port int
	// Accept is called for each WebSocket the gate lets through at /v1/connect, on that
	// connection's own goroutine. remote is the peer's address. origin is the listener's
	// own origin, "http://localhost:<port>". Accept owns ws, and must close it.
	Accept func(ws *websocket.Conn, remote string, origin string)
	// Log takes one line at a time. Nil drops them.
	Log func(string)
}

// Listener is LoopbackListener: the two binds, 127.0.0.1 and ::1, on one port.
type Listener struct {
	cfg       Config
	gate      *gate
	srv       *http.Server
	listeners []net.Listener
}

// Start is ControlService.startWeb with LoopbackListener.start. It loads the files from
// the manifest, then binds 127.0.0.1 and ::1 on one port. It logs as startWeb does. An
// error is a *FilesError when the build does not match its manifest, else the bind's
// error. Give the error to StatusOf for the status to report.
func Start(cfg Config) (*Listener, error) {
	logf := func(format string, args ...any) {
		if cfg.Log != nil {
			cfg.Log(fmt.Sprintf(format, args...))
		}
	}
	files, err := LoadFiles(cfg.Folder)
	if err != nil {
		logf("web: not serving, %v", err)
		return nil, err
	}
	l, err := bind(cfg, files)
	if err != nil {
		logf("web: port %d not bound (%v); not serving the web remote", cfg.Port, err)
		return nil, err
	}
	logf("web: serving the web remote at %s", l.Origin())
	return l, nil
}

// bind is LoopbackListener.start. With port 0 the system picks the port for 127.0.0.1,
// and ::1 takes the same one.
func bind(cfg Config, files Files) (*Listener, error) {
	v4, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(cfg.Port)))
	if err != nil {
		return nil, err
	}
	port := v4.Addr().(*net.TCPAddr).Port
	l := &Listener{cfg: cfg, gate: &gate{port: port, files: files}}
	// Its own cap, so strangers at the TLS listener never keep a browser out (#206).
	unproven := &unprovenGate{most: 64, held: map[net.Conn]uint64{}}
	l.srv = &http.Server{
		Handler:           l,
		ReadHeaderTimeout: 20 * time.Second,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		MaxHeaderBytes:    headerMost,
		ConnState:         unproven.state,
	}
	listeners := []net.Listener{v4}
	v6, err := net.Listen("tcp6", net.JoinHostPort("::1", strconv.Itoa(port)))
	switch {
	case err == nil:
		listeners = append(listeners, v6)
	case errors.Is(err, syscall.EADDRNOTAVAIL) || errors.Is(err, syscall.EAFNOSUPPORT):
		// No IPv6 loopback here, so nothing else can answer a browser there either.
		if cfg.Log != nil {
			cfg.Log(fmt.Sprintf("web: no ::1 on this Mac (%v); serving 127.0.0.1 only", err))
		}
	default:
		// Something else holds ::1 on this port, where a browser may well go for
		// localhost. Serving 127.0.0.1 alone would send the page's visitors to it, at this
		// page's own origin (071 security review, R1).
		v4.Close()
		return nil, err
	}
	l.listeners = listeners
	for _, ln := range listeners {
		go l.srv.Serve(ln)
	}
	return l, nil
}

// Port is LoopbackListener.port: the port both addresses are bound on.
func (l *Listener) Port() int { return l.gate.port }

// Origin is LoopbackGate.origin: "http://localhost:<port>".
func (l *Listener) Origin() string { return l.gate.origin() }

// Status is the status of a listener that serves.
func (l *Listener) Status() Status { return Status{Port: int64(l.Port()), Served: true} }

// Stop is LoopbackListener.stop: it closes both binds. WebSockets already given to
// Accept stay open; their owner closes them.
func (l *Listener) Stop() {
	l.srv.Close()
	// Closed here too, so the port is free when Stop returns, even before Serve ran.
	for _, ln := range l.listeners {
		ln.Close()
	}
}

// ServeHTTP is ControlWebSocketServer.configure with the gate: an upgrade the gate lets
// through becomes a WebSocket, and every other request gets the gate's reply and a close.
func (l *Listener) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if v := l.gate.judge(r.Method, r.Host, r.RequestURI, r.Header); v.upgrade && handshakeOK(r) {
		rc := http.NewResponseController(w)
		rc.SetReadDeadline(time.Time{})
		rc.SetWriteDeadline(time.Time{})
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			// The gate has checked Host and Origin already, more strictly than Accept would.
			InsecureSkipVerify: true,
			CompressionMode:    websocket.CompressionDisabled,
		})
		if err != nil {
			return
		}
		ws.SetReadLimit(maxMessage)
		if l.cfg.Accept == nil {
			ws.CloseNow()
			return
		}
		l.cfg.Accept(ws, r.RemoteAddr, l.Origin())
		return
	}
	reply := l.gate.reply(r.Method, r.Host, r.RequestURI, r.Header)
	if r.Method != http.MethodGet && l.cfg.Log != nil {
		l.cfg.Log(fmt.Sprintf("web %s %s %d", r.Method, pathOf(r.RequestURI, ""), reply.status))
	}
	h := w.Header()
	h.Set("Content-Type", reply.contentType)
	h.Set("Content-Length", strconv.Itoa(len(reply.body)))
	h.Set("Connection", "close")
	for _, kv := range reply.headers {
		h.Add(kv[0], kv[1])
	}
	w.WriteHeader(reply.status)
	w.Write(reply.body)
}

// handshakeOK is what NIO's WebSocket upgrader needs before it upgrades: HTTP/1.1, a
// Connection header with "upgrade", version 13 and one key. Without it the gate's reply
// is a 400, as LoopbackGate.reply answers an upgrade that failed.
func handshakeOK(r *http.Request) bool {
	if !r.ProtoAtLeast(1, 1) || r.Header.Get("Sec-WebSocket-Version") != "13" ||
		len(r.Header.Values("Sec-WebSocket-Key")) != 1 {
		return false
	}
	for _, value := range r.Header.Values("Connection") {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), "upgrade") {
				return true
			}
		}
	}
	return false
}

// unprovenGate is ControlDial's UnprovenGate (#206), for the part before the upgrade: it
// holds at most `most` connections that have not become a WebSocket. Past that, it
// closes the oldest to make room.
type unprovenGate struct {
	mu   sync.Mutex
	most int
	held map[net.Conn]uint64
	next uint64
}

func (u *unprovenGate) state(c net.Conn, s http.ConnState) {
	switch s {
	case http.StateNew:
		var evicted net.Conn
		u.mu.Lock()
		if len(u.held) >= u.most {
			var oldest uint64
			for conn, ticket := range u.held {
				if evicted == nil || ticket < oldest {
					evicted, oldest = conn, ticket
				}
			}
			delete(u.held, evicted)
		}
		u.next++
		u.held[c] = u.next
		u.mu.Unlock()
		if evicted != nil {
			evicted.Close()
		}
	case http.StateHijacked, http.StateClosed:
		u.mu.Lock()
		delete(u.held, c)
		u.mu.Unlock()
	}
}
