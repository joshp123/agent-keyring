// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"fmt"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
)

func (p *proof) endRemoteLease(id string) {
	p.owner.status()
	if report := p.owner.leases[id]; len(report) == 0 || report[2] != "2" {
		p.owner.wait(func(e []string) bool { return e[0] == "LEASE" && e[1] == id && e[2] == "2" })
	}
	before := p.owner.authorizations
	p.stopRelay()
	p.owner.action("end", id)
	require(p.owner.leases[id][2] == "6", "End did not update the Mac immediately")
	p.owner.stop()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.status()
	require(p.owner.leases[id][2] == "6" && p.owner.leases[id][3] == "true", "restart lost queued End")
	p.startRelay()
	p.receiver.waitLease(id, pb.LeaseState_LEASE_STATE_REVOKED)
	p.owner.wait(func(e []string) bool { return e[0] == "LEASE" && e[1] == id && e[2] == "6" && e[3] == "false" })
	p.owner.status()
	require(p.owner.authorizations == before, "End requested another authorization")
	conn := p.receiver.open(request(&pb.WireRequest{Request: &pb.WireRequest_BeginOperation{BeginOperation: &pb.BeginOperationRequest{
		LeaseId: id, RequestId: "after-owner-ended", OperationDigest: relaycrypto.Hash([]byte("after-owner-ended")), Kind: pb.OperationKind_OPERATION_KIND_FILL,
		Fields: []pb.CredentialField{pb.CredentialField_CREDENTIAL_FIELD_PASSWORD},
	}}}))
	response := new(pb.RelayWireResponse)
	must(authority.ReadFrame(conn, response))
	conn.Close()
	require(response.GetError().GetCode() == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "ended remote lease did not refuse a valid new delivery")
	fmt.Println("PASS live remote lease list and End: offline queue and Mac restart, no touch, relay revocation stops delivery")
}
