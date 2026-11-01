//go:build !unix

package hosted

import "errors"

// DiskOf reads the disk that holds path: never, on a system without statfs.
func DiskOf(string) func() (Space, error) {
	return func() (Space, error) { return Space{}, errors.New("the disk cannot be read on this system") }
}
