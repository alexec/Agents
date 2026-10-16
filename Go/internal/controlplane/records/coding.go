package records

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"time"
)

// Stamp is a date as the stores write it (ControlRecords.encoder): ISO 8601, UTC, with
// milliseconds. Dates without fractional seconds are read too, as Swift reads them.
type Stamp struct{ time.Time }

const isoMillis = "2006-01-02T15:04:05.000Z07:00"

// Now is the time to the millisecond, as every copy reads it back.
func Now() Stamp { return Stamp{time.Now().UTC().Truncate(time.Millisecond)} }

// At is t to the millisecond.
func At(t time.Time) Stamp { return Stamp{t.UTC().Truncate(time.Millisecond)} }

func (s Stamp) MarshalJSON() ([]byte, error) { return json.Marshal(s.UTC().Format(isoMillis)) }

func (s *Stamp) UnmarshalJSON(b []byte) error {
	var text string
	if err := json.Unmarshal(b, &text); err != nil {
		return err
	}
	t, err := time.Parse(time.RFC3339Nano, text)
	if err != nil {
		return fmt.Errorf("not an ISO 8601 date: %s", text)
	}
	s.Time = t
	return nil
}

// Encode is ControlRecords.encoder: pretty, keys sorted, slashes and HTML characters as
// they are.
func Encode(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	// Through a generic value, so every object's keys come out sorted, as Swift's
	// .sortedKeys has them.
	var generic any
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	if err := d.Decode(&generic); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	e := json.NewEncoder(&out)
	e.SetEscapeHTML(false)
	e.SetIndent("", "  ")
	if err := e.Encode(generic); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(out.Bytes(), []byte("\n")), nil
}

// Extra is what a record held that this build does not know: a later Swift or Go
// build's fields. It is written back as it was, so a Go copy never drops what another
// copy wrote.
type Extra map[string]json.RawMessage

var knownFields sync.Map // reflect.Type → map[string]bool

func fieldsOf(t reflect.Type) map[string]bool {
	if known, ok := knownFields.Load(t); ok {
		return known.(map[string]bool)
	}
	known := map[string]bool{}
	for i := range t.NumField() {
		tag := t.Field(i).Tag.Get("json")
		name, _, _ := strings.Cut(tag, ",")
		if name != "" && name != "-" {
			known[name] = true
		}
	}
	knownFields.Store(t, known)
	return known
}

// decodeKeeping decodes data into v (a pointer to a struct with no methods of its own),
// checks that each of required is there, as Swift's decoder does for a field that is
// not optional, and returns what it did not know.
func decodeKeeping(data []byte, v any, required ...string) (Extra, error) {
	var all map[string]json.RawMessage
	if err := json.Unmarshal(data, &all); err != nil {
		return nil, err
	}
	for _, name := range required {
		if raw, ok := all[name]; !ok || string(raw) == "null" {
			return nil, fmt.Errorf("no %s", name)
		}
	}
	if err := json.Unmarshal(data, v); err != nil {
		return nil, err
	}
	known := fieldsOf(reflect.TypeOf(v).Elem())
	var extra Extra
	for name, raw := range all {
		if !known[name] {
			if extra == nil {
				extra = Extra{}
			}
			extra[name] = raw
		}
	}
	return extra, nil
}

// encodeKeeping encodes v (a struct with no methods of its own) with extra beside it.
func encodeKeeping(v any, extra Extra) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil || len(extra) == 0 {
		return raw, err
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(raw, &all); err != nil {
		return nil, err
	}
	for name, value := range extra {
		if _, ok := all[name]; !ok {
			all[name] = value
		}
	}
	return json.Marshal(all)
}
