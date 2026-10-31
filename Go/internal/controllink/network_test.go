package controllink

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// echoSocket is a control plane's /v1/connect that says one line.
func echoSocket(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer ws.CloseNow()
	ws.Write(r.Context(), websocket.MessageText, []byte("hello"))
	ws.Read(r.Context())
}

// connectProxy is an HTTP proxy that only tunnels (CONNECT), as a corporate one does for
// HTTPS, and notes each address it was asked for.
type connectProxy struct {
	mu    sync.Mutex
	asked []string
}

func (p *connectProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodConnect {
		http.Error(w, "CONNECT only", http.StatusMethodNotAllowed)
		return
	}
	p.mu.Lock()
	p.asked = append(p.asked, r.Host)
	p.mu.Unlock()
	upstream, err := net.Dial("tcp", r.Host)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	conn, buffered, err := w.(http.Hijacker).Hijack()
	if err != nil {
		upstream.Close()
		return
	}
	conn.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))
	go func() {
		io.Copy(upstream, buffered)
		upstream.Close()
	}()
	io.Copy(conn, upstream)
	conn.Close()
}

func useProxy(t *testing.T, f func(*http.Request) (*url.URL, error)) {
	previous := Proxy
	Proxy = f
	t.Cleanup(func() { Proxy = previous })
}

func pinOf(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	return B64URL(sum[:])
}

func readHello(t *testing.T, l *Lines) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if line, err := l.Read(ctx); err != nil || line != "hello" {
		t.Fatal(line, err)
	}
}

// A dial goes through the network's proxy, by CONNECT, and the pin is still checked (#2177).
func TestADialGoesThroughAProxy(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(echoSocket))
	defer server.Close()
	proxy := &connectProxy{}
	proxyServer := httptest.NewServer(proxy)
	defer proxyServer.Close()
	proxyURL, _ := url.Parse(proxyServer.URL)
	useProxy(t, http.ProxyURL(proxyURL))

	l, err := Dial(context.Background(), server.URL, pinOf(server.Certificate()))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	readHello(t, l)
	proxy.mu.Lock()
	asked := proxy.asked
	proxy.mu.Unlock()
	if len(asked) != 1 || asked[0] != server.Listener.Addr().String() {
		t.Fatal(asked)
	}
	// Through the proxy, a certificate that is not the pinned one is still refused.
	if _, err := Dial(context.Background(), server.URL, "not-the-pin"); err == nil {
		t.Fatal("a wrong pin was taken through the proxy")
	}
}

// testCA makes a CA, and a certificate for 127.0.0.1 that it signs.
func testCA(t *testing.T) (caPEM []byte, leaf tls.Certificate) {
	t.Helper()
	caKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Example Corp CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true,
		KeyUsage: x509.KeyUsageCertSign, BasicConstraintsValid: true}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	ca, _ = x509.ParseCertificate(caDER)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "control"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, ca, &key.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// A control plane signed by an organisation's CA is trusted only when that CA is given:
// AGENTS_CA_FILE, or /etc/agents/ca.pem (#2177).
func TestTheOrganisationsCAIsTrustedOnlyWhenGiven(t *testing.T) {
	useProxy(t, func(*http.Request) (*url.URL, error) { return nil, nil })
	caPEM, leaf := testCA(t)
	server := httptest.NewUnstartedServer(http.HandlerFunc(echoSocket))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{leaf}}
	server.StartTLS()
	defer server.Close()
	t.Setenv("AGENTS_TEST_TRUST_ROOT", "")
	previous := caFile
	caFile = filepath.Join(t.TempDir(), "none.pem")
	t.Cleanup(func() { caFile = previous })

	if _, err := Dial(context.Background(), server.URL, ""); err == nil {
		t.Fatal("a certificate from an unknown CA was taken")
	}

	file := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(file, caPEM, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTS_CA_FILE", file)
	l, err := Dial(context.Background(), server.URL, "")
	if err != nil {
		t.Fatal(err)
	}
	readHello(t, l)
	l.Close()

	// The default place, with no variable.
	t.Setenv("AGENTS_CA_FILE", "")
	caFile = file
	l, err = Dial(context.Background(), server.URL, "")
	if err != nil {
		t.Fatal(err)
	}
	readHello(t, l)
	l.Close()
}

// The Mac's proxy settings, as scutil --proxy prints them.
func TestTheMacsProxySettings(t *testing.T) {
	p := parseScutil(`<dictionary> {
  ExceptionsList : <array> {
    0 : *.local
    1 : 169.254/16
    2 : .corp.example.com
    3 : intranet
  }
  ExcludeSimpleHostnames : 1
  FTPPassive : 1
  HTTPEnable : 1
  HTTPPort : 3128
  HTTPProxy : proxy.example.com
  HTTPSEnable : 1
  HTTPSPort : 8443
  HTTPSProxy : secure.example.com
  ProxyAutoConfigEnable : 0
}`)
	for address, want := range map[string]string{
		"https://control.example.com":   "http://secure.example.com:8443",
		"wss://control.example.com/v1":  "http://secure.example.com:8443",
		"http://control.example.com":    "http://proxy.example.com:3128",
		"https://mac.local:8791":        "",
		"https://169.254.3.4":           "",
		"https://a.corp.example.com":    "",
		"https://intranet":              "",
		"https://devbox":                "",
		"https://127.0.0.1:8791":        "",
		"https://localhost:8791":        "",
		"https://10.0.0.5":              "http://secure.example.com:8443",
		"https://notcorp.example.com.x": "http://secure.example.com:8443",
	} {
		u, _ := url.Parse(address)
		got := ""
		if proxy := p.forURL(u); proxy != nil {
			got = proxy.String()
		}
		if got != want {
			t.Errorf("%s: %q, want %q", address, got, want)
		}
	}
	if off := parseScutil("<dictionary> {\n  HTTPSEnable : 0\n  HTTPSProxy : secure.example.com\n}"); off.https != "" {
		t.Fatal(off)
	}
}
