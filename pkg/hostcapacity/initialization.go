package hostcapacity

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
)

// StandaloneInitializationIdentity binds recovery to every original owner field.
// Activation is the only permitted difference; no policy, epoch, storage or
// consumer change can be hidden behind an idempotent initialization retry.
func StandaloneInitializationIdentity(config *Config) (string, error) {
	if config == nil || (config.Mode != "closed" && config.Mode != "active") || len(config.Consumers) != 0 || len(config.Policy.Pools) != 1 || config.PoolExpansion != nil {
		return "", errors.New("standalone initialization identity requires unchanged build-only owner")
	}
	if _, ok := config.Policy.Pools["build"]; !ok {
		return "", errors.New("standalone initialization requires the build class")
	}
	copy := *config
	copy.Mode = "closed"
	data, err := json.Marshal(copy)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}
