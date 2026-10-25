package nativebackend

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"time"
)

type registrationPolicyRequest struct {
	Version                          int      `json:"version"`
	Epoch                            string   `json:"epoch"`
	ExpectedPolicySHA256             string   `json:"expectedPolicySHA256"`
	ExpectedRegistrationPolicySHA256 string   `json:"expectedRegistrationPolicySHA256"`
	SettingsSHA256                   string   `json:"settingsSHA256"`
	Scope                            string   `json:"scope"`
	Repositories                     []string `json:"repositories"`
}

func registrationPolicyIntent(owner, next hostcapacity.Config, policySHA, settingsSHA, privateSHA string) ([]byte, string, error) {
	request := registrationPolicyRequest{1, owner.Epoch, policySHA, privateSHA, settingsSHA, next.EffectiveRegistrationScope(), next.RegistrationRepositories}
	raw, err := json.Marshal(request)
	if err != nil {
		return nil, "", err
	}
	return raw, farmcapacity.RegistrationDigest(raw), nil
}
func readRegistrationPolicyEvidence(path string, owner uint32) ([]byte, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != owner || st.Nlink != 1 || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 65536 {
		return nil, errors.New("registration_policy_evidence_not_private")
	}
	raw, err := io.ReadAll(io.LimitReader(f, 65537))
	if err != nil || len(raw) > 65536 {
		return nil, errors.New("registration_policy_evidence_bound")
	}
	return raw, nil
}
func (s *Service) registrationMaterials(ctx context.Context) (*Engine, hostcapacity.Config, []byte, map[string]string, string, error) {
	var owner hostcapacity.Config
	e, ok := s.engine.(*Engine)
	if !ok {
		return nil, owner, nil, nil, "", errors.New("registration_policy_requires_native_engine")
	}
	raw, err := readRegistrationPolicyEvidence(hostcapacity.ConfigPath, 0)
	if err != nil {
		return e, owner, nil, nil, "", err
	}
	host, err := os.Hostname()
	if err != nil || json.Unmarshal(raw, &owner) != nil || owner.Validate(host) != nil {
		return e, owner, nil, nil, "", errors.New("registration_policy_invalid")
	}
	settingsRaw, err := e.Run(ctx, "native-config-json", nil, "")
	if err != nil {
		return e, owner, nil, nil, "", err
	}
	var settings map[string]string
	if json.Unmarshal([]byte(settingsRaw), &settings) != nil || settings["GH_OWNER"] != owner.Organization || e.BoundCache == "" || settings["CACHE_ROOT"] != e.BoundCache || owner.LedgerPath != filepath.Join(e.BoundCache, "native-capacity", "ledger.db") {
		return e, owner, nil, nil, "", errors.New("registration_policy_storage_or_owner_changed")
	}
	return e, owner, raw, settings, settingsRaw, nil
}
func (s *Service) registrationPolicyProposal() Response {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, owner, raw, settings, settingsRaw, err := s.registrationMaterials(ctx)
	if err != nil {
		return fail(err.Error())
	}
	current, privateSHA, err := farmcapacity.ReadRegistrationPolicy(farmcapacity.RegistrationPolicyPath, &owner)
	if err != nil {
		return fail("registration_private_policy_unavailable")
	}
	next := owner
	if bindRegistrationSettings(&next, settings) != nil {
		return fail("registration_settings_scope_invalid")
	}
	proposal, err := registrationPolicyProposalData(owner, next, current, privateSHA, raw, settingsRaw)
	if err != nil {
		return fail(err.Error())
	}
	result, _ := json.Marshal(proposal)
	return success(string(result))
}
func registrationPolicyProposalData(owner, next hostcapacity.Config, current *farmcapacity.PrivateRegistrationPolicy, privateSHA string, raw []byte, settingsRaw string) (map[string]any, error) {
	policySHA := farmcapacity.RegistrationDigest(raw)
	settingsSHA := farmcapacity.RegistrationDigest([]byte(settingsRaw))
	_, intentSHA, err := registrationPolicyIntent(owner, next, policySHA, settingsSHA, privateSHA)
	if err != nil {
		return nil, errors.New("registration_policy_proposal_failed")
	}
	currentScope := "org"
	var repositories []string
	bindingCurrent := true
	if current != nil {
		currentScope = current.Scope
		repositories = current.Repositories
		bindingCurrent = current.SharedPolicySHA256 == policySHA
	}
	changed := !bindingCurrent || currentScope != next.EffectiveRegistrationScope() || !reflect.DeepEqual(repositories, next.RegistrationRepositories)
	proposal := map[string]any{"schema": "farm-registration-policy-proposal/v1", "epoch": owner.Epoch, "owner": owner.Organization, "currentScope": currentScope, "currentRepositories": repositories, "requestedScope": next.EffectiveRegistrationScope(), "requestedRepositories": next.RegistrationRepositories, "expectedPolicySHA256": policySHA, "expectedSettingsSHA256": settingsSHA, "expectedRegistrationPolicySHA256": privateSHA, "intentSHA256": intentSHA, "idleProven": false, "consumerOwnerProofRequired": len(owner.Consumers) != 0, "sharedPolicyBindingCurrent": bindingCurrent, "changed": changed}
	return proposal, nil
}

