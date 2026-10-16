//go:build !linux && !darwin

package sandbox

import "fmt"

func Exec(args []string) error  { return fmt.Errorf("no sandbox on this system") }
func Available() (bool, string) { return false, "no sandbox on this system" }
