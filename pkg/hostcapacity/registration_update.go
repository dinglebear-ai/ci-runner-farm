package hostcapacity

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
)

// WithRegistrationPolicyCAS authorizes Farm's private sibling publication while
// retaining the existing shared lease. It never writes the shared document.
func (l *Lease) WithRegistrationPolicyCAS(expected string, idle func() error, publish func() error) error {
	if err := l.checkExpansionPublication(); err != nil {
		return err
	}
	if l.Config.Mode != "active" || l.Config.PoolExpansion != nil || idle == nil || publish == nil {
		return errors.New("registration update requires stable active owner")
	}
	check := func() error {
		raw, err := os.ReadFile(l.path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(raw)
		if hex.EncodeToString(sum[:]) != expected {
			return errors.New("registration shared policy CAS changed")
		}
		return nil
	}
	if err := check(); err != nil {
		return err
	}
	if err := idle(); err != nil {
		return err
	}
	if err := l.checkExpansionPublication(); err != nil {
		return err
	}
	if err := check(); err != nil {
		return err
	}
	return publish()
}