func (s *Service) updateRegistrationPolicy(ctx context.Context, values map[string]string) (string, error) {
	if len(values) != 3 || len(values["expectedPolicySHA256"]) != 64 || len(values["expectedSettingsSHA256"]) != 64 {
		return "", errors.New("registration_policy_exact_three_pins_required")
	}
	e, owner, raw, settings, settingsRaw, err := s.registrationMaterials(ctx)
	if err != nil {
		return "", err
	}
	policySHA := farmcapacity.RegistrationDigest(raw)
	settingsSHA := farmcapacity.RegistrationDigest([]byte(settingsRaw))
	if policySHA != values["expectedPolicySHA256"] || settingsSHA != values["expectedSettingsSHA256"] {
		return "", errors.New("registration_policy_review_changed")
	}
	current, privateSHA, err := farmcapacity.ReadRegistrationPolicy(farmcapacity.RegistrationPolicyPath, &owner)
	if err != nil {
		return "", err
	}
	if privateSHA != values["expectedRegistrationPolicySHA256"] {
		return "", errors.New("registration_private_policy_review_changed")
	}
	next := owner
	if err = bindRegistrationSettings(&next, settings); err != nil {
		return "", err
	}
	if current != nil && current.SharedPolicySHA256 == policySHA && current.Scope == next.EffectiveRegistrationScope() && reflect.DeepEqual(current.Repositories, next.RegistrationRepositories) {
		return "", errors.New("registration_policy_already_current")
	}
	request, intentSHA, err := registrationPolicyIntent(owner, next, policySHA, settingsSHA, privateSHA)
	if err != nil {
		return "", err
	}
	path := filepath.Join(s.config, "registration-policy-"+intentSHA+".json")
	if err = publishExclusive(path, request); err != nil {
		return "", errors.New("registration_policy_intent_exists_inspect_before_retry")
	}
	if err = publishExclusive(path+".before.json", raw); err != nil {
		return "", err
	}
	beforePrivate := []byte("null\n")
	if current != nil {
		beforePrivate, err = readRegistrationPolicyEvidence(farmcapacity.RegistrationPolicyPath, 0)
		if err != nil {
			return "", err
		}
		if farmcapacity.RegistrationDigest(beforePrivate) != privateSHA {
			return "", errors.New("registration_private_policy_changed")
		}
	}
	if err = publishExclusive(path+".before-registration.json", beforePrivate); err != nil {
		return "", err
	}
	result, err := e.Run(ctx, "native-registration-policy-update", []string{owner.Epoch, path}, "")
	if err != nil {
		return "intentSHA256=" + intentSHA + "\n" + result, errors.New("registration_policy_update_uncertain_inspect_intent_and_policy")
	}
	return strings.TrimSpace(result), nil
}
func registrationPolicyObservation(intent, before, current, beforePrivate, currentPrivate []byte) (map[string]any, error) {
	var request registrationPolicyRequest
	if json.Unmarshal(intent, &request) != nil || request.Version != 1 {
		return nil, errors.New("registration_policy_intent_invalid")
	}
	if farmcapacity.RegistrationDigest(before) != request.ExpectedPolicySHA256 || farmcapacity.RegistrationDigest(current) != request.ExpectedPolicySHA256 {
		return nil, errors.New("registration_shared_policy_observation_drift")
	}
	var owner hostcapacity.Config
	if json.Unmarshal(before, &owner) != nil || owner.Epoch != request.Epoch || owner.Validate(owner.Host) != nil {
		return nil, errors.New("registration_policy_observation_invalid")
	}
	beforeSHA := farmcapacity.RegistrationPolicyAbsent
	if string(beforePrivate) != "null\n" {
		beforeSHA = farmcapacity.RegistrationDigest(beforePrivate)
	}
	if beforeSHA != request.ExpectedRegistrationPolicySHA256 {
		return nil, errors.New("registration_private_policy_before_changed")
	}
	currentSHA := farmcapacity.RegistrationPolicyAbsent
	if string(currentPrivate) != "null\n" {
		currentSHA = farmcapacity.RegistrationDigest(currentPrivate)
	}
	if currentSHA == beforeSHA {
		return map[string]any{"state": "inspect_required", "reason": "publication_not_observed", "replayAllowed": false}, nil
	}
	var actual farmcapacity.PrivateRegistrationPolicy
	if json.Unmarshal(currentPrivate, &actual) != nil || actual.Validate(&owner) != nil || actual.SharedPolicySHA256 != request.ExpectedPolicySHA256 || actual.SettingsSHA256 != request.SettingsSHA256 || actual.Scope != request.Scope || !reflect.DeepEqual(actual.Repositories, request.Repositories) {
		return nil, errors.New("registration_private_policy_observation_drift")
	}
	return map[string]any{"state": "applied_observed", "epoch": request.Epoch, "beforeSHA256": request.ExpectedPolicySHA256, "afterSHA256": request.ExpectedPolicySHA256, "beforeRegistrationPolicySHA256": beforeSHA, "afterRegistrationPolicySHA256": currentSHA, "settingsSHA256": request.SettingsSHA256, "replayAllowed": false, "runtimeQualificationProven": false}, nil
}
func (s *Service) observeRegistrationPolicy(identity string) Response {
	if len(identity) != 64 {
		return fail("registration_policy_intent_identity_required")
	}
	if _, err := hex.DecodeString(identity); err != nil {
		return fail("registration_policy_intent_identity_required")
	}
	path := filepath.Join(s.config, "registration-policy-"+identity+".json")
	intent, err := readRegistrationPolicyEvidence(path, 0)
	if err != nil || farmcapacity.RegistrationDigest(intent) != identity {
		return fail("registration_policy_intent_unavailable")
	}
	before, err := readRegistrationPolicyEvidence(path+".before.json", 0)
	if err != nil {
		return fail("registration_policy_before_unavailable")
	}
	current, err := readRegistrationPolicyEvidence(hostcapacity.ConfigPath, 0)
	if err != nil {
		return fail("registration_policy_current_unavailable")
	}
	beforePrivate, err := readRegistrationPolicyEvidence(path+".before-registration.json", 0)
	if err != nil {
		return fail("registration_private_policy_before_unavailable")
	}
	currentPrivate, err := readRegistrationPolicyEvidence(farmcapacity.RegistrationPolicyPath, 0)
	if errors.Is(err, os.ErrNotExist) {
		currentPrivate = []byte("null\n")
	} else if err != nil {
		return fail("registration_private_policy_current_unavailable")
	}
	result, err := registrationPolicyObservation(intent, before, current, beforePrivate, currentPrivate)
	if err != nil {
		return fail(err.Error())
	}
	raw, _ := json.Marshal(result)
	return success(string(raw))
}
