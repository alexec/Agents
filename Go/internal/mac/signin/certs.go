// Package signin is the Mac end of a sign-in relay (047 Codex's, 056 Claude's; 058 T091),
// as MacSignInRelay.swift: a runtime on a server signs in with this Mac's own sign-in,
// which never leaves the Mac. The server's runtime holds a stand-in with no secret in it;
// its requests reach a TLS relay on this Mac's loopback through a tunnel the control plane
// opens, and go on to the runtime's own service with this Mac's current token in place of
// the stand-in's. Logs say a method, a path and a status: never a header or a body.
package signin

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// Certificates is RelayCertificates: a certificate authority made once for this Mac, and a
// server certificate for 127.0.0.1 it signs (rustls refuses a certificate that is its own
// CA). The keys stay in Folder (<root>/relay), private to this account; only the CA's
// public certificate is ever sent to a server. The Swift host's files are read as they
// are: ca.pem, relay-cert.pem and relay-key.pem, which it keeps beside its relay.p12.
type Certificates struct {
	Folder string
}

func (c Certificates) caCert() string { return filepath.Join(c.Folder, "ca.pem") }
func (c Certificates) caKey() string  { return filepath.Join(c.Folder, "ca-key.pem") }
func (c Certificates) cert() string   { return filepath.Join(c.Folder, "relay-cert.pem") }
func (c Certificates) key() string    { return filepath.Join(c.Folder, "relay-key.pem") }
func exists(p string) bool            { _, err := os.Stat(p); return err == nil }
func (c Certificates) complete() bool {
	return exists(c.caCert()) && exists(c.cert()) && exists(c.key())
}

// CAPEM is the CA's public certificate, made first if need be.
func (c Certificates) CAPEM() (string, error) {
	if err := c.Ensure(); err != nil {
		return "", err
	}
	b, err := os.ReadFile(c.caCert())
	return string(b), err
}

// Identity is the server certificate and its key, for TLS.
func (c Certificates) Identity() (tls.Certificate, error) {
	if err := c.Ensure(); err != nil {
		return tls.Certificate{}, err
	}
	return tls.LoadX509KeyPair(c.cert(), c.key())
}

// Ensure makes the CA and the server certificate when either is missing: P-256 and
// SHA-256, two years each, the folder 0700 and every key 0600.
func (c Certificates) Ensure() error {
	if c.complete() {
		return nil
	}
	if err := os.MkdirAll(c.Folder, 0o700); err != nil {
		return err
	}
	now := time.Now()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	caTemplate := &x509.Certificate{
		SerialNumber: serial(), Subject: pkix.Name{CommonName: "Agents sign-in relay"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.AddDate(0, 0, 730),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return err
	}
	ca, _ := x509.ParseCertificate(caDER)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	template := &x509.Certificate{
		SerialNumber: serial(), Subject: pkix.Name{CommonName: "127.0.0.1"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.AddDate(0, 0, 730),
		IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1)}, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		KeyUsage: x509.KeyUsageDigitalSignature, BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, ca, &key.PublicKey, caKey)
	if err != nil {
		return err
	}
	write := func(path, kind string, b []byte, mode os.FileMode) error {
		return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: b}), mode)
	}
	caKeyDER, err := x509.MarshalPKCS8PrivateKey(caKey)
	if err != nil {
		return err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	// The keys first, the CA last: a folder is complete only once all are there.
	return errors.Join(write(c.caKey(), "PRIVATE KEY", caKeyDER, 0o600), write(c.key(), "PRIVATE KEY", keyDER, 0o600),
		write(c.cert(), "CERTIFICATE", der, 0o644), write(c.caCert(), "CERTIFICATE", caDER, 0o644))
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	return n
}
