package controlplane

import (
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// The control plane's methods answer with the types in Go/wire, made from Packages/Wire
// (#1313). What is here turns its records into them.

// referenceDate is 2001-01-01T00:00:00Z, which Swift's dates count from, in Unix seconds.
const referenceDate = 978307200

// dateOf is a time on the wire, worked out as the control plane wrote dates before the
// generated types (#1313), so no date's bytes moved.
func dateOf(t time.Time) wire.Date {
	return wire.Date(float64(t.UnixNano()-referenceDate*int64(time.Second)) / 1e9)
}

// stampDate is a record's date on the wire, or nil.
func stampDate(s *records.Stamp) *wire.Date {
	if s == nil {
		return nil
	}
	return new(dateOf(s.Time))
}

// deref is what p points at, or T's zero.
func deref[T any](p *T) T {
	if p == nil {
		var zero T
		return zero
	}
	return *p
}

// optional is v, or nil for T's zero: what an omitempty field said before (#1313).
func optional[T comparable](v T) *T {
	var zero T
	if v == zero {
		return nil
	}
	return &v
}

// int64Of is a record's count on the wire.
func int64Of(n *int) *int64 {
	if n == nil {
		return nil
	}
	return new(int64(*n))
}

// hostIDs is a record's map of host ids on the wire; nil when it holds none.
func hostIDs(m map[string]string) map[string]wire.MachineRef {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]wire.MachineRef, len(m))
	for k, v := range m {
		out[k] = wire.MachineRef(v)
	}
	return out
}

// clientOnWire is a ClientRecord as clients/list answers it: grant operator, for an
// older build (#111).
func clientOnWire(c records.ClientRecord) wire.ClientRecord {
	return wire.ClientRecord{ID: wire.UUID(c.ID), Name: c.Name, Kind: wire.ClientKind(c.Kind), PublicKey: c.PublicKey,
		Grant: records.LegacyGrant, Paired: dateOf(c.Paired.Time), LastSeen: stampDate(c.LastSeen), MayNotify: c.MayNotify,
		Owner: c.Owner, Rev: int64(c.Rev), Forgotten: c.Forgotten, ForgottenAt: stampDate(c.ForgottenAt),
		KnownEpoch: int64Of(c.KnownEpoch)}
}

// MachineJoinStatus is DaemonAPI.MachineJoinStatus: how this Mac's host's join stands (#113).
type MachineJoinStatus = wire.MachineJoinStatus

// standardDetection is FolderDetection.standard (#429): where a host added from now on
// has its folders found, until a person says otherwise.
var standardDetection = wire.FolderDetection{Enabled: true, Paths: []string{"~", "~/src", "~/code", "~/folders", "~/Developer", "~/dev", "~/git"}}
