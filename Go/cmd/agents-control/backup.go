package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/alexec/agents/Go/internal/controlplane"
)

// homeParts is where this control plane keeps what a restore needs besides the store
// (#2137), as serve finds each: the key file, secrets-key beside it, the certificate
// (--self-signed, the home's tls/, or AGENTS_CONTROL_TLS_CERT/_KEY) and the APNs key.
func homeParts() controlplane.HomeParts {
	var p controlplane.HomeParts
	if file := keyFile(); file != "" {
		p.ControlKey = file
		p.SecretsKey = filepath.Join(filepath.Dir(file), "secrets-key")
	}
	// Agents Host hands the key in from the keychain: --key-fd, or AGENTS_CONTROL_KEY.
	p.GivenKey = givenKey()
	if dir := value("--self-signed"); dir != "" || home() != "" {
		if dir == "" {
			dir = filepath.Join(home(), "tls")
		}
		p.TLSCert, p.TLSKey = filepath.Join(expand(dir), "cert.pem"), filepath.Join(expand(dir), "key.pem")
	} else if cert, key := os.Getenv("AGENTS_CONTROL_TLS_CERT"), os.Getenv("AGENTS_CONTROL_TLS_KEY"); cert != "" && key != "" {
		p.TLSCert, p.TLSKey = cert, key
	}
	if file := os.Getenv("AGENTS_APNS_KEY_FILE"); file != "" {
		p.APNsKey = file
	} else if home() != "" {
		p.APNsKey = filepath.Join(home(), "apns.p8")
	}
	return p
}

// backup is `agents-control backup --to DIR`: the store and every part beside it, into a
// new folder. Stop the control plane first, or the backup misses what changes meanwhile.
// A key handed in (--key-fd N) is the backup's control-key.
func backup() {
	to := value("--to")
	if to == "" {
		fail("say where the backup goes: --to DIR, a new folder")
	}
	list, err := controlplane.Backup(context.Background(), openStore(""), homeParts(), expand(to))
	if err != nil {
		fail("backup: %v", err)
	}
	fmt.Printf("backed up %d records and %s into %s\n", list.Records, words(list.Files), to)
	if os.Getenv("AGENTS_CONTROL_KMS") != "" {
		fmt.Println("the control key is sealed in the store's copy: a restore needs the same KMS key, " +
			"or run key export as well")
	}
	fmt.Println("it holds keys in clear: keep it as safe as the control plane's own folder")
}

// restore is `agents-control restore --from DIR`, into the home, key file and store that
// serve with the same flags and environment would use, each of them new. --new-kms leaves
// out the control key the old KMS sealed: seal the exported key with the new one after.
func restore() {
	from := value("--from")
	if from == "" {
		fail("say which backup: --from DIR")
	}
	list, err := controlplane.Restore(context.Background(), expand(from), homeParts(), openStore(""), has("--new-kms"))
	if err != nil {
		fail("restore: %v", err)
	}
	fmt.Printf("restored %d records and %s from the backup of %s\n", list.Records, words(list.Files),
		list.Made.Format("2006-01-02 15:04 MST"))
	for _, kept := range list.Kept {
		fmt.Println("left " + kept + " as it was")
	}
	if p := homeParts(); p.APNsKey != "" && os.Getenv("AGENTS_APNS_KEY_FILE") == "" {
		if _, err := os.Stat(p.APNsKey); err == nil {
			fmt.Println("the APNs key is at " + p.APNsKey + ": give it as AGENTS_APNS_KEY_FILE")
		}
	}
}

func words(files []string) string {
	if len(files) == 0 {
		return "no other file"
	}
	return strings.Join(files, ", ")
}
