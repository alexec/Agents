package service

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/alexec/agents/controlplane-go/internal/auth"
)

// MachineID is MachineID.current: AGENTS_MACHINE_ID, else the Mac's hardware UUID (what
// gethostuuid gives, read here from ioreg, as there is no cgo), else /etc/machine-id.
func MachineID() string {
	if id := os.Getenv("AGENTS_MACHINE_ID"); id != "" {
		return id
	}
	if out, err := exec.Command("/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice").Output(); err == nil {
		if m := regexp.MustCompile(`"IOPlatformUUID" = "([0-9A-Fa-f-]+)"`).FindSubmatch(out); m != nil {
			return strings.ToUpper(string(m[1]))
		}
	}
	for _, f := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
		if b, err := os.ReadFile(f); err == nil && strings.TrimSpace(string(b)) != "" {
			return strings.TrimSpace(string(b))
		}
	}
	h, _ := os.Hostname()
	return h
}

// LocalName is this Mac's name as the window's browser shows it.
func LocalName() string {
	if out, err := exec.Command("/usr/sbin/scutil", "--get", "ComputerName").Output(); err == nil {
		if n := strings.TrimSpace(string(out)); n != "" {
			return n
		}
	}
	h, _ := os.Hostname()
	return h
}

// SelfSigned makes (once) and loads a certificate in dir, as SelfSigned.swift does with
// openssl, here with crypto/x509: clients take it by its pin, never by its name.
func SelfSigned(dir, name string) (*tls.Config, string, error) {
	certFile, keyFile := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if _, err := os.Stat(certFile); err != nil {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, "", err
		}
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, "", err
		}
		serial, _ := rand.Int(rand.Reader, big.NewInt(1<<62))
		tmpl := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: name},
			NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(10, 0, 0),
			KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
		der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
		if err != nil {
			return nil, "", err
		}
		kb, _ := x509.MarshalECPrivateKey(key)
		if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600); err != nil {
			return nil, "", err
		}
		if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
			return nil, "", err
		}
	}
	return LoadTLS(certFile, keyFile)
}

// LoadTLS is a certificate and key from files, and the certificate's pin: base64url of
// the SHA-256 of its SubjectPublicKeyInfo.
func LoadTLS(certFile, keyFile string) (*tls.Config, string, error) {
	pair, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, "", err
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, "", err
	}
	sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
	return &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12}, auth.ToB64URL(sum[:]), nil
}
