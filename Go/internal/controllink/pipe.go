package controllink

import (
	"encoding/base64"
	"encoding/json"
	"net"
	"strconv"
	"sync"
)

// Pipe carries one TCP connection through one tunnel channel until either end closes:
// bytes as base64 JSON strings, 32 KiB at most each (TunnelPipe).
func Pipe(c net.Conn, t Conn) {
	var once sync.Once
	done := func() { once.Do(func() { t.Close(); c.Close() }) }
	go func() {
		defer done()
		for line := range t.In() {
			var s string
			if json.Unmarshal([]byte(line), &s) != nil {
				continue
			}
			b, err := base64.StdEncoding.DecodeString(s)
			if err != nil {
				continue
			}
			if _, err := c.Write(b); err != nil {
				return
			}
		}
	}()
	buf := make([]byte, 32<<10)
	for {
		n, err := c.Read(buf)
		if n > 0 {
			if t.Write(strconv.Quote(base64.StdEncoding.EncodeToString(buf[:n]))) != nil {
				break
			}
		}
		if err != nil {
			break
		}
	}
	done()
}
