package hostcapacity

import (
	"github.com/unraid/ci-runner-farm/pkg/sharedcapacity"
	"testing"
)

func TestInitializationIdentitySurvivesOnlyActivation(t *testing.T) {
	original := Config{Epoch: "original", Mode: "closed", LedgerPath: "/original/ledger", ReceiptRoot: "/original/receipts", Policy: sharedcapacity.Policy{Pools: map[string]sharedcapacity.Pool{"build": {Maximum: 2}}}}
	expected, err := StandaloneInitializationIdentity(&original)
	if err != nil {
		t.Fatal(err)
	}
	active := original
	active.Mode = "active"
	same, err := StandaloneInitializationIdentity(&active)
	if err != nil || same != expected {
		t.Fatal("activation changed initialization identity")
	}
	for _, mutate := range []func(*Config){
		func(c *Config) { c.Epoch = "new" },
		func(c *Config) { c.LedgerPath = "/replacement/ledger" },
		func(c *Config) { c.TokenPath = "/different/token" },
		func(c *Config) { c.Policy.Pools = map[string]sharedcapacity.Pool{"build": {Maximum: 3}} },
		func(c *Config) { c.Consumers = map[string]Consumer{"qa": {Pools: []string{"qa"}}} },
	} {
		changed := original
		mutate(&changed)
		actual, err := StandaloneInitializationIdentity(&changed)
		if err == nil && actual == expected {
			t.Fatal("changed ownership retained recovery authority")
		}
	}
}
