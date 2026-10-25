package farmcapacity

import (
	"context"
	"errors"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
	"strings"
)

func (o *FrozenOwner) registrationAPI() (string, error) {
	target := o.RegistrationTarget
	if target == nil {
		target = &hostcapacity.RegistrationTarget{Scope: "org", Owner: o.Organization}
	}
	if target.Owner != o.Organization {
		return "", errors.New("registration target policy owner differs")
	}
	return target.API()
}

// RegistrationTarget returns retained ownership, not a fresh selection from
// mutable repository order. Old receipts migrate only as organization owners.
func (c *Controller) RegistrationTarget(ctx context.Context, name, id string) (*hostcapacity.RegistrationTarget, error) {
	owned, err := c.load(name)
	if err != nil {
		return nil, err
	}
	if owned.ID != id {
		return nil, errors.New("registration target owner changed")
	}
	if owned.RegistrationTarget != nil {
		target := *owned.RegistrationTarget
		if err := target.Validate(); err != nil {
			return nil, err
		}
		return &target, nil
	}
	if c.RegistrationPolicy == nil || c.RegistrationPolicy.EffectiveRegistrationScope() != "org" {
		return nil, errors.New("repository owner requires retained registration target")
	}
	target := &hostcapacity.RegistrationTarget{Scope: "org", Owner: c.RegistrationPolicy.Organization}
	item, err := c.Docker.Inspect(ctx, id)
	if err != nil {
		return nil, err
	}
	if item.RegistrationTarget != nil && *item.RegistrationTarget != *target {
		return nil, errors.New("legacy registration scope differs")
	}
	owned.RegistrationTarget = target
	if err := c.save(name, owned); err != nil {
		return nil, err
	}
	return target, nil
}
func registrationEnvironment(environment []string) (*hostcapacity.RegistrationTarget, error) {
	values := map[string]string{}
	for _, entry := range environment {
		key, value, ok := strings.Cut(entry, "=")
		if ok && (key == "RUNNER_SCOPE" || key == "ORG_NAME" || key == "REPO_URL") {
			if _, exists := values[key]; exists {
				return nil, errors.New("ambiguous registration target environment")
			}
			values[key] = value
		}
	}
	if len(values) == 0 {
		return nil, nil
	} // positively old organization image only
	target := hostcapacity.RegistrationTarget{Scope: values["RUNNER_SCOPE"]}
	if target.Scope == "org" {
		if values["REPO_URL"] != "" {
			return nil, errors.New("conflicting registration target")
		}
		target.Owner = values["ORG_NAME"]
	} else if target.Scope == "repo" {
		if values["ORG_NAME"] != "" {
			return nil, errors.New("conflicting registration target")
		}
		parts := strings.Split(strings.TrimPrefix(values["REPO_URL"], "https://github.com/"), "/")
		if len(parts) != 2 || !strings.HasPrefix(values["REPO_URL"], "https://github.com/") {
			return nil, errors.New("invalid repository registration URL")
		}
		target.Owner, target.Repository = parts[0], parts[1]
	}
	if err := target.Validate(); err != nil {
		return nil, err
	}
	return &target, nil
}

func RegistrationForTarget(ctx context.Context, id string, target hostcapacity.RegistrationTarget, name string) (int64, string, error) {
	return registration(ctx, id, target.Owner, name, false, target)
}
