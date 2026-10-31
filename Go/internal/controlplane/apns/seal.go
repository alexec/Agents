package apns

import (
	"crypto/ecdh"
	"crypto/hpke"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/alexec/agents/Go/wire"
)

// Purpose is the HPKE info a push's item is sealed under: not the headline's
// ("com.alexecollins.agents.headline.v1"), so one can never be opened as the other.
const Purpose = "com.alexecollins.agents.push.v1"

// Seal is Envelope.seal: HPKE (P-256, HKDF-SHA256, AES-256-GCM) to a device's P-256
// public key, X9.63, as CryptoKit's HPKE.Ciphersuite.P256_SHA256_AES_GCM_256 opens it.
func Seal(publicKey []byte, info string, plaintext []byte) (wire.SealedEnvelope, error) {
	key, err := ecdh.P256().NewPublicKey(publicKey)
	if err != nil {
		return wire.SealedEnvelope{}, fmt.Errorf("the device's key: %w", err)
	}
	recipient, err := hpke.NewDHKEMPublicKey(key)
	if err != nil {
		return wire.SealedEnvelope{}, err
	}
	enc, sender, err := hpke.NewSender(recipient, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(info))
	if err != nil {
		return wire.SealedEnvelope{}, err
	}
	ciphertext, err := sender.Seal(nil, plaintext)
	if err != nil {
		return wire.SealedEnvelope{}, err
	}
	return wire.SealedEnvelope{Encapsulated: enc, Ciphertext: ciphertext}, nil
}

// Open is Envelope.open, for tests and for a Go client: the device's own P-256 key opens
// what was sealed to it.
func Open(privateKey *ecdh.PrivateKey, info string, sealed wire.SealedEnvelope) ([]byte, error) {
	key, err := hpke.NewDHKEMPrivateKey(privateKey)
	if err != nil {
		return nil, err
	}
	recipient, err := hpke.NewRecipient(sealed.Encapsulated, key, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(info))
	if err != nil {
		return nil, err
	}
	return recipient.Open(nil, sealed.Ciphertext)
}

// Budget is Headline.budget: the most a banner's field carries, in characters.
const Budget = 100

// AnswerBudget is QuickAnswer.titleBudget: the most a banner's button says.
const AnswerBudget = 40

// Truncated is Headline.truncating: every field cut to the budget before it is sealed,
// and an empty one given the placeholder's word.
func Truncated(h wire.Headline) wire.Headline {
	out := wire.Headline{H1: cut(h.H1, "Agents"), H2: cut(h.H2, "An agent"), H3: cut(h.H3, "needs you")}
	for _, a := range h.Answers {
		fallback := a.ID
		if a.Kind == wire.QuickAnswerKindReply {
			fallback = "Reply"
		}
		a.Title = cutTo(a.Title, fallback, AnswerBudget)
		out.Answers = append(out.Answers, a)
	}
	return out
}

func cut(text, fallback string) string { return cutTo(text, fallback, Budget) }

func cutTo(text, fallback string, budget int) string {
	trimmed := strings.TrimFunc(text, unicode.IsSpace)
	if trimmed == "" {
		return fallback
	}
	if utf8.RuneCountInString(trimmed) <= budget {
		return trimmed
	}
	return string([]rune(trimmed)[:budget-1]) + "…"
}

// Token is NeedID.token: the need's name on a device, which a banner is threaded and
// replaced by.
func Token(id wire.NeedID) string {
	switch {
	case id.Permission != nil:
		return "permission:" + strings.ToUpper(string(*id.Permission))
	case id.Elicitation != nil:
		return "elicitation:" + strings.ToUpper(string(*id.Elicitation))
	case id.Report != nil:
		// Swift's Double description: a whole number keeps its ".0".
		at := strconv.FormatFloat(float64(id.Report.At), 'f', -1, 64)
		if !strings.Contains(at, ".") {
			at += ".0"
		}
		return "report:" + strings.ToUpper(string(id.Report.AgentID)) + ":" + at
	case id.GuardedChange != nil:
		folder := string(id.GuardedChange.Folder)
		if u, err := url.Parse(folder); err == nil && u.Scheme == "file" {
			folder = u.Path
		}
		return "guarded:" + folder + ":" + id.GuardedChange.Path
	case id.Notice != nil:
		// What an agent told the person (#2805): the host's id, a string as Swift keeps it.
		return "notice:" + *id.Notice
	}
	return ""
}

// CollapseID is the apns-collapse-id for a need: the token CloudKit's subscription
// collapses by (so a banner from the relay and one from here are one banner), unless it
// names a file or is longer than APNs allows. Then a hash, which names nothing.
func CollapseID(id wire.NeedID) string {
	token := Token(id)
	if token != "" && !strings.HasPrefix(token, "guarded:") && len(token) <= 64 {
		return token
	}
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
