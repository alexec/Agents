package controllink

import (
	"crypto/ecdh"
	"crypto/hpke"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Client sealing (#3397, specs/3397-client-sealing): an admin's client seals each of an
// org route's secrets, and a person's client each of their own secrets, with HPKE straight
// to each machine (and each client) that may hold it. The control plane keeps and sends
// the envelopes and never opens one. The web page (Web/src/wire/sealing.ts) and AgentsKit
// (Sealing.swift) make the same associated data, byte for byte.

const (
	// OrgRoutePurpose is HPKE's info an org route's secret is sealed under (#999, #3397).
	// v3: sealed by the admin's client, bound to where the key goes.
	OrgRoutePurpose = "com.alexecollins.agents.orgroute.v3"
	// UserSecretPurpose is HPKE's info a person's own secret is sealed under (#3397).
	UserSecretPurpose = "com.alexecollins.agents.usersecret.v1"
)

// MachineRecipient and ClientRecipient name what a value is sealed to, as the associated
// data and the sealed records name it.
func MachineRecipient(host string) string { return "m:" + host }

// ClientRecipient is a client's name as a recipient: its id in upper case.
func ClientRecipient(client string) string { return "c:" + strings.ToUpper(client) }

// routeSettingLines are the settings that bind a route's secrets, in this order.
func routeSettingLines(s *wire.OrgRouteSettings) string {
	if s == nil {
		s = &wire.OrgRouteSettings{}
	}
	var b strings.Builder
	for _, f := range []struct {
		name  string
		value *string
	}{
		{"address", s.Address}, {"apiVersion", s.ApiVersion}, {"clientID", s.ClientID}, {"header", s.Header},
		{"location", s.Location}, {"project", s.Project}, {"region", s.Region}, {"resource", s.Resource}, {"tenant", s.Tenant},
	} {
		if f.value != nil {
			fmt.Fprintf(&b, "%s=%s\n", f.name, *f.value)
		}
	}
	return b.String()
}

// OrgRouteBinding is the hex SHA-256 of a route's settings, one name=value line each.
func OrgRouteBinding(s *wire.OrgRouteSettings) string {
	sum := sha256.Sum256([]byte(routeSettingLines(s)))
	return hex.EncodeToString(sum[:])
}

// OrgRouteAD is the associated data of one of a route's secrets for one recipient: the
// route, the recipient, the field, the seal's version, and where the key goes (kind,
// vendor, settings). A copy for another machine, another field or an older version does
// not open; nor does one whose address, header, region or kind was changed after an
// admin sealed it, by a control plane or on the machine.
func OrgRouteAD(route, recipient, field string, sealVersion int64, kind wire.OrgRouteKind, vendor *wire.OrgRouteVendor,
	settings *wire.OrgRouteSettings) []byte {
	v := ""
	if vendor != nil {
		v = string(*vendor)
	}
	return fmt.Appendf(nil, "orgroute.v3|%s|%s|%s|%d|%s|%s|%s", route, recipient, field, sealVersion, kind, v, OrgRouteBinding(settings))
}

// DeliveredRouteAD is OrgRouteAD for a delivered route and one of its fields.
func DeliveredRouteAD(r wire.DeliveredRoute, recipient, field string) []byte {
	return OrgRouteAD(r.ID, recipient, field, r.SealVersion, r.Kind, r.Vendor, r.Settings)
}

// UserSecretAD is the associated data of a person's secret for one recipient.
func UserSecretAD(user, recipient, name string, version int64) []byte {
	return fmt.Appendf(nil, "usersecret.v1|%s|%s|%s|%d", user, recipient, name, version)
}

// Seal is HPKE (P-256, HKDF-SHA256, AES-256-GCM) to a P-256 public key (X9.63), under info
// and with ad: what a client does, and the tests for it.
func Seal(publicKey []byte, info string, ad, value []byte) (wire.SealedEnvelope, error) {
	key, err := ecdh.P256().NewPublicKey(publicKey)
	if err != nil {
		return wire.SealedEnvelope{}, fmt.Errorf("the recipient's key: %w", err)
	}
	recipient, err := hpke.NewDHKEMPublicKey(key)
	if err != nil {
		return wire.SealedEnvelope{}, err
	}
	enc, sender, err := hpke.NewSender(recipient, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(info))
	if err != nil {
		return wire.SealedEnvelope{}, err
	}
	ciphertext, err := sender.Seal(ad, value)
	if err != nil {
		return wire.SealedEnvelope{}, err
	}
	return wire.SealedEnvelope{Encapsulated: enc, Ciphertext: ciphertext}, nil
}

// Open is Seal's other side, with the recipient's own P-256 private key (raw scalar).
func Open(privateKey []byte, info string, ad []byte, sealed wire.SealedEnvelope) ([]byte, error) {
	private, err := ecdh.P256().NewPrivateKey(privateKey)
	if err != nil {
		return nil, err
	}
	key, err := hpke.NewDHKEMPrivateKey(private)
	if err != nil {
		return nil, err
	}
	recipient, err := hpke.NewRecipient(sealed.Encapsulated, key, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(info))
	if err != nil {
		return nil, err
	}
	return recipient.Open(ad, sealed.Ciphertext)
}
