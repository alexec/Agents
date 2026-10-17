//go:build !darwin

package store

func folders(root, home string, env func(string) string) Locations {
	return platformFolders(root, home, env)
}
