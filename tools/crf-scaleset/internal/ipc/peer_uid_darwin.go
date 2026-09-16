//go:build darwin && cgo

package ipc

/*
#include <sys/types.h>
#include <unistd.h>
*/
import "C"

func peerUID(fd uintptr) (uint32, bool) {
	var uid C.uid_t
	var gid C.gid_t
	if C.getpeereid(C.int(fd), &uid, &gid) != 0 {
		return 0, false
	}
	return uint32(uid), true
}
