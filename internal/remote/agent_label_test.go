package remote

import (
	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"testing"
)

func TestScopeRejectsChangedAgentLabel(t *testing.T) {
	request := &pb.RequestLeaseRequest{LoginId: "login", TaskRef: "task", AgentLabel: "Codex"}
	record := &pb.RequestRecord{LoginId: "login", TaskRef: "task", AgentLabel: "Codex"}
	if !scopeMatches(request, record) {
		t.Fatal("matching label rejected")
	}
	record.AgentLabel = "Claude Code"
	if scopeMatches(request, record) {
		t.Fatal("substituted agent label accepted")
	}
}
