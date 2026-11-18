//go:build linux

package airplay

import "syscall"

// childProcAttr kills the GStreamer child if doubletake dies.
func childProcAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}
