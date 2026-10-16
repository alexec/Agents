package sandbox

import "path/filepath"

func evalSymlinks(p string) (string, error) { return filepath.EvalSymlinks(p) }
