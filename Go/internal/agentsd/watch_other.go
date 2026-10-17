//go:build !linux

package agentsd

// folderWatch hears nothing off Linux yet: the Mac daemon in Go is step 3 (#1138).
type folderWatch struct{}

func newFolderWatch(string, func([]string)) (*folderWatch, error) { return &folderWatch{}, nil }
func (*folderWatch) stop()                                        {}

func newProjectWatch(string, func([]string)) (*folderWatch, error) { return &folderWatch{}, nil }
