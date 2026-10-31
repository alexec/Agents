package wire

import "strings"

// The wire's host/* and hosts/* methods are renamed machine/* and machines/* over three
// releases (#2653, after #2316), so that the skew check's rolling update keeps working:
//
//  1. Receivers accept both names, and the control plane says machine/1 beside host/1.
//     Senders still use host/* and hosts/*. (This release.)
//  2. Senders use machine/* and machines/*. Receivers still accept both.
//  3. The old names are removed.
//
// Until step 3 the documents and the code keep the old names; a receiver reads a new name
// as its old one with OldMethodName, where it decodes a message, and a sender that can't
// change a generated Name directly sends its new name with NewMethodName.

// renamed is each old prefix by its new one.
var renamed = [][2]string{{"machine/", "host/"}, {"machines/", "hosts/"}}

// OldMethodName is method under its old name when it is the new name of a host/* or
// hosts/* method of control.openrpc.json (machines/list is hosts/list), and method itself
// otherwise. A method that has the new name already (machines/forAgent) stays as it is.
func OldMethodName(method string) string {
	if _, ok := ControlCapabilities[method]; ok {
		return method
	}
	if _, ok := HostCapabilities[method]; ok {
		return method
	}
	for _, r := range renamed {
		if rest, ok := strings.CutPrefix(method, r[0]); ok {
			old := r[1] + rest
			if _, known := ControlCapabilities[old]; known {
				return old
			}
		}
	}
	return method
}

// NewMethodName is method under its new name, the reverse of OldMethodName: a sender
// uses it to send a host/* or hosts/* method of control.openrpc.json (hosts/list is
// machines/list) as its machine/* or machines/* name (#2653), where it can't change a
// generated Method's or Notification's Name directly.
func NewMethodName(method string) string {
	for _, r := range renamed {
		if rest, ok := strings.CutPrefix(method, r[1]); ok {
			return r[0] + rest
		}
	}
	return method
}
