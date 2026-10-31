package audit

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

func waitUntil(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("no %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// A full queue lets the oldest go, and the next line sent says how many.
func TestAFullQueueDropsTheOldestAndSaysSo(t *testing.T) {
	o := newOutbox(3)
	for i := range 5 {
		o.Add("k"+strconv.Itoa(i), []byte(`{"n":`+strconv.Itoa(i)+`}`))
	}
	if q, d := o.Counts(); q != 3 || d != 2 {
		t.Fatalf("queued %d, dropped %d", q, d)
	}
	lines, last, said := o.peek(10)
	h := func(n string) string { return Hash([]byte(`{"n":` + n + `}`)) }
	if len(lines) != 3 || string(lines[0]) != `{"dropped":2,"key":"k2","hash":"`+h("2")+`","entry":{"n":2}}` ||
		string(lines[1]) != `{"key":"k3","hash":"`+h("3")+`","entry":{"n":3}}` {
		t.Fatalf("%s", lines)
	}
	// One more goes while those are sent: said on the next line, not lost.
	o.Add("k5", []byte(`{"n":5}`))
	o.done(last, said)
	lines, _, _ = o.peek(10)
	if len(lines) != 1 || string(lines[0]) != `{"dropped":1,"key":"k5","hash":"`+h("5")+`","entry":{"n":5}}` {
		t.Fatalf("%s", lines)
	}
}

// US4: an HTTP sink gets each entry within seconds, as JSON lines with the bearer token,
// and the entry's stored bytes unchanged; one that fails is sent again.
func TestAnHTTPSinkGetsEachEntry(t *testing.T) {
	var mu sync.Mutex
	var got []string
	var auth string
	failures := 1
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if failures > 0 {
			failures--
			http.Error(w, "busy", http.StatusServiceUnavailable)
			return
		}
		b, _ := io.ReadAll(r.Body)
		auth = r.Header.Get("Authorization")
		got = append(got, strings.Split(strings.TrimSpace(string(b)), "\n")...)
	}))
	defer srv.Close()

	sinks := &Sinks{From: SinkFrom{Host: "control", ProcID: "aaaa1111"}}
	defer sinks.Stop()
	token := "s3cret"
	sinks.Set([]wire.AuditSink{{Kind: wire.AuditSinkKindHttp, Address: srv.URL, Token: &token}})
	s := store.NewMemory()
	l := &Log{Store: s, Chain: NewChain("aaaa1111"), Out: sinks.Add}
	for range 3 {
		if err := l.Write(context.Background(), wire.AuditActor{User: "alex"}, "agents/stop", "Stopped an agent", "box", nil); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		mu.Lock()
		n := len(got)
		mu.Unlock()
		if n == 3 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("got %d lines: %+v", n, sinks.State())
		}
		time.Sleep(10 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	if auth != "Bearer s3cret" {
		t.Fatalf("auth %q", auth)
	}
	var line struct {
		Key   string          `json:"key"`
		Hash  string          `json:"hash"`
		Entry json.RawMessage `json:"entry"`
	}
	json.Unmarshal([]byte(got[1]), &line)
	o, _ := s.Get(context.Background(), line.Key)
	if o == nil || line.Hash != Hash(o.Data) || !strings.Contains(string(line.Entry), `"seq":2`) {
		t.Fatalf("line %s, stored %v", got[1], o)
	}
	st := sinks.State()
	if len(st) != 1 || st[0].Sink.Token != nil || st[0].Sink.HasToken == nil || !*st[0].Sink.HasToken || st[0].SentAt == nil ||
		st[0].LastError != nil || st[0].Queued != 0 {
		t.Fatalf("%+v", st)
	}
}

// readFrames reads RFC 6587 octet-counted frames from a connection.
func readFrames(t *testing.T, conn net.Conn, n int) []string {
	t.Helper()
	r := bufio.NewReader(conn)
	var out []string
	for range n {
		size, err := r.ReadString(' ')
		if err != nil {
			t.Fatal(err)
		}
		count, _ := strconv.Atoi(strings.TrimSpace(size))
		b := make([]byte, count)
		if _, err := io.ReadFull(r, b); err != nil {
			t.Fatal(err)
		}
		out = append(out, string(b))
	}
	return out
}

func selfSigned(t *testing.T) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "siem"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, pool
}

