//go:build darwin && !cgo

package ipc

// A Darwin binary built without cgo cannot call getpeereid. Fail closed rather
// than weakening the control-socket peer check or making the package unbuildable.
func peerUID(uintptr) (uint32, bool) {
	return 0, false
}
