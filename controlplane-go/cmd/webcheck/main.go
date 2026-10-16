// webcheck does what the web page does at the loopback listener (071), without a
// browser: the socket at ws://localhost:<port>/v1/connect with the page's Origin, a
// browser code's p: exchange and clients/announce (kind browser), then the c: exchange
// bound to http://localhost:<port>, control/status, and a ping to the home host.
//
//	webcheck <web port> '<browser code>'      (run.sh code <slug> --client --browser)
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/controlplane-go/internal/auth"
	"github.com/alexec/agents/controlplane-go/internal/records"
)

func die(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "webcheck: "+f+"\n", a...)
	os.Exit(1)
}

type sock struct{ ws *websocket.Conn }

func (s sock) send(line string) {
	if err := s.ws.Write(context.Background(), websocket.MessageText, []byte(line)); err != nil {
		die("write: %v", err)
	}
}

func (s sock) read() string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, b, err := s.ws.Read(ctx)
	if err != nil {
		die("read: %v", err)
	}
	return string(b)
}

func (s sock) until(want string) string {
	for range 100 {
		if l := s.read(); strings.Contains(l, want) {
			return l
		}
	}
	die("no line with %s", want)
	return ""
}

func open(origin, identity string, key, controlKey []byte) sock {
	h := http.Header{}
	h.Set("Origin", origin)
	ws, _, err := websocket.Dial(context.Background(), strings.Replace(origin, "http", "ws", 1)+"/v1/connect",
		&websocket.DialOptions{HTTPHeader: h})
	if err != nil {
		die("dial: %v", err)
	}
	ws.SetReadLimit(64 << 20)
	s := sock{ws}
	var hello struct{ Hello auth.Hello }
	json.Unmarshal([]byte(s.read()), &hello)
	if c, _ := auth.B64URL(hello.Hello.Control); string(c) != string(controlKey) {
		die("the hello is from another control plane")
	}
	sn, _ := auth.B64URL(hello.Hello.Nonce)
	pn := auth.Nonce()
	s.send(auth.Line("auth", auth.Auth{ID: identity, Nonce: auth.ToB64URL(pn),
		MAC: auth.ToB64URL(auth.PeerMAC(key, sn, pn, identity, origin)), Kind: "browser"}))
	line := s.read()
	var ok struct {
		OK *auth.OK `json:"ok"`
	}
	json.Unmarshal([]byte(line), &ok)
	if ok.OK == nil {
		die("refused: %s", line)
	}
	if m, _ := auth.B64URL(ok.OK.MAC); string(m) != string(auth.ServerMAC(key, sn, pn, identity, origin)) {
		die("the ok's MAC does not match")
	}
	return s
}

func main() {
	if len(os.Args) != 3 {
		die("webcheck <web port> '<browser code>'")
	}
	origin := "http://localhost:" + os.Args[1]
	code, err := auth.ParseCode(os.Args[2])
	if err != nil {
		die("%v", err)
	}
	p := open(origin, "p:"+code.ID(), auth.CodeKey(code.Secret), code.ControlKey)
	priv := auth.NewPrivateKey()
	pub, _ := auth.PublicKey(priv)
	id := records.NewUUID()
	b, _ := json.Marshal(map[string]any{"id": id, "publicKey": pub, "name": "webcheck", "kind": "browser"})
	p.send(`{"jsonrpc":"2.0","id":1,"method":"clients/announce","params":` + string(b) + `}`)
	fmt.Println("announce:", p.read())
	key, _ := auth.ClientKey(priv, code.ControlKey, id)
	c := open(origin, "c:"+id, key, code.ControlKey)
	c.send(`{"m":{"jsonrpc":"2.0","id":2,"method":"control/status"}}`)
	fmt.Println("status:", c.until(`"id":2`))
	c.send(`{"h":"mac","m":{"jsonrpc":"2.0","id":3,"method":"daemon/ping"}}`)
	fmt.Println("mac:", c.until(`"id":3`))
	c.send(`{"h":"mac","m":{"jsonrpc":"2.0","id":4,"method":"agents/list","params":{"includeArchived":false}}}`)
	l := c.until(`"id":4`)
	fmt.Printf("agents/list: %d bytes\n", len(l))
}
