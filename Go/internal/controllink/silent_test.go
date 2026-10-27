package controllink

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"
)

// #1770: a tunnel's dead remote forward takes the connection and never answers. Join and
// Enroll give up, saying so, and the uplink dials again.
func TestAControlPlaneThatNeverAnswersIsGivenUp(t *testing.T) {
	was := dialWait
	dialWait = 300 * time.Millisecond
	t.Cleanup(func() { dialWait = was })
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	held := make(chan net.Conn, 16)
	t.Cleanup(func() {
		for len(held) > 0 {
			(<-held).Close()
		}
	})
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			held <- c // read nothing, say nothing
		}
	}()
	base := "https://" + ln.Addr().String()
	began := time.Now()
	_, _, err = Join(context.Background(), base, "pin", Credentials{Identity: "h:x"})
	if err == nil || !strings.Contains(err.Error(), "did not answer within") {
		t.Fatalf("Join: %v", err)
	}
	code := &Code{Host: true, URL: base, Pin: "pin", Secret: make([]byte, 32)}
	_, err = Enroll(context.Background(), t.TempDir(), code, NewPrivateKey(), MachineHello{})
	if err == nil || !strings.Contains(err.Error(), "did not answer within") {
		t.Fatalf("Enroll: %v", err)
	}
	if took := time.Since(began); took > 5*time.Second {
		t.Fatalf("took %s", took)
	}
}
