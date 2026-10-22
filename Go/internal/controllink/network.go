package controllink

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// On a corporate network (#2177) the control dial goes out through the network's proxy,
// and trusts the organisation's own CA where the network re-signs TLS.
//
// The proxy: HTTPS_PROXY, HTTP_PROXY and NO_PROXY (or their lower-case names) when any is
// set, as on Linux. Otherwise, on a Mac, the proxies in System Settings ▸ Network ▸ Proxies
// (`scutil --proxy`): the web proxy for http and ws, the secure web proxy for https and wss,
// and their exceptions. A proxy auto-configuration (PAC) file is not read here; the Mac's
// windows, through URLSession, do follow it. Loopback is never sent to a proxy.
//
// The CA: the system's roots, and on a Mac the keychain's (the platform verifier), plus
// every certificate in the PEM file AGENTS_CA_FILE names, or else in /etc/agents/ca.pem. A
// pinned control plane is still checked by its pin alone, and every control plane by its
// key in the hello, whatever CA signed its certificate.

// transport is the HTTP transport for a control plane at pin (empty: no pin).
func transport(pin string) *http.Transport {
	return &http.Transport{Proxy: Proxy, TLSClientConfig: tlsConfig(pin)}
}

// tlsConfig checks the control plane's certificate by its pin, or by TrustRoots.
func tlsConfig(pin string) *tls.Config {
	config := &tls.Config{MinVersion: tls.VersionTLS12}
	if pin == "" {
		config.RootCAs = TrustRoots()
		return config
	}
	config.InsecureSkipVerify = true
	config.VerifyPeerCertificate = func(raw [][]byte, _ [][]*x509.Certificate) error {
		if len(raw) == 0 {
			return errors.New("no certificate")
		}
		leaf, err := x509.ParseCertificate(raw[0])
		if err != nil {
			return err
		}
		sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
		if B64URL(sum[:]) != pin {
			return errors.New("the certificate is not the pinned one")
		}
		return nil
	}
	return config
}

// caFile is where a Linux machine's administrator puts the organisation's CA.
var caFile = "/etc/agents/ca.pem"

// TrustRoots is nil (the system's roots) unless a CA is added: the organisation's
// (AGENTS_CA_FILE, or caFile), or a walk's test root (TestTrustRoots).
func TrustRoots() *x509.CertPool {
	pool := TestTrustRoots()
	file := os.Getenv("AGENTS_CA_FILE")
	if file == "" {
		file = caFile
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return pool
	}
	if pool == nil {
		if pool, err = x509.SystemCertPool(); err != nil {
			pool = x509.NewCertPool()
		}
	}
	pool.AppendCertsFromPEM(data)
	return pool
}

// Proxy is the proxy for a request to a control plane, or nil to go straight there. A
// variable, so a test can send dials through its own proxy.
var Proxy = func(r *http.Request) (*url.URL, error) {
	if proxyInEnvironment() {
		return http.ProxyFromEnvironment(r)
	}
	if runtime.GOOS == "darwin" {
		return macProxies().forURL(r.URL), nil
	}
	return nil, nil
}

func proxyInEnvironment() bool {
	for _, name := range []string{"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy"} {
		if os.Getenv(name) != "" {
			return true
		}
	}
	return false
}

// proxies are the Mac's proxy settings, as `scutil --proxy` says them.
type proxies struct {
	http, https  string // host:port, or empty when off
	exceptions   []string
	simpleDirect bool // ExcludeSimpleHostnames: a name with no dot goes straight
}

var (
	macMu      sync.Mutex
	macRead    time.Time
	macCached  proxies
	scutilText = func() string {
		out, _ := exec.Command("/usr/sbin/scutil", "--proxy").Output()
		return string(out)
	}
)

// macProxies reads the settings at most once a minute: a dial that retries does not run
// scutil each time.
func macProxies() proxies {
	macMu.Lock()
	defer macMu.Unlock()
	if time.Since(macRead) > time.Minute {
		macCached, macRead = parseScutil(scutilText()), time.Now()
	}
	return macCached
}

// parseScutil reads `scutil --proxy`: "Key : value" lines, and the ExceptionsList's
// "N : pattern" lines inside its <array>.
func parseScutil(text string) proxies {
	values := map[string]string{}
	var p proxies
	inExceptions := false
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		key, value, ok := strings.Cut(line, " : ")
		switch {
		case inExceptions && line == "}":
			inExceptions = false
		case inExceptions && ok:
			p.exceptions = append(p.exceptions, strings.TrimSpace(value))
		case ok && key == "ExceptionsList":
			inExceptions = true
		case ok:
			values[key] = strings.TrimSpace(value)
		}
	}
	proxy := func(kind string) string {
		host, port := values[kind+"Proxy"], values[kind+"Port"]
		if values[kind+"Enable"] != "1" || host == "" {
			return ""
		}
		if port == "" {
			port = "80"
		}
		return net.JoinHostPort(host, port)
	}
	p.http, p.https = proxy("HTTP"), proxy("HTTPS")
	p.simpleDirect = values["ExcludeSimpleHostnames"] == "1"
	return p
}

// forURL is the proxy for u: by its scheme, unless its host is loopback or an exception.
func (p proxies) forURL(u *url.URL) *url.URL {
	address := p.http
	if s := strings.ToLower(u.Scheme); s == "https" || s == "wss" {
		address = p.https
	}
	host := strings.ToLower(u.Hostname())
	if address == "" || host == "localhost" || p.excepted(host) {
		return nil
	}
	return &url.URL{Scheme: "http", Host: address}
}

// excepted says whether host goes straight: loopback, a simple name when so set, or one of
// the exceptions ("*.local", ".example.com", "example.com", "169.254/16", "10.0.0.0/8").
func (p proxies) excepted(host string) bool {
	addr, err := netip.ParseAddr(host)
	isIP := err == nil
	if isIP && addr.IsLoopback() {
		return true
	}
	if p.simpleDirect && !isIP && !strings.Contains(host, ".") {
		return true
	}
	for _, e := range p.exceptions {
		e = strings.ToLower(strings.TrimSpace(e))
		if prefix, ok := cidr(e); ok {
			if isIP && prefix.Contains(addr) {
				return true
			}
			continue
		}
		e = strings.TrimPrefix(e, "*")
		if host == strings.TrimPrefix(e, ".") || strings.HasPrefix(e, ".") && strings.HasSuffix(host, e) {
			return true
		}
	}
	return false
}

// cidr reads an exception as an address range: "10.0.0.0/8", or the Mac's short "169.254/16".
func cidr(e string) (netip.Prefix, bool) {
	address, bits, ok := strings.Cut(e, "/")
	if !ok {
		return netip.Prefix{}, false
	}
	n, err := strconv.Atoi(bits)
	if err != nil {
		return netip.Prefix{}, false
	}
	if !strings.Contains(address, ":") {
		for strings.Count(address, ".") < 3 {
			address += ".0"
		}
	}
	a, err := netip.ParseAddr(address)
	if err != nil {
		return netip.Prefix{}, false
	}
	prefix, err := a.Prefix(n)
	return prefix, err == nil
}
