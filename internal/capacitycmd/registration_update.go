package capacitycmd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"

	"github.com/unraid/ci-runner-farm/internal/localchecks"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"golang.org/x/sys/unix"
)

type registrationUpdate struct {
	Version                          int      `json:"version"`
	Epoch                            string   `json:"epoch"`
	ExpectedRegistrationPolicySHA256 string   `json:"expectedRegistrationPolicySHA256"`
	ExpectedPolicySHA256             string   `json:"expectedPolicySHA256"`
	SettingsSHA256                   string   `json:"settingsSHA256"`
	Scope                            string   `json:"scope"`
	Repositories                     []string `json:"repositories"`
}

func updateRegistration(ctx context.Context, lease *hostcapacity.Lease, epoch, path string, input io.Reader, output io.Writer) error {
	if lease.Config.Epoch != epoch {
		return errors.New("registration policy epoch changed")
	}
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != 0 || st.Nlink != 1 || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 32768 {
		return errors.New("registration update request is not private bounded file")
	}
	var request registrationUpdate
	decoder := json.NewDecoder(io.LimitReader(file, 32769))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&request); err != nil {
		return err
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return errors.New("registration update trailing request")
	}
	if request.Version != 1 || request.Epoch != epoch || len(request.ExpectedPolicySHA256) != 64 || len(request.SettingsSHA256) != 64 {
		return errors.New("registration update identity invalid")
	}
	settingsRaw, err := io.ReadAll(io.LimitReader(input, 1024*1024+1))
	if err != nil || len(settingsRaw) > 1024*1024 {
		return errors.New("registration update settings bound")
	}
	settingsSum := sha256.Sum256(settingsRaw)
	if hex.EncodeToString(settingsSum[:]) != request.SettingsSHA256 {
		return errors.New("registration update settings CAS changed")
	}
	var settings map[string]string
	if json.NewDecoder(bytes.NewReader(settingsRaw)).Decode(&settings) != nil || settings["GH_OWNER"] != lease.Config.Organization {
		return errors.New("registration update settings owner changed")
	}
	scope := settings["GH_SCOPE"]
	if scope == "" {
		scope = "org"
	}
	var repositories []string
	if scope == "repo" {
		repositories = strings.Fields(settings["GH_REPOS"])
	}
	if scope != request.Scope || !reflect.DeepEqual(repositories, request.Repositories) {
		return errors.New("registration update settings scope changed")
	}
	terminalPath := path + ".terminal.json"
	if _, err = os.Lstat(terminalPath); !errors.Is(err, os.ErrNotExist) {
		return errors.New("registration update terminal exists; observe before retry")
	}
	if len(lease.Config.Consumers) != 0 {
		return errors.New("registration update requires explicit consumer owner idle proof")
	}
	c := farmcapacity.Controller{Broker: sharedcapacity.Broker{Path: lease.Config.LedgerPath}, Policy: lease.Config.Policy, ReceiptRoot: lease.Config.ReceiptRoot, Docker: farmcapacity.NativeDocker{}}
	idle := func() error {
		snapshot, err := c.Broker.Status(&c.Policy)
		if err != nil {
			return err
		}
		if len(snapshot.Grants) != 0 || len(snapshot.Pending) != 0 || len(snapshot.Starts) != 0 {
			return errors.New("registration update capacity owners are not idle")
		}
		inventory, err := c.Inventory(ctx)
		if err != nil {
			return err
		}
		if len(inventory) != 0 {
			return errors.New("registration update managed containers remain")
		}
		return localchecks.NewBuildRoleOwner(lease.Config).VerifyReleasedIntents(ctx)
	}
	private := farmcapacity.PrivateRegistrationPolicy{Version: 1, Host: lease.Config.Host, Epoch: epoch, Owner: lease.Config.Organization, SharedPolicySHA256: request.ExpectedPolicySHA256, SettingsSHA256: request.SettingsSHA256, Scope: request.Scope, Repositories: request.Repositories}
	if err = lease.WithRegistrationPolicyCAS(request.ExpectedPolicySHA256, idle, func() error {
		return farmcapacity.PublishRegistrationPolicy(farmcapacity.RegistrationPolicyPath, request.ExpectedRegistrationPolicySHA256, private, lease.Config)
	}); err != nil {
		return err
	}
	_, afterPrivate, err := farmcapacity.ReadRegistrationPolicy(farmcapacity.RegistrationPolicyPath, lease.Config)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(hostcapacity.ConfigPath)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(raw)
	if hex.EncodeToString(sum[:]) != request.ExpectedPolicySHA256 {
		return errors.New("shared policy changed after private publication")
	}
	data, err := json.Marshal(map[string]any{"version": 1, "epoch": epoch, "beforeRegistrationPolicySHA256": request.ExpectedRegistrationPolicySHA256, "afterRegistrationPolicySHA256": afterPrivate, "beforeSHA256": request.ExpectedPolicySHA256, "afterSHA256": hex.EncodeToString(sum[:]), "settingsSHA256": request.SettingsSHA256, "scope": request.Scope, "repositories": request.Repositories, "status": "applied"})
	if err != nil {
		return err
	}
	result, err := os.OpenFile(terminalPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer result.Close()
	if _, err = result.Write(data); err != nil {
		return err
	}
	if err = result.Sync(); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	if err = dir.Sync(); err != nil {
		return err
	}
	_, err = output.Write(append(data, '\n'))
	return err
}
