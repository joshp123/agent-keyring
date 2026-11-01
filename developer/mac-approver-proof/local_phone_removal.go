// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"bytes"
	"path/filepath"
	"strings"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
)

func (p *proof) localPhoneApprovedLease(phone *phoneProcess, task string) string {
	output, err := p.localCLICommand("lease", loginID, "--task", task, "--reason", "Synthetic local phone removal proof", "--for", "agent-process", "--no-wait").Output()
	must(err)
	id := strings.TrimSpace(string(output))
	work := p.owner.wait(func(event []string) bool { return event[0] == "LOCAL" && event[1] == id && event[3] == "1" })
	phone.wait("requests", work[4]+"=waitingForYou")
	phone.action("approve\t" + work[4])
	lease := waitLocalLease(authority.Client{Socket: filepath.Join(p.root, "agent.sock")}, id, pb.LeaseState_LEASE_STATE_ACTIVE)
	require(lease.ApprovedBy == pb.ApprovedBy_APPROVED_BY_IPHONE, "local lease was not phone approved")
	return id
}

func (p *proof) checkLocalFields(id string, allowed bool) {
	for _, field := range []string{"password", "one-time-code"} {
		var output, diagnostic bytes.Buffer
		command := p.localCLICommand("read", id, "--field", field)
		command.Stdout, command.Stderr = &output, &diagnostic
		err := command.Run()
		if allowed {
			require(err == nil, "local CLI refused trusted phone approval: "+diagnostic.String())
			if field == "password" {
				require(output.String() == "example-password", "unexpected dummy password")
			} else {
				require(output.Len() == 6, "missing dummy TOTP")
			}
		} else {
			require(err != nil && output.Len() == 0 && strings.Contains(diagnostic.String(), "not active"), "local CLI delivered after approving phone removal")
		}
		clear(output.Bytes())
	}
}
