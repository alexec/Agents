package mac

import (
	"errors"
	"net"

	"golang.org/x/sys/unix"
)

// PeerToken is the audit token of the process on the other end of c, a connection on a
// Unix socket, from LOCAL_PEERTOKEN. An audit token is eight 32-bit words, the same size
// and shape as an ICMPv6 filter, so x/sys's getsockopt for one reads it without cgo.
func PeerToken(c net.Conn) (Token, error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return Token{}, errors.New("not a Unix socket")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return Token{}, err
	}
	var f *unix.ICMPv6Filter
	var gerr error
	if err := raw.Control(func(fd uintptr) {
		f, gerr = unix.GetsockoptICMPv6Filter(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERTOKEN)
	}); err != nil {
		return Token{}, err
	}
	if gerr != nil {
		return Token{}, gerr
	}
	return Token(f.Filt), nil
}
