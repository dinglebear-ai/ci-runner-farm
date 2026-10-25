package hostcapacity

import (
	"errors"
	"net/url"
	"slices"
)

// RegistrationTarget is public immutable ownership, not a credential. Repository
// is the repository name; Owner always names its exact GitHub owner.
type RegistrationTarget struct {
	Scope      string `json:"scope"`
	Owner      string `json:"owner"`
	Repository string `json:"repository,omitempty"`
}

func (t RegistrationTarget) Validate() error {
	if !organizationPattern.MatchString(t.Owner) || (t.Scope != "org" && t.Scope != "repo") || (t.Scope == "org" && t.Repository != "") || (t.Scope == "repo" && !repositoryNamePattern.MatchString(t.Repository)) {
		return errors.New("invalid registration target")
	}
	return nil
}
func (t RegistrationTarget) URL() string {
	if t.Scope == "repo" {
		return "https://github.com/" + t.Owner + "/" + t.Repository
	}
	return "https://github.com/" + t.Owner
}
func (t RegistrationTarget) API() (string, error) {
	if err := t.Validate(); err != nil {
		return "", err
	}
	if t.Scope == "repo" {
		return "https://api.github.com/repos/" + url.PathEscape(t.Owner) + "/" + url.PathEscape(t.Repository) + "/actions/runners", nil
	}
	return "https://api.github.com/orgs/" + url.PathEscape(t.Owner) + "/actions/runners", nil
}
func (c *Config) EffectiveRegistrationScope() string {
	if c.RegistrationScope == "" {
		return "org"
	}
	return c.RegistrationScope
}
func (c *Config) ValidateRegistrationPolicy() error {
	scope := c.EffectiveRegistrationScope()
	if scope != "org" && scope != "repo" {
		return errors.New("invalid registration scope")
	}
	if scope == "org" && len(c.RegistrationRepositories) != 0 {
		return errors.New("organization registration cannot contain repository targets")
	}
	if scope == "repo" && (len(c.RegistrationRepositories) == 0 || len(c.RegistrationRepositories) > 256) {
		return errors.New("repository registration requires bounded allowlist")
	}
	seen := map[string]bool{}
	for _, repo := range c.RegistrationRepositories {
		prefix := c.Organization + "/"
		if len(repo) <= len(prefix) || repo[:len(prefix)] != prefix || !repositoryNamePattern.MatchString(repo[len(prefix):]) || seen[repo] {
			return errors.New("invalid registration repository allowlist")
		}
		seen[repo] = true
	}
	return nil
}
func (c *Config) AllowsRegistration(t RegistrationTarget) bool {
	return c.ValidateRegistrationPolicy() == nil && t.Validate() == nil && t.Owner == c.Organization && t.Scope == c.EffectiveRegistrationScope() && (t.Scope == "org" || slices.Contains(c.RegistrationRepositories, t.Owner+"/"+t.Repository))
}
