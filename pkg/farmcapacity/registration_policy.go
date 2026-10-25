package farmcapacity

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

const RegistrationPolicyAbsent = "absent"
const RegistrationPolicyPath = "/boot/config/plugins/ci-runner-farm/farm-registration-policy.json"

type PrivateRegistrationPolicy struct {
	Version            int      `json:"version"`
	Host               string   `json:"host"`
	Epoch              string   `json:"epoch"`
	Owner              string   `json:"owner"`
	SharedPolicySHA256 string   `json:"sharedPolicySHA256"`
	SettingsSHA256     string   `json:"settingsSHA256"`
	Scope              string   `json:"scope"`
	Repositories       []string `json:"repositories"`
}

func (p PrivateRegistrationPolicy) Validate(c *hostcapacity.Config) error {
	if c == nil || p.Version != 1 || (p.Scope != "org" && p.Scope != "repo") || p.Host != c.Host || p.Epoch != c.Epoch || p.Owner != c.Organization || len(p.SharedPolicySHA256) != 64 || len(p.SettingsSHA256) != 64 {
		return errors.New("Farm registration policy ownership differs")
	}
	if _, err := hex.DecodeString(p.SharedPolicySHA256); err != nil {
		return err
	}
	if _, err := hex.DecodeString(p.SettingsSHA256); err != nil {
		return err
	}
	copy := *c
	p.Apply(&copy)
	return copy.ValidateRegistrationPolicy()
}
func (p PrivateRegistrationPolicy) Apply(c *hostcapacity.Config) {
	c.RegistrationScope = p.Scope
	c.RegistrationRepositories = append([]string(nil), p.Repositories...)
}
func RegistrationDigest(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}
func ReadRegistrationPolicy(path string, c *hostcapacity.Config) (*PrivateRegistrationPolicy, string, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil, RegistrationPolicyAbsent, nil
	}
	if err != nil {
		return nil, "", err
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, "", err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != uint32(os.Geteuid()) || st.Nlink != 1 || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 65536 {
		return nil, "", errors.New("private Farm registration policy is unsafe")
	}
	raw, err := io.ReadAll(io.LimitReader(f, 65537))
	if err != nil || len(raw) > 65536 {
		return nil, "", errors.New("private Farm registration policy bound")
	}
	var p PrivateRegistrationPolicy
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&p); err != nil {
		return nil, "", err
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return nil, "", errors.New("private registration policy trailing data")
	}
	if err = p.Validate(c); err != nil {
		return nil, "", err
	}
	return &p, RegistrationDigest(raw), nil
}
func LoadRegistrationAuthority(path string, c *hostcapacity.Config, sharedRaw []byte) error {
	p, _, err := ReadRegistrationPolicy(path, c)
	if err != nil {
		return err
	}
	if p == nil {
		c.RegistrationScope = ""
		c.RegistrationRepositories = nil
		return nil
	}
	if p.SharedPolicySHA256 != RegistrationDigest(sharedRaw) {
		return errors.New("private Farm registration policy shared binding changed")
	}
	p.Apply(c)
	return nil
}
func PublishRegistrationPolicy(path, expected string, p PrivateRegistrationPolicy, c *hostcapacity.Config) error {
	if err := p.Validate(c); err != nil {
		return err
	}
	_, digest, err := ReadRegistrationPolicy(path, c)
	if err != nil {
		return err
	}
	if digest != expected {
		return errors.New("private Farm registration policy CAS changed")
	}
	parent := filepath.Dir(path)
	info, err := os.Lstat(parent)
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != uint32(os.Geteuid()) || !info.IsDir() || info.Mode().Perm()&0022 != 0 {
		return errors.New("private Farm registration policy parent unsafe")
	}
	file, err := os.CreateTemp(parent, ".farm-registration-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err = file.Chmod(0600); err != nil {
		return err
	}
	if err = json.NewEncoder(file).Encode(p); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	_, digest, err = ReadRegistrationPolicy(path, c)
	if err != nil || digest != expected {
		return errors.New("private Farm registration policy changed before publication")
	}
	if err = os.Rename(file.Name(), path); err != nil {
		return err
	}
	dir, err := os.Open(parent)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
