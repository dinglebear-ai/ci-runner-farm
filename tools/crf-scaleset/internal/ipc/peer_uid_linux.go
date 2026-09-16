//go:build linux

package ipc

import "syscall"

func peerUID(fd uintptr) (uint32, bool) {
	cred, err := syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	if err != nil {
		return 0, false
	}
	return cred.Uid, true
}
