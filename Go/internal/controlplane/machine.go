package controlplane

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
	"runtime"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/machine"
)

// MachineID is machine.ID: the id a host gives the control plane.
func MachineID() string { return machine.ID() }

// LocalName is this Mac's name as the window's browser shows it: its ComputerName.
func LocalName() string {
	if runtime.GOOS == "darwin" {
		if out, err := exec.Command("/usr/sbin/scutil", "--get", "ComputerName").Output(); err == nil {
			if n := strings.TrimSpace(string(out)); n != "" {
				return n
			}
		}
	}
	h, _ := os.Hostname()
	return h
}

// LocalHostName is LocalHostName.current: <name>.local, the address a Mac on the same
// network reaches this one at, its Bonjour name and not its Unix host name (#113).
func LocalHostName() string {
	if runtime.GOOS == "darwin" {
		if out, err := exec.Command("/usr/sbin/scutil", "--get", "LocalHostName").Output(); err == nil {
			if n := strings.TrimSpace(string(out)); n != "" {
				return strings.ToLower(n + ".local")
			}
		}
	}
	h, _ := os.Hostname()
	return localFromHostName(h)
}

func localFromHostName(name string) string {
	if !strings.HasSuffix(name, ".local") {
		name, _, _ = strings.Cut(name, ".")
		name += ".local"
	}
	return strings.ToLower(name)
}

// SelfSigned is SelfSigned.make: a certificate made once in dir and kept, for a copy
// that terminates TLS itself. Clients take it by its pin, never by its name. The files
// are the ones the Swift control plane makes with openssl (a P-256 key in SEC1 PEM, a
// certificate in PEM), so a change of language keeps the pin every member holds.
func SelfSigned(dir, name string) (*tls.Config, string, error) {
	certFile, keyFile := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	_, certErr := os.Stat(certFile)
	_, keyErr := os.Stat(keyFile)
	if certErr != nil || keyErr != nil {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, "", err
		}
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, "", err
		}
		serial, _ := rand.Int(rand.Reader, big.NewInt(1<<62))
		template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: name},
			NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(10, 0, 0),
			KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
		der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
		if err != nil {
			return nil, "", err
		}
		sec1, _ := x509.MarshalECPrivateKey(key)
		if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: sec1}), 0o600); err != nil {
			return nil, "", err
		}
		if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
			return nil, "", err
		}
	}
	return LoadTLS(certFile, keyFile)
}

// LoadTLS is SelfSigned.load: a certificate and key from files, as a server's, and the
// certificate's pin, base64url of the SHA-256 of its SubjectPublicKeyInfo.
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
	return &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12}, controllink.B64URL(sum[:]), nil
}
