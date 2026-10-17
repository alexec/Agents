package agentsd

import (
	"syscall"
	"unsafe"
)

// diskVolume names a Mac's volume as Foundation's volumeName does ("Macintosh HD"), and
// keys it by where it is mounted, as the Swift host's reading does. The data volume is
// firmlinked under the system one, and Foundation reports both as "/".
func diskVolume(st *syscall.Statfs_t, _ uint64) (name, mount string) {
	mount = cString(st.Mntonname[:])
	if mount == "/System/Volumes/Data" {
		mount = "/"
	}
	if name = volumeName(mount); name == "" {
		name = mount
	}
	return name, mount
}

func cString(b []int8) string {
	n := 0
	for n < len(b) && b[n] != 0 {
		n++
	}
	out := make([]byte, n)
	for i := range n {
		out[i] = byte(b[i])
	}
	return string(out)
}

// volumeName reads ATTR_VOL_NAME with getattrlist(2), so no cgo is needed.
func volumeName(mount string) string {
	const attrVolInfo, attrVolName = 0x80000000, 0x2000
	list := struct {
		bitmapCount uint16
		reserved    uint16
		common      uint32
		vol         uint32
		dir         uint32
		file        uint32
		fork        uint32
	}{bitmapCount: 5, vol: attrVolInfo | attrVolName}
	path, err := syscall.BytePtrFromString(mount)
	if err != nil {
		return ""
	}
	var buf [4 + 8 + 1024]byte
	if _, _, e := syscall.Syscall6(syscall.SYS_GETATTRLIST, uintptr(unsafe.Pointer(path)),
		uintptr(unsafe.Pointer(&list)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0); e != 0 {
		return ""
	}
	// The buffer: its length, then an attrreference_t (offset from itself, length with the NUL).
	offset := int(int32(uint32(buf[4]) | uint32(buf[5])<<8 | uint32(buf[6])<<16 | uint32(buf[7])<<24))
	length := int(uint32(buf[8]) | uint32(buf[9])<<8 | uint32(buf[10])<<16 | uint32(buf[11])<<24)
	start := 4 + offset
	if length < 1 || start < 12 || start+length > len(buf) {
		return ""
	}
	return string(buf[start : start+length-1])
}