// A syslog sink gets RFC 5424 lines, framed by their length, over TCP and over TLS.
func TestASyslogSinkGetsRFC5424Lines(t *testing.T) {
	cert, pool := selfSigned(t)
	for _, scheme := range []string{"tcp", "tls"} {
		t.Run(scheme, func(t *testing.T) {
			var ln net.Listener
			var err error
			if scheme == "tls" {
				ln, err = tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}})
			} else {
				ln, err = net.Listen("tcp", "127.0.0.1:0")
			}
			if err != nil {
				t.Fatal(err)
			}
			defer ln.Close()
			frames := make(chan []string, 1)
			go func() {
				conn, err := ln.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				frames <- readFrames(t, conn, 2)
			}()
			sinks := &Sinks{From: SinkFrom{Host: "my control", ProcID: "aaaa1111", TLS: &tls.Config{RootCAs: pool}}}
			defer sinks.Stop()
			sinks.Set([]wire.AuditSink{{Kind: wire.AuditSinkKindSyslog, Address: scheme + "://" + ln.Addr().String()}})
			sinks.Add("v1/events/k1.json", []byte(`{"kind":"audit","seq":1}`))
			sinks.Add("v1/events/k2.json", []byte(`{"kind":"audit","seq":2}`))
			select {
			case got := <-frames:
				head, msg, _ := strings.Cut(got[1], " - ")
				parts := strings.Fields(head)
				if len(parts) != 6 || parts[0] != "<110>1" || parts[2] != "my-control" || parts[3] != "agents-control" ||
					parts[4] != "aaaa1111" || parts[5] != "audit" || msg != `{"key":"v1/events/k2.json","hash":"`+Hash([]byte(`{"kind":"audit","seq":2}`))+`","entry":{"kind":"audit","seq":2}}` {
					t.Fatalf("%q", got[1])
				}
				if _, err := time.Parse(time.RFC3339Nano, parts[1]); err != nil {
					t.Fatalf("time %q: %v", parts[1], err)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("no frames")
			}
		})
	}
}

// What an admin may set: an address of the kind's own shape, a token only for HTTP.
func TestCheckSink(t *testing.T) {
	token := "t"
	for _, c := range []struct {
		sink wire.AuditSink
		ok   bool
	}{
		{wire.AuditSink{Kind: wire.AuditSinkKindSyslog, Address: "tcp://siem.example.com:514"}, true},
		{wire.AuditSink{Kind: wire.AuditSinkKindSyslog, Address: "tls://siem.example.com:6514"}, true},
		{wire.AuditSink{Kind: wire.AuditSinkKindSyslog, Address: "udp://siem.example.com:514"}, false},
		{wire.AuditSink{Kind: wire.AuditSinkKindSyslog, Address: "tcp://siem.example.com"}, false},
		{wire.AuditSink{Kind: wire.AuditSinkKindSyslog, Address: "tcp://siem.example.com:514", Token: &token}, false},
		{wire.AuditSink{Kind: wire.AuditSinkKindHttp, Address: "https://siem.example.com/in", Token: &token}, true},
		{wire.AuditSink{Kind: wire.AuditSinkKindHttp, Address: "http://siem.example.com/in"}, false},
		{wire.AuditSink{Kind: wire.AuditSinkKindHttp, Address: "http://127.0.0.1:9000/in"}, true},
		{wire.AuditSink{Kind: "kafka", Address: "https://x"}, false},
		{wire.AuditSink{Kind: wire.AuditSinkKindHttp, Address: "not an address"}, false},
	} {
		if err := CheckSink(c.sink); (err == nil) != c.ok {
			t.Errorf("%+v: %v", c.sink, err)
		}
	}
}

// A sink set again unchanged keeps its queue; one taken away stops.
func TestSettingTheSinksAgainKeepsTheirQueues(t *testing.T) {
	sinks := &Sinks{}
	defer sinks.Stop()
	down := wire.AuditSink{Kind: wire.AuditSinkKindSyslog, Address: "tcp://127.0.0.1:1"}
	sinks.Set([]wire.AuditSink{down})
	sinks.Add("k", []byte(`{}`))
	sinks.Set([]wire.AuditSink{down})
	if st := sinks.State(); len(st) != 1 || st[0].Queued != 1 {
		t.Fatalf("%+v", st)
	}
	waitUntil(t, "a failure said", func() bool { st := sinks.State(); return st[0].LastError != nil })
	sinks.Set(nil)
	if st := sinks.State(); len(st) != 0 {
		t.Fatalf("%+v", st)
	}
}
