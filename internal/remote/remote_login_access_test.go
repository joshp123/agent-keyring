// Written by AI on 2026.11.23 by model claude opus 5.5.
package remote

import (
	"testing"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
)

// Josh blocks a password, then unblocks it before copying from Passwords
// again: an agent can neither ask for it nor use an approval given before.
func TestABlockedOrDeletedPasswordCannotBeAskedForOrUsed(t *testing.T) {
	cases := map[string]struct {
		login  *pb.Login
		usable bool
	}{
		"not listed":                {nil, false},
		"blocked":                   {&pb.Login{LoginId: "bank", Rule: pb.Rule_RULE_BLOCKED, Version: 5}, false},
		"blocked, deleted":          {&pb.Login{LoginId: "bank", Rule: pb.Rule_RULE_BLOCKED}, false},
		"unblocked, not yet copied": {&pb.Login{LoginId: "bank", Rule: pb.Rule_RULE_ASK}, false},
		"ask":                       {&pb.Login{LoginId: "bank", Rule: pb.Rule_RULE_ASK, Version: 5}, true},
		"automatic":                 {&pb.Login{LoginId: "bank", Rule: pb.Rule_RULE_AUTOMATIC, Version: 5}, true},
	}
	for name, c := range cases {
		if err := loginAccessPolicyError(c.login); (err == nil) != c.usable {
			t.Errorf("%s: unusable() = %v, want usable %v", name, err, c.usable)
		}
	}
}
