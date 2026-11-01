// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relay

import (
	"bytes"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func verifyApprover(tx *sql.Tx, id string, statement, signature []byte, owner bool) error {
	_, keys, err := currentKeys(tx)
	if err != nil {
		return err
	}
	key := keyByID(keys, id)
	if key == nil || relaycrypto.Role(keys, key) != pb.ApproverRole_APPROVER_ROLE_MAC || (owner && keys.RuleOwnerKeyId != id) {
		return denied("Signer is not a current authorized approver.")
	}
	if relaycrypto.Verify(key.PublicKey, statement, signature) != nil {
		return denied("Invalid approver signature.")
	}
	return nil
}
func (s *Server) approver(tx *sql.Tx, p peer, r *pb.RelayWireRequest, seen map[string][]byte) (*pb.RelayWireResponse, bool, error) {
	_, keys, err := currentKeys(tx)
	if err != nil {
		return nil, false, err
	}
	role := relaycrypto.Role(keys, keyByID(keys, p.approver))
	if role == pb.ApproverRole_APPROVER_ROLE_PHONE {
		switch r.Request.(type) {
		case *pb.RelayWireRequest_WatchWork, *pb.RelayWireRequest_RegisterPush, *pb.RelayWireRequest_AnswerFromPhone, *pb.RelayWireRequest_RevokeLease, *pb.RelayWireRequest_ClearDenial, *pb.RelayWireRequest_GetCopyUpdate, *pb.RelayWireRequest_Decide:
		default:
			return nil, false, denied("This method requires a Mac approver.")
		}
	}
	switch request := r.Request.(type) {
	case *pb.RelayWireRequest_WatchWork:
		if request.WatchWork.ApproverKeyId != p.approver {
			return nil, false, denied("Watcher must name its pinned approver key.")
		}
		return s.work(tx, p, seen)
	case *pb.RelayWireRequest_Decide:
		result, err := s.decide(tx, p, request.Decide)
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Decision{Decision: result}, EndOfStream: true}, false, err
	case *pb.RelayWireRequest_PublishConfiguration:
		err := s.publishConfiguration(tx, request.PublishConfiguration)
		return publishAck(), false, err
	case *pb.RelayWireRequest_PublishCopyUpdate:
		err := s.publishCopyUpdate(tx, request.PublishCopyUpdate)
		return publishAck(), false, err
	case *pb.RelayWireRequest_GetCopyUpdate:
		value, err := phoneCopy(tx, p)
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_CopyUpdate{CopyUpdate: value}, EndOfStream: true}, false, err
	case *pb.RelayWireRequest_DismissEnrolment:
		result, err := tx.Exec("UPDATE enrolments SET state=2 WHERE id=? AND state=0", request.DismissEnrolment.RecipientId)
		if err == nil {
			count, e := result.RowsAffected()
			err = e
			if count == 0 {
				var state int
				if tx.QueryRow("SELECT state FROM enrolments WHERE id=?", request.DismissEnrolment.RecipientId).Scan(&state) != nil || state != 2 {
					err = missing("No pending enrolment to dismiss.")
				}
			}
		}
		return publishAck(), false, err
	case *pb.RelayWireRequest_ClearDenial:
		err := s.clearDenial(tx, request.ClearDenial)
		if err == nil {
			err = queueLocalClear(tx, request.ClearDenial)
		}
		return publishAck(), false, err
	case *pb.RelayWireRequest_RevokeLease:
		if lease, err := revokeLocal(tx, request.RevokeLease.LeaseId); err != nil || lease != nil {
			return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Lease{Lease: lease}, EndOfStream: true}, false, err
		}
		lease, _, err := loadLease(tx, request.RevokeLease.LeaseId)
		if err == nil && !terminal(lease) {
			end(lease, pb.LeaseState_LEASE_STATE_REVOKED)
			err = saveLease(tx, lease)
		}
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Lease{Lease: lease}, EndOfStream: true}, false, err
	case *pb.RelayWireRequest_PublishApproverKeys:
		err := s.publishKeys(tx, request.PublishApproverKeys)
		return publishAck(), false, err
	case *pb.RelayWireRequest_RegisterPush:
		err := registerPush(tx, p, request.RegisterPush)
		return publishAck(), false, err
	case *pb.RelayWireRequest_EscalateToPhone:
		err := escalate(tx, p, request.EscalateToPhone)
		return publishAck(), false, err
	case *pb.RelayWireRequest_AnswerFromPhone:
		ack, err := answerPhone(tx, p, request.AnswerFromPhone)
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Decision{Decision: ack}, EndOfStream: true}, false, err
	case *pb.RelayWireRequest_UpdateLocalPhoneLease:
		ack, err := updateLocalPhoneLease(tx, p, request.UpdateLocalPhoneLease)
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Decision{Decision: ack}, EndOfStream: true}, false, err
	default:
		return nil, false, invalid("Select a supported relay method.")
	}
}
func (s *Server) clearDenial(tx *sql.Tx, request *pb.ClearDenialRequest) error {
	if request.RecipientId == "" || request.LoginId == "" {
		return invalid("Recipient and login are required.")
	}
	leases, err := queryLeases(tx, "SELECT lease FROM leases WHERE recipient=?", request.RecipientId)
	if err != nil {
		return err
	}
	for _, lease := range leases {
		if lease.State == pb.LeaseState_LEASE_STATE_DENIED && lease.GetRecipient().GetRecipientId() == request.RecipientId && lease.LoginId == request.LoginId && lease.RetryNotBeforeUnixSeconds != 0 {
			lease.RetryNotBeforeUnixSeconds = 0
			if err := saveLease(tx, lease); err != nil {
				return err
			}
		}
	}
	return nil
}
func workResponse(work *pb.ApproverWork) *pb.RelayWireResponse {
	return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Work{Work: work}}
}
func (s *Server) work(tx *sql.Tx, p peer, seen map[string][]byte) (*pb.RelayWireResponse, bool, error) {
	if next, err := phoneWork(tx, p, seen); err != nil || next != nil {
		return next, true, err
	}
	_, keys, err := currentKeys(tx)
	if err != nil {
		return nil, false, err
	}
	if relaycrypto.Role(keys, keyByID(keys, p.approver)) == pb.ApproverRole_APPROVER_ROLE_PHONE {
		if len(keyByID(keys, p.approver).EncryptionPublicKey) > 0 {
			copy, e := phoneCopy(tx, p)
			if e == nil && changed(seen, "copy", copy) {
				return workResponse(&pb.ApproverWork{Item: &pb.ApproverWork_CopyUpdate{CopyUpdate: copy}}), true, nil
			}
			if e != nil {
				var rpc *rpcError
				if !errors.As(e, &rpc) || rpc.code != pb.RpcErrorCode_RPC_ERROR_CODE_NOT_FOUND {
					return nil, false, e
				}
			}
		}
		leases, err := allLeases(tx)
		if err != nil {
			return nil, false, err
		}
		for _, lease := range leases {
			_, raw, err := loadLease(tx, lease.LeaseId)
			if err != nil {
				return nil, false, err
			}
			digest := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", raw))
			requestKey := "request:" + digest
			if lease.State != pb.LeaseState_LEASE_STATE_PENDING && bytes.Equal(seen[requestKey], []byte{1}) {
				seen[requestKey] = []byte{2}
				return workResponse(&pb.ApproverWork{Item: &pb.ApproverWork_CancelledRequestDigestHex{CancelledRequestDigestHex: digest}}), true, nil
			}
			if lease.State != pb.LeaseState_LEASE_STATE_PENDING && changed(seen, "lease:"+lease.LeaseId, lease) {
				return workResponse(&pb.ApproverWork{Item: &pb.ApproverWork_Lease{Lease: lease}}), true, nil
			}
		}
		return nil, true, nil
	}
	rows, err := tx.Query("SELECT request,lease FROM leases ORDER BY rowid")
	if err != nil {
		return nil, false, err
	}
	var next *pb.ApproverWork
	for rows.Next() {
		var record, data []byte
		if err = rows.Scan(&record, &data); err != nil {
			break
		}
		l := new(pb.Lease)
		if err = proto.Unmarshal(data, l); err != nil {
			break
		}
		digest := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", record))
		key := "request:" + digest
		if l.State == pb.LeaseState_LEASE_STATE_PENDING && seen[key] == nil {
			seen[key] = []byte{1}
			next = &pb.ApproverWork{Item: &pb.ApproverWork_Request{Request: &pb.PendingRequest{Record: record}}}
			break
		}
		if l.State != pb.LeaseState_LEASE_STATE_PENDING && bytes.Equal(seen[key], []byte{1}) {
			seen[key] = []byte{2}
			next = &pb.ApproverWork{Item: &pb.ApproverWork_CancelledRequestDigestHex{CancelledRequestDigestHex: digest}}
			break
		}
		leaseKey := "lease:" + l.LeaseId
		if (!terminal(l) || seen[leaseKey] != nil) && changed(seen, leaseKey, l) {
			next = &pb.ApproverWork{Item: &pb.ApproverWork_Lease{Lease: l}}
			break
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, false, err
	}
	if next != nil {
		return workResponse(next), true, nil
	}
	signed, _, err := currentKeys(tx)
	if err != nil {
		return nil, false, err
	}
	rows, err = tx.Query("SELECT record,keyset FROM enrolments WHERE state=0 ORDER BY rowid")
	if err != nil {
		return nil, false, err
	}
	for rows.Next() {
		var record, compared []byte
		if err = rows.Scan(&record, &compared); err != nil {
			break
		}
		enrol := new(pb.EnrolmentRecord)
		set := new(pb.SignedApproverKeySet)
		if err = proto.Unmarshal(record, enrol); err != nil {
			break
		}
		if err = proto.Unmarshal(compared, set); err != nil {
			break
		}
		if time.Now().Unix() < enrol.CreatedUnixSeconds+600 && bytes.Equal(set.KeySet, signed.KeySet) && changed(seen, "enrol:"+enrol.RecipientId, enrol) {
			next = &pb.ApproverWork{Item: &pb.ApproverWork_Enrolment{Enrolment: &pb.PendingEnrolment{Record: record}}}
			break
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, false, err
	}
	if next != nil {
		return workResponse(next), true, nil
	}
	rows, err = tx.Query("SELECT request,keyset,created FROM pairings WHERE expires IS NOT NULL ORDER BY rowid")
	if err != nil {
		return nil, false, err
	}
	for rows.Next() {
		var data, compared []byte
		var created int64
		if err = rows.Scan(&data, &compared, &created); err != nil {
			break
		}
		pair := new(pb.PairApproverRequest)
		if err = proto.Unmarshal(data, pair); err != nil {
			break
		}
		if time.Now().Unix() < created+600 && bytes.Equal(compared, signed.KeySet) && changed(seen, "pair:"+pair.Key.KeyId, pair) {
			next = &pb.ApproverWork{Item: &pb.ApproverWork_Pairing{Pairing: pair}}
			break
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, false, err
	}
	if next != nil {
		return workResponse(next), true, nil
	}
	return nil, true, nil
}
func (s *Server) decide(tx *sql.Tx, p peer, r *pb.SignedDecision) (*pb.DecisionAck, error) {
	if r == nil {
		return nil, invalid("Missing decision.")
	}
	statement := new(pb.DecisionStatement)
	if proto.Unmarshal(r.Statement, statement) != nil || statement.Domain != "agentkeyring.decision.v1" {
		return nil, invalid("Invalid decision statement.")
	}
	l, record, err := loadLease(tx, statement.LeaseId)
	if err != nil {
		return nil, err
	}
	var accepted []byte
	if err = tx.QueryRow("SELECT decision_hash FROM leases WHERE id=?", l.LeaseId).Scan(&accepted); err != nil {
		return nil, err
	}
	if len(accepted) > 0 {
		return &pb.DecisionAck{Accepted: bytes.Equal(accepted, relaycrypto.Hash(marshal(r))), Lease: l, Detail: "The request already has a decision."}, nil
	}
	if terminal(l) || l.State != pb.LeaseState_LEASE_STATE_PENDING {
		return &pb.DecisionAck{Lease: l, Detail: "The request is no longer pending."}, nil
	}
	if !bytes.Equal(statement.RequestDigest, relaycrypto.Digest("agentkeyring.request.v1", record)) || statement.RecipientId != l.Recipient.RecipientId {
		return nil, denied("Decision does not match the original request.")
	}
	_, config, err := configuration(tx)
	if err != nil {
		return nil, err
	}
	enrol := machineByID(config, l.Recipient.RecipientId)
	if enrol == nil || statement.ReceiverKeyId != enrol.ReceiverKeyId {
		return nil, denied("Decision receiver is not currently enrolled.")
	}
	if !bytes.Equal(statement.ReplySha256, relaycrypto.Hash([]byte(r.Reply))) {
		return nil, denied("Decision reply hash mismatch.")
	}
	login := loginByID(config, l.LoginId)
	_, keys, err := currentKeys(tx)
	if err != nil {
		return nil, err
	}
	phonePeer := relaycrypto.Role(keys, keyByID(keys, p.approver)) == pb.ApproverRole_APPROVER_ROLE_PHONE
	if phonePeer {
		var count int
		if err = tx.QueryRow("SELECT count(*) FROM phone_escalations WHERE lease=? AND local_lease IS NULL", l.LeaseId).Scan(&count); err != nil {
			return nil, err
		}
		if login.GetRule() != pb.AccessRule_ACCESS_RULE_ASK || count != 1 || r.ApproverKeyId != p.approver || (statement.Authority != pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN && statement.Authority != pb.DecisionAuthority_DECISION_AUTHORITY_APPROVER_CONNECTION) {
			return nil, denied("Phone decisions require their own escalated remote Ask request.")
		}
	}
	switch statement.Authority {
	case pb.DecisionAuthority_DECISION_AUTHORITY_APPROVER_CONNECTION:
		if p.approver == "" || statement.Choice != pb.DecisionChoice_DECISION_CHOICE_DENY || r.Reply != "" || len(r.Signature) != 0 || r.Bundle != nil || len(statement.BundleCiphertextSha256) != 0 || statement.ConfigurationRevision != 0 || (r.ApproverKeyId != "" && r.ApproverKeyId != p.approver) {
			return nil, denied("Approver connection authority permits only an unsigned denial with no reply.")
		}
	case pb.DecisionAuthority_DECISION_AUTHORITY_PHONE:
		_, keys, e := currentKeys(tx)
		if e != nil {
			return nil, e
		}
		if err = relaycrypto.VerifyPhoneDelivery(keys, r, statement); err != nil {
			return nil, denied(err.Error())
		}
		var owner string
		var answer []byte
		if tx.QueryRow("SELECT owner,answer FROM phone_escalations WHERE lease=? AND local_lease IS NULL", l.LeaseId).Scan(&owner, &answer) != nil || owner != p.approver || !bytes.Equal(answer, marshal(r.PhoneDecision)) {
			return nil, denied("Phone answer was not accepted for this escalation.")
		}
	case pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN:
		if statement.ConfigurationRevision != 0 {
			return nil, invalid("Human decision cannot name an Automatic configuration revision.")
		}
		if relaycrypto.Role(keys, keyByID(keys, r.ApproverKeyId)) == pb.ApproverRole_APPROVER_ROLE_PHONE && (p.approver != r.ApproverKeyId || r.PhoneDecision != nil) {
			return nil, denied("A phone signs its own direct human decision without a forwarded phone answer.")
		}
		public, e := relaycrypto.HumanKey(keys, r.ApproverKeyId)
		if e != nil || relaycrypto.Verify(public, r.Statement, r.Signature) != nil {
			return nil, denied("Invalid human decision signature or role.")
		}
	case pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE:
		if statement.Choice != pb.DecisionChoice_DECISION_CHOICE_APPROVE || login == nil || login.Rule != pb.AccessRule_ACCESS_RULE_AUTOMATIC {
			return nil, denied("Automatic authority cannot answer this request.")
		}
		if statement.ConfigurationRevision == 0 || statement.ConfigurationRevision > config.Revision || config.AutomaticKeyId != r.ApproverKeyId || !enrol.AutomaticAllowed {
			return nil, denied("Current configuration does not authorize this Automatic decision.")
		}
		_, keys, e := currentKeys(tx)
		if e != nil {
			return nil, e
		}
		delivery, e := relaycrypto.KeyForRole(keys, config.AutomaticKeyId, pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY)
		if e != nil || !bytes.Equal(delivery, config.AutomaticSigningPublicKey) || relaycrypto.Verify(delivery, r.Statement, r.Signature) != nil {
			return nil, denied("Invalid or retired Automatic signing key.")
		}
	default:
		return nil, invalid("Unknown decision authority.")
	}
	now := time.Now().Unix()
	if statement.ApprovedAtUnixSeconds < l.RequestedAtUnixSeconds || statement.ApprovedAtUnixSeconds > now+30 || statement.ApprovedAtUnixSeconds >= l.PendingUntilUnixSeconds {
		return nil, denied("Decision approval time is outside this request.")
	}
	switch statement.Choice {
	case pb.DecisionChoice_DECISION_CHOICE_APPROVE:
		if login == nil || login.Rule == pb.AccessRule_ACCESS_RULE_BLOCKED {
			return nil, denied("Current login policy refuses approval.")
		}
		if statement.NotAfterUnixSeconds <= now || statement.NotAfterUnixSeconds > statement.ApprovedAtUnixSeconds+1800 || statement.NotAfterUnixSeconds <= statement.ApprovedAtUnixSeconds {
			return nil, denied("Decision deadline is expired or exceeds 30 minutes.")
		}
		if r.Bundle == nil || len(r.Bundle.Ciphertext) == 0 || len(r.Bundle.EncapsulatedKey) != 65 || r.Bundle.ReceiverKeyId != enrol.ReceiverKeyId || !bytes.Equal(statement.BundleCiphertextSha256, relaycrypto.Hash(r.Bundle.Ciphertext)) {
			return nil, denied("Sealed bundle does not match the signed decision.")
		}
		if _, err = relaycrypto.PublicKey(r.Bundle.EncapsulatedKey); err != nil {
			return nil, invalid("Invalid HPKE encapsulated key.")
		}
		l.State = pb.LeaseState_LEASE_STATE_ACTIVE
		l.ApprovedAtUnixSeconds = statement.ApprovedAtUnixSeconds
		l.NotAfterUnixSeconds = statement.NotAfterUnixSeconds
	case pb.DecisionChoice_DECISION_CHOICE_DENY:
		if r.Bundle != nil || len(statement.BundleCiphertextSha256) > 0 {
			return nil, invalid("Denial cannot include a bundle.")
		}
		end(l, pb.LeaseState_LEASE_STATE_DENIED)
		l.Reply = r.Reply
		l.RetryNotBeforeUnixSeconds = statement.ApprovedAtUnixSeconds + 1800
	default:
		return nil, invalid("Unknown decision choice.")
	}
	l.ApprovedBy = pb.ApprovedBy_APPROVED_BY_MAC
	if statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_PHONE || phonePeer {
		l.ApprovedBy = pb.ApprovedBy_APPROVED_BY_IPHONE
	}
	if statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE {
		l.ApprovedBy = pb.ApprovedBy_APPROVED_BY_AUTOMATIC_RULE
	}
	if statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_APPROVER_CONNECTION {
		_, keys, e := currentKeys(tx)
		if e != nil {
			return nil, e
		}
		if relaycrypto.Role(keys, keyByID(keys, p.approver)) == pb.ApproverRole_APPROVER_ROLE_PHONE {
			l.ApprovedBy = pb.ApprovedBy_APPROVED_BY_IPHONE
		}
	}
	if statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_APPROVER_CONNECTION {
		var accepted []byte
		if tx.QueryRow("SELECT answer FROM phone_escalations WHERE lease=? AND owner=?", l.LeaseId, p.approver).Scan(&accepted) == nil && len(accepted) > 0 {
			answer := new(pb.SignedPhoneDecision)
			phone := new(pb.PhoneDecision)
			if proto.Unmarshal(accepted, answer) == nil && proto.Unmarshal(answer.Decision, phone) == nil && phone.Choice == pb.DecisionChoice_DECISION_CHOICE_DENY && answer.Reply == "" {
				l.ApprovedBy = pb.ApprovedBy_APPROVED_BY_IPHONE
			}
		}
	}
	if err = saveLease(tx, l); err != nil {
		return nil, err
	}
	var bundle []byte
	if r.Bundle != nil && !terminal(l) {
		bundle = marshal(r.Bundle)
	}
	stored := proto.Clone(r).(*pb.SignedDecision)
	stored.Bundle = nil
	if terminal(l) && stored.Reply == "" {
		stored.PhoneDecision = nil
	}
	if _, err = tx.Exec("UPDATE leases SET decision=?,decision_hash=?,bundle=? WHERE id=?", marshal(stored), relaycrypto.Hash(marshal(r)), bundle, l.LeaseId); err != nil {
		return nil, err
	}
	return &pb.DecisionAck{Accepted: true, Lease: l}, nil
}
func (s *Server) publishConfiguration(tx *sql.Tx, publication *pb.ConfigurationPublication) error {
	if publication == nil || publication.Configuration == nil {
		return invalid("Missing configuration.")
	}
	r := publication.Configuration
	if err := verifyApprover(tx, r.ApproverKeyId, r.Configuration, r.Signature, true); err != nil {
		return err
	}
	next := new(pb.Configuration)
	if proto.Unmarshal(r.Configuration, next) != nil || next.Domain != "agentkeyring.configuration.v1" || next.Revision == 0 {
		return invalid("Invalid configuration.")
	}
	oldSigned, old, err := configuration(tx)
	if err != nil {
		return err
	}
	if oldSigned != nil && next.Revision <= old.Revision {
		if bytes.Equal(oldSigned.Configuration, r.Configuration) {
			return nil
		}
		return conflict("Configuration revision did not increase.")
	}
	currentSigned, keys, err := currentKeys(tx)
	if err != nil {
		return err
	}
	if len(next.RelayEncryptionPublicKey) != 0 && !s.delegatesAutomatic(next) {
		return denied("Configuration must name this relay's exact Automatic signing and encryption keys.")
	}
	if !s.delegatesAutomatic(next) && (next.AutomaticKeyId != "" || len(next.AutomaticSigningPublicKey) != 0) {
		key, e := relaycrypto.KeyForRole(keys, next.AutomaticKeyId, pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY)
		if e != nil || !bytes.Equal(key, next.AutomaticSigningPublicKey) {
			return denied("Configuration must name a current Mac delivery key.")
		}
	}
	ids := map[string]bool{}
	for _, login := range next.Logins {
		if login.LoginId == "" || ids[login.LoginId] || login.Rule < 1 || login.Rule > 3 {
			return invalid("Configuration has duplicate login IDs or unknown rules.")
		}
		ids[login.LoginId] = true
	}
	ids = map[string]bool{}
	tlsKeys := map[string]bool{}
	for _, machine := range next.Machines {
		if machine.RecipientId == "" || ids[machine.RecipientId] || tlsKeys[string(machine.TlsPublicKey)] {
			return invalid("Configuration has duplicate machines or TLS keys.")
		}
		ids[machine.RecipientId] = true
		tlsKeys[string(machine.TlsPublicKey)] = true
		var raw, compared []byte
		var state int
		var expires sql.NullInt64
		if tx.QueryRow("SELECT record,keyset,state,expires FROM enrolments WHERE id=?", machine.RecipientId).Scan(&raw, &compared, &state, &expires) != nil {
			return denied("Configuration names an unknown machine. Enrol it first.")
		}
		record := new(pb.EnrolmentRecord)
		if err = proto.Unmarshal(raw, record); err != nil {
			return err
		}
		expected := &pb.EnrolledMachine{RecipientId: record.RecipientId, MachineLabel: record.MachineLabel, ClientLabel: record.ClientLabel, TailscaleNodeId: record.TailscaleNodeId, TlsPublicKey: record.TlsPublicKey, ReceiverPublicKey: record.ReceiverPublicKey, ReceiverKeyId: record.ReceiverKeyId, AutomaticAllowed: machine.AutomaticAllowed}
		if !proto.Equal(machine, expected) || (state != 0 && state != 1) {
			return denied("Machine does not match its enrolled keys and tailnet node.")
		}
		if state == 0 {
			set := new(pb.SignedApproverKeySet)
			if err = proto.Unmarshal(compared, set); err != nil {
				return err
			}
			comparedKeys := new(pb.ApproverKeySet)
			if err = proto.Unmarshal(set.KeySet, comparedKeys); err != nil {
				return err
			}
			if !expires.Valid || expires.Int64 <= time.Now().Unix() || !bytes.Equal(set.KeySet, currentSigned.KeySet) || !bytes.Equal(record.ApproverKeySetSha256, relaycrypto.Hash(set.KeySet)) || comparedKeys.RuleOwnerKeyId != r.ApproverKeyId || !bytes.Equal(keyByID(comparedKeys, r.ApproverKeyId).GetPublicKey(), keyByID(keys, r.ApproverKeyId).GetPublicKey()) {
				return denied("Compared enrolment expired or its rule owner changed.")
			}
		}
		if _, err = tx.Exec("UPDATE enrolments SET state=1,decision=?,expires=NULL WHERE id=?", marshal(r), machine.RecipientId); err != nil {
			return err
		}
	}
	for _, machine := range old.Machines {
		if machineByID(next, machine.RecipientId) == nil {
			if _, err = tx.Exec("UPDATE enrolments SET state=3,expires=? WHERE id=?", time.Now().Unix()+600, machine.RecipientId); err != nil {
				return err
			}
		}
	}
	leases, err := queryLeases(tx, "SELECT lease FROM leases WHERE deadline IS NOT NULL")
	if err != nil {
		return err
	}
	for _, lease := range leases {
		login, machine := loginByID(next, lease.LoginId), machineByID(next, lease.GetRecipient().GetRecipientId())
		revoke := login == nil || login.Rule == pb.AccessRule_ACCESS_RULE_BLOCKED || machine == nil
		if lease.ApprovedBy == pb.ApprovedBy_APPROVED_BY_AUTOMATIC_RULE {
			revoke = revoke || login.GetRule() != pb.AccessRule_ACCESS_RULE_AUTOMATIC || !machine.GetAutomaticAllowed() || old.AutomaticKeyId != next.AutomaticKeyId || !bytes.Equal(old.AutomaticSigningPublicKey, next.AutomaticSigningPublicKey)
		}
		if revoke {
			end(lease, pb.LeaseState_LEASE_STATE_REVOKED)
			if err = saveLease(tx, lease); err != nil {
				return err
			}
		}
	}
	if err = s.pruneAutomaticCopies(tx, next); err != nil {
		return err
	}
	if relaycrypto.ConfigurationWithdraws(old, next) {
		var removed [][]byte
		for _, machine := range old.Machines {
			after := machineByID(next, machine.RecipientId)
			if after == nil || !bytes.Equal(after.TlsPublicKey, machine.TlsPublicKey) {
				removed = append(removed, machine.TlsPublicKey)
				if err = retireDevice(tx, machine.TlsPublicKey, machine.TailscaleNodeId); err != nil {
					return err
				}
			}
		}
		if err = retainWithdrawal(tx, &pb.TrustUpdate{Update: &pb.TrustUpdate_Configuration{Configuration: r}}, keys, next, removed); err != nil {
			return err
		}
	}
	return put(tx, "current", "configuration", r)
}
func (s *Server) publishKeys(tx *sql.Tx, r *pb.SignedApproverKeySet) error {
	if r == nil {
		return invalid("Missing approver key set.")
	}
	oldSigned, old, err := currentKeys(tx)
	if err != nil {
		return err
	}
	if proto.Equal(r, oldSigned) {
		return nil
	}
	if err = verifyApprover(tx, r.SignerKeyId, r.KeySet, r.Signature, false); err != nil {
		return err
	}
	next := new(pb.ApproverKeySet)
	if proto.Unmarshal(r.KeySet, next) != nil || next.Domain != "agentkeyring.approvers.v1" || next.Revision <= old.Revision || len(next.Keys) == 0 || keyByID(next, next.RuleOwnerKeyId) == nil {
		return invalid("Invalid approver key set or revision.")
	}
	relaySPKI, _ := relaycrypto.CertificateSPKI(s.Certificate)
	ids := map[string]bool{}
	tlsKeys := map[string]bool{}
	added := 0
	for _, key := range next.Keys {
		if key.KeyId == "" || ids[key.KeyId] || (len(key.TlsPublicKey) > 0 && (tlsKeys[string(key.TlsPublicKey)] || !validSPKI(key.TlsPublicKey))) {
			return invalid("Duplicate or invalid approver keys.")
		}
		if key.Role != pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY && !validSPKI(key.TlsPublicKey) {
			return invalid("Approver requires a TLS identity.")
		}
		ids[key.KeyId] = true
		if len(key.TlsPublicKey) > 0 {
			tlsKeys[string(key.TlsPublicKey)] = true
		}
		if _, err = relaycrypto.PublicKey(key.PublicKey); err != nil {
			return invalid("Invalid approver signing key.")
		}
		before := keyByID(old, key.KeyId)
		if before != nil {
			if !bytes.Equal(before.PublicKey, key.PublicKey) || !bytes.Equal(before.TlsPublicKey, key.TlsPublicKey) || !bytes.Equal(before.EncryptionPublicKey, key.EncryptionPublicKey) || relaycrypto.Role(old, before) != relaycrypto.Role(next, key) {
				return invalid("Key rotation requires a new key ID and pairing.")
			}
			continue
		}
		if key.Role == pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY {
			continue
		}
		added++
		var data, compared []byte
		var created int64
		if err = tx.QueryRow("SELECT request,keyset,created FROM pairings WHERE id=?", key.KeyId).Scan(&data, &compared, &created); err != nil {
			return denied("No pending pairing for added approver.")
		}
		pair := new(pb.PairApproverRequest)
		if err = proto.Unmarshal(data, pair); err != nil {
			return err
		}
		if !proto.Equal(pair.Key, key) || !bytes.Equal(compared, oldSigned.KeySet) || time.Now().Unix() >= created+600 || !bytes.Equal(next.PairingTranscriptSha256, relaycrypto.Hash(relaycrypto.PairTranscript(relaySPKI, key.TlsPublicKey, key.PublicKey, oldSigned.KeySet, key.EncryptionPublicKey))) {
			return denied("Added approver does not match the compared pairing.")
		}
	}
	if err = relaycrypto.ValidateRoles(next, old.RuleOwnerKeyId); err != nil {
		return denied(err.Error())
	}
	if added > 1 {
		return invalid("Pair one new approver at a time.")
	}
	if added == 1 {
		signed, config, err := configuration(tx)
		if err != nil {
			return err
		}
		if signed == nil || config.Revision != next.ConfigurationRevision || !bytes.Equal(next.ConfigurationSha256, relaycrypto.Hash(signed.Configuration)) {
			return denied("New approver set must bind the current signed configuration.")
		}
	}
	for _, key := range next.Keys {
		if key.Role != pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY {
			if _, err = tx.Exec("UPDATE pairings SET expires=NULL WHERE id=?", key.KeyId); err != nil {
				return err
			}
		}
	}
	if relaycrypto.ApproverKeysWithdraw(old, next) {
		if r.SignerKeyId != old.RuleOwnerKeyId {
			return denied("Only the rule owner may withdraw approver authority.")
		}
		_, config, err := configuration(tx)
		if err != nil {
			return err
		}
		var removed [][]byte
		for _, key := range old.Keys {
			if len(key.TlsPublicKey) > 0 && keyByID(next, key.KeyId) == nil {
				var node string
				if err = tx.QueryRow("SELECT node FROM pairings WHERE id=?", key.KeyId).Scan(&node); err != nil {
					return err
				}
				if err = retireDevice(tx, key.TlsPublicKey, node); err != nil {
					return err
				}
				removed = append(removed, key.TlsPublicKey)
			}
		}
		if err = retainWithdrawal(tx, &pb.TrustUpdate{Update: &pb.TrustUpdate_ApproverKeys{ApproverKeys: r}}, next, config, removed); err != nil {
			return err
		}
	}
	for _, key := range old.Keys {
		if keyByID(next, key.KeyId) == nil {
			if err = removePhoneCopy(tx, key); err != nil {
				return err
			}
			if _, err = tx.Exec("DELETE FROM pairings WHERE id=?", key.KeyId); err != nil {
				return err
			}
			if _, err = tx.Exec("DELETE FROM objects WHERE kind='push' AND id=?", key.KeyId); err != nil {
				return err
			}
		}
	}
	if err = put(tx, "current", "keys", r); err != nil {
		return err
	}
	return put(tx, "keychain", revisionID(next.Revision), r)
}
