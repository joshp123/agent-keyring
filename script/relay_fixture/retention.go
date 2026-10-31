// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

func (p *proof) database() *sql.DB {
	db, err := sql.Open("sqlite", filepath.Join(p.directory, "relay", "relay.sqlite"))
	must(err)
	db.SetMaxOpenConns(1)
	return db
}
func (p *proof) retentionProof() {
	p.publishIndex(pb.AccessRule_ACCESS_RULE_ASK)
	lease := good(p.client.call(leaseRequest("retained-request", "retained-task", p.enrolled.RecipientId))).GetClient().GetLease()
	raw := p.nextRequest()
	good(p.client.call(leaseRequest("retained-alias", "retained-task", p.enrolled.RecipientId)))
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: lease.LeaseId, Record: raw}}}))
	decision := p.decision(raw, false)
	good(p.approver.call(decision))
	ended := good(p.client.call(endRequest(lease.LeaseId))).GetClient().GetLease()
	db := p.database()
	var retainedUntil int64
	var upload []byte
	var payloads, operations int
	must(db.QueryRow("SELECT delete_after,decision FROM leases WHERE id=? AND bundle IS NULL", lease.LeaseId).Scan(&retainedUntil, &upload))
	require(retainedUntil == ended.EndedAtUnixSeconds+7*24*60*60, "ended lease retention is not seven days")
	stored := new(pb.SignedDecision)
	must(proto.Unmarshal(upload, stored))
	require(stored.Bundle == nil && stored.PhoneDecision == nil, "ended lease retained a delivery payload or phone answer")
	must(db.QueryRow("SELECT count(*) FROM phone_escalations WHERE lease=?", lease.LeaseId).Scan(&payloads))
	require(payloads == 0, "ended lease retained escalation")
	must(db.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='operations'").Scan(&operations))
	require(operations == 0, "relay still stores operations")
	db.Close()
	// Age only this isolated fixture's persisted timestamps. No production clock
	// or retention override exists. The restart must schedule these actual rows.
	p.work.Close()
	p.stop()
	db = p.database()
	agedDeadline := time.Now().Unix() + 2
	_, err := db.Exec("UPDATE leases SET delete_after=? WHERE id=?", agedDeadline, lease.LeaseId)
	must(err)
	db.Close()
	p.start()
	p.work = p.watchWork()
	// Keep watchers connected without any traffic before checking timer-driven cleanup.
	time.Sleep(time.Until(time.Unix(agedDeadline, 0)) + 200*time.Millisecond)
	missing := p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: lease.LeaseId}}}))
	require(missing.GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_NOT_FOUND, "aged lease was not removed by deadline timer")
	db = p.database()
	var aliases int
	must(db.QueryRow("SELECT count(*) FROM aliases WHERE lease=?", lease.LeaseId).Scan(&aliases))
	db.Close()
	require(aliases == 0, "lease aliases survived retention deadline")
	fmt.Println("PASS immediate delivery/answer/escalation deletion; seven-day history and aliases expire from one timer after restart; no operation table")
}
func (p *proof) dismissEnrolmentProof() {
	candidate := wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "dismissed-receiver")), pin: p.approver.pin}
	spki, err := relaycrypto.CertificateSPKI(candidate.certificate)
	must(err)
	receiver := signingKey()
	request := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_Enrol{Enrol: &pb.EnrolRequest{MachineLabel: "Dismissed machine", ClientLabel: "Dummy", TlsPublicKey: spki, ReceiverPublicKey: public(receiver)}}}
	stream := candidate.open(request)
	defer stream.Close()
	pending := good(receive(stream)).GetEnrolStatus()
	dismiss := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_DismissEnrolment{DismissEnrolment: &pb.DismissEnrolmentRequest{RecipientId: pending.RecipientId}}}
	require(candidate.call(dismiss).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "pending receiver dismissed enrolment")
	good(p.approver.call(dismiss))
	good(p.approver.call(dismiss))
	require(good(receive(stream)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_DENIED, "dismissal did not finish enrolment stream")
	require(candidate.call(find()).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "dismissed receiver became enrolled")
	fmt.Println("PASS approver-only unsigned DismissEnrolment, idempotent and grants no access")
}

func (p *proof) setupExpiryProof() {
	candidate := wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "expired-receiver")), pin: p.approver.pin}
	spki, err := relaycrypto.CertificateSPKI(candidate.certificate)
	must(err)
	enrol := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_Enrol{Enrol: &pb.EnrolRequest{MachineLabel: "Expired machine", ClientLabel: "Dummy", TlsPublicKey: spki, ReceiverPublicKey: public(signingKey())}}}
	pending := candidate.open(enrol)
	status := good(receive(pending)).GetEnrolStatus()
	pending.Close()
	next := wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "expired-approver")), pin: p.approver.pin}
	nextSPKI, err := relaycrypto.CertificateSPKI(next.certificate)
	must(err)
	key := &pb.ApproverKey{KeyId: "expired-approver", Label: "Expired approver", PublicKey: public(signingKey()), TlsPublicKey: nextSPKI, Role: pb.ApproverRole_APPROVER_ROLE_MAC}
	pair := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: &pb.PairApproverRequest{Key: key, TlsPublicKey: nextSPKI}}}
	pairing := next.open(pair)
	good(receive(pairing))
	pairing.Close()
	p.work.Close()
	p.stop()
	db := p.database()
	var enrolExpiry, pairExpiry, created int64
	must(db.QueryRow("SELECT expires FROM enrolments WHERE id=?", status.RecipientId).Scan(&enrolExpiry))
	var record []byte
	must(db.QueryRow("SELECT record FROM enrolments WHERE id=?", status.RecipientId).Scan(&record))
	enrolled := new(pb.EnrolmentRecord)
	must(proto.Unmarshal(record, enrolled))
	must(db.QueryRow("SELECT created,expires FROM pairings WHERE id=?", key.KeyId).Scan(&created, &pairExpiry))
	require(enrolExpiry == enrolled.CreatedUnixSeconds+600 && pairExpiry == created+600, "setup retention is not ten minutes")
	aged := time.Now().Unix() + 2
	_, err = db.Exec("UPDATE enrolments SET expires=? WHERE id=?", aged, status.RecipientId)
	must(err)
	_, err = db.Exec("UPDATE pairings SET expires=? WHERE id=?", aged, key.KeyId)
	must(err)
	db.Close()
	p.start()
	p.work = p.watchWork()
	pending = candidate.open(enrol)
	defer pending.Close()
	require(good(receive(pending)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_PENDING, "setup rejoin lost pending state")
	pairing = next.open(pair)
	defer pairing.Close()
	good(receive(pairing))
	require(good(receive(pending)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_EXPIRED, "enrolment timer did not finish expired stream")
	require(good(receive(pairing)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_EXPIRED, "pairing timer did not finish expired stream")
	db = p.database()
	var count int
	must(db.QueryRow("SELECT (SELECT count(*) FROM enrolments WHERE id=?)+(SELECT count(*) FROM pairings WHERE id=?)", status.RecipientId, key.KeyId).Scan(&count))
	db.Close()
	require(count == 0, "expired setup records retained")
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}})).GetConfiguration() != nil, "setup cleanup removed pinned approver identity")
	fmt.Println("PASS ten-minute enrolment/pairing retention; restarted timer expires connected setup streams and deletes rows while preserving pinned approvers")
}
