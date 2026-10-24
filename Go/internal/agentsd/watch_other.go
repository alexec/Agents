//go:build !linux && !darwin

package agentsd

// folderWatch hears nothing off Linux and macOS.
type folderWatch struct{}

func newFilesWatch(string, func([]string)) (*folderWatch, error) { return &folderWatch{}, nil }
func (*folderWatch) stop()                                        {}

func newFolderWatch(string, func([]string)) (*folderWatch, error) { return &folderWatch{}, nil }
