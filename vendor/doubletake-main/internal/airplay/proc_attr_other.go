//go:build !linux

// AirPlay Splitter additions to doubletake (LGPL-3.0-or-later, same as upstream).

package airplay

import "syscall"

// childProcAttr: macOS has no parent-death signal. Put the GStreamer child in
// its own process group; doubletake's context cancellation still stops it.
func childProcAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true}
}
