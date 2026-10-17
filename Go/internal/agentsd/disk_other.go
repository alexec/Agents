//go:build !darwin

package agentsd

import (
	"strconv"
	"syscall"
)

// diskVolume names a server's disk by its device, as the Swift host does off a Mac.
func diskVolume(_ *syscall.Statfs_t, dev uint64) (name, mount string) {
	return "This server’s disk", "device-" + strconv.FormatUint(dev, 10)
}
