package controllink

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"strconv"
	"testing"
	"time"
)

type lineConn struct {
	in  chan string
	out chan string
}

func (l *lineConn) Write(line string) error { l.out <- line; return nil }
func (l *lineConn) In() <-chan string       { return l.in }
func (l *lineConn) Close()                  {}
func (l *lineConn) Device() string          { return "" }

// A tunnel's lines are the connection's bytes, both ways, as base64 JSON strings.
func TestPipeCarriesBytesBothWays(t *testing.T) {
	a, b := net.Pipe()
	tunnel := &lineConn{in: make(chan string, 4), out: make(chan string, 4)}
	go Pipe(a, tunnel)

	tunnel.in <- strconv.Quote(base64.StdEncoding.EncodeToString([]byte("GET / HTTP/1.1\r\n")))
	got := make([]byte, 16)
	if _, err := io.ReadFull(b, got); err != nil || string(got) != "GET / HTTP/1.1\r\n" {
		t.Fatalf("%q %v", got, err)
	}
	b.Write([]byte("HTTP/1.1 200 OK"))
	select {
	case line := <-tunnel.out:
		var s string
		json.Unmarshal([]byte(line), &s)
		if raw, _ := base64.StdEncoding.DecodeString(s); string(raw) != "HTTP/1.1 200 OK" {
			t.Fatalf("%q", raw)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("nothing came back through the tunnel")
	}
	close(tunnel.in)
	if _, err := b.Read(got); err == nil {
		t.Fatal("the connection stayed open after the tunnel closed")
	}
}
