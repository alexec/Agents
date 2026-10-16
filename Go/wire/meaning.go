package wire

import (
	"encoding/json"
	"strings"
	"time"
)

// The five meaning-types (#1134): what a value means, not only its JSON shape, written by
// hand here as in Swift. The schema names each with x-go-type.

// UUID is upper case on the wire, as Swift's uuidString writes it. Any case reads.
type UUID string

// MarshalJSON writes the UUID upper case.
func (u UUID) MarshalJSON() ([]byte, error) { return json.Marshal(strings.ToUpper(string(u))) }

// Date is Swift's Date through a plain JSONEncoder: seconds since 2001-01-01T00:00:00Z. It
// is kept as those seconds, so a value read and written again is the same number.
type Date float64

// reference is Swift's reference date, 2001-01-01T00:00:00Z.
var reference = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)

// DateOf is the Date of a time.
func DateOf(t time.Time) Date { return Date(t.Sub(reference).Seconds()) }

// Time is the time a Date says.
func (d Date) Time() time.Time {
	return reference.Add(time.Duration(float64(d) * float64(time.Second)))
}

// Data is Swift's Data: standard base64 with padding, as encoding/json writes []byte.
type Data = []byte

// URL is Swift's URL: an absolute URL as text, a file URL for a path.
type URL string

// JSONValue is any JSON, Swift's JSONValue, kept as it was read.
type JSONValue = json.RawMessage
