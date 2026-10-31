// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relay

import (
	"bytes"
	"database/sql"
	"encoding/hex"
	"errors"
	"slices"
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
	if key == nil || (owner && keys.RuleOwnerKeyId != id) {
		return denied("Signer is not a current authorized approver.")
	}
	if relaycrypto.Verify(key.PublicKey, statement, signature) != nil {
		return denied("Invalid approver signature.")
	}
	return nil
}
func (s *Server) approver(tx *sql.Tx, p peer, r *pb.RelayWireRequest, seen map[string][]byte) (*pb.RelayWireResponse, bool, error) {
	switch request := r.Request.(type) {
	case *pb.RelayWireRequest_WatchWork:
		if request.WatchWork.ApproverKeyId != p.approver {
			return nil, false, denied("Watcher must name its pinned approver key.")
		}
		return s.work(tx, seen)
	case *pb.RelayWireRequest_Decide:
		result, err := s.decide(tx, p, request.Decide)
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Decision{Decision: result}, EndOfStream: true}, false, err
	case *pb.RelayWireRequest_DecideEnrolment:
		err := s.decideEnrolment(tx, request.DecideEnrolment)
		return enrolAck(), false, err
	case *pb.RelayWireRequest_ClearDenial:
		err := s.clearDenial(tx, request.ClearDenial)
		return publishAck(), false, err
	case *pb.RelayWireRequest_RevokeLease:
		lease, _, err := loadLease(tx, request.RevokeLease.LeaseId)
		if err == nil && !terminal(lease) {
			end(lease, pb.LeaseState_LEASE_STATE_REVOKED)
			err = saveLease(tx, lease)
		}
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Lease{Lease: lease}, EndOfStream: true}, false, err
	case *pb.RelayWireRequest_PublishIndex:
		err := s.publishIndex(tx, request.PublishIndex)
		return publishAck(), false, err
	case *pb.RelayWireRequest_GetIndex:
		value := new(pb.SignedIndex)
		err := get(tx, "current", "index", value)
		if errors.Is(err, sql.ErrNoRows) {
			err = missing("No login index published yet.")
		}
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Index{Index: value}, EndOfStream: true}, false, err
	case *pb.RelayWireRequest_PublishAutomaticGrant:
		err := s.publishGrant(tx, request.PublishAutomaticGrant)
		return publishAck(), false, err
	case *pb.RelayWireRequest_ListEnrolments:
		rows, err := tx.Query("SELECT record,decision FROM enrolments WHERE state=? ORDER BY id", int(pb.EnrolmentChoice_ENROLMENT_CHOICE_APPROVE))
		if err != nil {
			return nil, false, err
		}
		result := new(pb.ListEnrolmentsResponse)
		for rows.Next() {
			var record, decision []byte
			if err = rows.Scan(&record, &decision); err != nil {
				break
			}
			signed := new(pb.SignedEnrolmentDecision)
			if err = proto.Unmarshal(decision, signed); err != nil {
				break
			}
			result.Enrolments = append(result.Enrolments, &pb.ApprovedEnrolment{Record: record, Decision: signed})
		}
		if err == nil {
			err = rows.Err()
		}
		rows.Close()
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Enrolments{Enrolments: result}, EndOfStream: true}, false, err
	case *pb.RelayWireRequest_PublishEnrolmentSet:
		err := s.publishRoster(tx, request.PublishEnrolmentSet)
		return publishAck(), false, err
	case *pb.RelayWireRequest_GetEnrolmentSet:
		value := new(pb.SignedEnrolmentSet)
		err := get(tx, "current", "roster", value)
		if errors.Is(err, sql.ErrNoRows) {
			err = missing("No signed machine roster published yet.")
		}
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_EnrolmentSet{EnrolmentSet: value}, EndOfStream: true}, false, err
	case *pb.RelayWireRequest_PublishApproverKeys:
		err := s.publishKeys(tx, request.PublishApproverKeys)
		return publishAck(), false, err
	case *pb.RelayWireRequest_PublishAutomatic, *pb.RelayWireRequest_RegisterPush, *pb.RelayWireRequest_GetAutomaticKeys:
		return nil, false, &rpcError{pb.RpcErrorCode_RPC_ERROR_CODE_UNAVAILABLE, "This method belongs to release 4 and is not available on this relay."}
	default:
		return nil, false, invalid("Select a supported relay method.")
	}
}
func (s *Server) clearDenial(tx *sql.Tx, request *pb.ClearDenialRequest) error {
	if request.RecipientId == "" || request.LoginId == "" {
		return invalid("Recipient and login are required.")
	}
	leases, err := allLeases(tx)
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
func (s *Server) work(tx *sql.Tx, seen map[string][]byte) (*pb.RelayWireResponse, bool, error) {
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
	rows, err = tx.Query("SELECT request,keyset,created FROM pairings ORDER BY rowid")
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
	if err = tx.QueryRow("SELECT decision FROM leases WHERE id=?", l.LeaseId).Scan(&accepted); err != nil {
		return nil, err
	}
	if len(accepted) > 0 {
		old := new(pb.SignedDecision)
		if proto.Unmarshal(accepted, old) != nil {
			return nil, errors.New("corrupt decision")
		}
		return &pb.DecisionAck{Accepted: proto.Equal(old, r), Lease: l, Detail: "The request already has a decision."}, nil
	}
	if terminal(l) || l.State != pb.LeaseState_LEASE_STATE_PENDING {
		return &pb.DecisionAck{Lease: l, Detail: "The request is no longer pending."}, nil
	}
	if !bytes.Equal(statement.RequestDigest, relaycrypto.Digest("agentkeyring.request.v1", record)) || statement.RecipientId != l.Recipient.RecipientId {
		return nil, denied("Decision does not match the original request.")
	}
	var enrolBytes []byte
	var state int
	if err = tx.QueryRow("SELECT record,state FROM enrolments WHERE id=?", l.Recipient.RecipientId).Scan(&enrolBytes, &state); err != nil {
		return nil, err
	}
	enrol := new(pb.EnrolmentRecord)
	if err = proto.Unmarshal(enrolBytes, enrol); err != nil {
		return nil, err
	}
	if state != int(pb.EnrolmentChoice_ENROLMENT_CHOICE_APPROVE) || statement.ReceiverKeyId != enrol.ReceiverKeyId {
		return nil, denied("Decision receiver is not currently enrolled.")
	}
	if !bytes.Equal(statement.ReplySha256, relaycrypto.Hash([]byte(r.Reply))) {
		return nil, denied("Decision reply hash mismatch.")
	}
	idx, err := index(tx)
	if err != nil {
		return nil, err
	}
	login := loginByID(idx, l.LoginId)
	switch statement.Authority {
	case pb.DecisionAuthority_DECISION_AUTHORITY_APPROVER_CONNECTION:
		if p.approver == "" || statement.Choice != pb.DecisionChoice_DECISION_CHOICE_DENY || r.Reply != "" || len(r.Signature) != 0 || r.Bundle != nil || len(statement.BundleCiphertextSha256) != 0 || statement.AutomaticGrantRevision != 0 || (r.ApproverKeyId != "" && r.ApproverKeyId != p.approver) {
			return nil, denied("Approver connection authority permits only an unsigned denial with no reply.")
		}
	case pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN:
		if statement.AutomaticGrantRevision != 0 {
			return nil, invalid("Human decision cannot name an Automatic grant.")
		}
		if err = verifyApprover(tx, r.ApproverKeyId, r.Statement, r.Signature, false); err != nil {
			return nil, err
		}
	case pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE:
		if statement.Choice != pb.DecisionChoice_DECISION_CHOICE_APPROVE || login == nil || login.Rule != pb.AccessRule_ACCESS_RULE_AUTOMATIC {
			return nil, denied("Automatic authority cannot answer this request.")
		}
		signed := new(pb.SignedAutomaticGrant)
		if err = get(tx, "current", "grant", signed); err != nil {
			return nil, denied("No current Automatic grant.")
		}
		grant := new(pb.AutomaticGrant)
		if err = proto.Unmarshal(signed.Grant, grant); err != nil {
			return nil, err
		}
		if verifyApprover(tx, signed.ApproverKeyId, signed.Grant, signed.Signature, true) != nil || grant.Revision != statement.AutomaticGrantRevision || grant.AutomaticKeyId != r.ApproverKeyId || !slices.Contains(grant.LoginIds, l.LoginId) || !slices.Contains(grant.RecipientIds, l.Recipient.RecipientId) {
			return nil, denied("Automatic grant does not authorize this login and recipient.")
		}
		approval := new(pb.SignedEnrolmentDecision)
		var data []byte
		if err = tx.QueryRow("SELECT decision FROM enrolments WHERE id=?", enrol.RecipientId).Scan(&data); err != nil {
			return nil, err
		}
		if err = proto.Unmarshal(data, approval); err != nil {
			return nil, err
		}
		enrolStatement := new(pb.EnrolmentStatement)
		if err = proto.Unmarshal(approval.Statement, enrolStatement); err != nil {
			return nil, err
		}
		if !enrolStatement.AutomaticAllowed {
			return nil, denied("This machine was not allowed Automatic logins.")
		}
		if relaycrypto.Verify(grant.AutomaticSigningPublicKey, r.Statement, r.Signature) != nil {
			return nil, denied("Invalid Automatic signature.")
		}
	default:
		return nil, invalid("Unknown decision authority.")
	}
	now := time.Now().Unix()
	if statement.ApprovedAtUnixSeconds < l.RequestedAtUnixSeconds || statement.ApprovedAtUnixSeconds > now+30 {
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
		l.ApprovedBy = pb.ApprovedBy_APPROVED_BY_MAC
		if statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE {
			l.ApprovedBy = pb.ApprovedBy_APPROVED_BY_AUTOMATIC_RULE
		}
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
	if err = saveLease(tx, l); err != nil {
		return nil, err
	}
	var bundle []byte
	if r.Bundle != nil {
		bundle = marshal(r.Bundle)
	}
	if _, err = tx.Exec("UPDATE leases SET decision=?,bundle=? WHERE id=?", marshal(r), bundle, l.LeaseId); err != nil {
		return nil, err
	}
	return &pb.DecisionAck{Accepted: true, Lease: l}, nil
}
func (s *Server) decideEnrolment(tx *sql.Tx, r *pb.SignedEnrolmentDecision) error {
	if r == nil {
		return invalid("Missing enrolment decision.")
	}
	if err := verifyApprover(tx, r.ApproverKeyId, r.Statement, r.Signature, false); err != nil {
		return err
	}
	statement := new(pb.EnrolmentStatement)
	if proto.Unmarshal(r.Statement, statement) != nil || statement.Domain != "agentkeyring.enrolment.v1" || statement.Choice < 1 || statement.Choice > 3 {
		return invalid("Invalid enrolment statement.")
	}
	rows, err := tx.Query("SELECT id,record,decision,state FROM enrolments")
	if err != nil {
		return err
	}
	var id string
	var record *pb.EnrolmentRecord
	var previous []byte
	var state int
	for rows.Next() {
		var candidateID string
		var data, decision []byte
		var candidateState int
		if err = rows.Scan(&candidateID, &data, &decision, &candidateState); err != nil {
			break
		}
		if bytes.Equal(statement.EnrolmentDigest, relaycrypto.Digest("agentkeyring.enrolment.v1", data)) {
			id = candidateID
			record = new(pb.EnrolmentRecord)
			err = proto.Unmarshal(data, record)
			previous = decision
			state = candidateState
			break
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return err
	}
	if record == nil {
		return missing("Enrolment record not found.")
	}
	if len(previous) > 0 {
		old := new(pb.SignedEnrolmentDecision)
		if err = proto.Unmarshal(previous, old); err != nil {
			return err
		}
		if proto.Equal(old, r) {
			return nil
		}
		if statement.Choice != pb.EnrolmentChoice_ENROLMENT_CHOICE_REVOKE || state != int(pb.EnrolmentChoice_ENROLMENT_CHOICE_APPROVE) {
			return conflict("Enrolment was already decided.")
		}
	}
	if statement.DecidedUnixSeconds < record.CreatedUnixSeconds || statement.DecidedUnixSeconds > time.Now().Unix()+30 {
		return denied("Invalid enrolment decision time.")
	}
	if statement.Choice != pb.EnrolmentChoice_ENROLMENT_CHOICE_REVOKE {
		current, _, err := currentKeys(tx)
		if err != nil {
			return err
		}
		if time.Now().Unix() >= record.CreatedUnixSeconds+600 || !bytes.Equal(record.ApproverKeySetSha256, relaycrypto.Hash(current.KeySet)) {
			return denied("Compared enrolment has expired or its key set changed.")
		}
	}
	if _, err = tx.Exec("UPDATE enrolments SET state=?,decision=? WHERE id=?", int(statement.Choice), marshal(r), id); err != nil {
		return err
	}
	if statement.Choice == pb.EnrolmentChoice_ENROLMENT_CHOICE_REVOKE {
		return revokeRecipient(tx, id)
	}
	return nil
}
func revokeRecipient(tx *sql.Tx, id string) error {
	leases, err := allLeases(tx)
	if err != nil {
		return err
	}
	for _, l := range leases {
		if l.Recipient.RecipientId == id && !terminal(l) {
			end(l, pb.LeaseState_LEASE_STATE_REVOKED)
			if err = saveLease(tx, l); err != nil {
				return err
			}
		}
	}
	return nil
}
func (s *Server) publishIndex(tx *sql.Tx, r *pb.SignedIndex) error {
	if r == nil {
		return invalid("Missing index.")
	}
	if err := verifyApprover(tx, r.ApproverKeyId, r.Index, r.Signature, true); err != nil {
		return err
	}
	next := new(pb.LoginIndex)
	if proto.Unmarshal(r.Index, next) != nil || next.Revision == 0 {
		return invalid("Invalid login index.")
	}
	oldSigned := new(pb.SignedIndex)
	if err := get(tx, "current", "index", oldSigned); err == nil {
		old := new(pb.LoginIndex)
		if err = proto.Unmarshal(oldSigned.Index, old); err != nil {
			return err
		}
		if next.Revision <= old.Revision {
			if proto.Equal(oldSigned, r) {
				return nil
			}
			return conflict("Login index revision did not increase.")
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	ids := map[string]bool{}
	for _, login := range next.Logins {
		if login.LoginId == "" || ids[login.LoginId] || login.Rule < 1 || login.Rule > 3 {
			return invalid("Login index has duplicate IDs or unknown rules.")
		}
		ids[login.LoginId] = true
	}
	old, err := index(tx)
	if err != nil {
		return err
	}
	leases, err := allLeases(tx)
	if err != nil {
		return err
	}
	for _, l := range leases {
		if terminal(l) {
			continue
		}
		before, after := loginByID(old, l.LoginId), loginByID(next, l.LoginId)
		if after == nil || after.Rule == pb.AccessRule_ACCESS_RULE_BLOCKED || (before != nil && before.Rule == pb.AccessRule_ACCESS_RULE_AUTOMATIC && after.Rule == pb.AccessRule_ACCESS_RULE_ASK) {
			end(l, pb.LeaseState_LEASE_STATE_REVOKED)
			if err = saveLease(tx, l); err != nil {
				return err
			}
		}
	}
	return put(tx, "current", "index", r)
}
func (s *Server) publishGrant(tx *sql.Tx, r *pb.SignedAutomaticGrant) error {
	if r == nil {
		return invalid("Missing Automatic grant.")
	}
	if err := verifyApprover(tx, r.ApproverKeyId, r.Grant, r.Signature, true); err != nil {
		return err
	}
	next := new(pb.AutomaticGrant)
	if proto.Unmarshal(r.Grant, next) != nil || next.Domain != "agentkeyring.automatic.v1" || next.Revision == 0 || next.AutomaticKeyId == "" {
		return invalid("Invalid Automatic grant.")
	}
	if _, err := relaycrypto.PublicKey(next.AutomaticSigningPublicKey); err != nil {
		return invalid("Invalid Automatic signing key.")
	}
	oldSigned := new(pb.SignedAutomaticGrant)
	if err := get(tx, "current", "grant", oldSigned); err == nil {
		old := new(pb.AutomaticGrant)
		if err = proto.Unmarshal(oldSigned.Grant, old); err != nil {
			return err
		}
		if next.Revision <= old.Revision {
			if proto.Equal(oldSigned, r) {
				return nil
			}
			return conflict("Automatic grant revision did not increase.")
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	leases, err := allLeases(tx)
	if err != nil {
		return err
	}
	for _, l := range leases {
		if l.State == pb.LeaseState_LEASE_STATE_ACTIVE && l.ApprovedBy == pb.ApprovedBy_APPROVED_BY_AUTOMATIC_RULE {
			end(l, pb.LeaseState_LEASE_STATE_REVOKED)
			if err = saveLease(tx, l); err != nil {
				return err
			}
		}
	}
	return put(tx, "current", "grant", r)
}
func (s *Server) publishRoster(tx *sql.Tx, r *pb.SignedEnrolmentSet) error {
	if r == nil {
		return invalid("Missing machine roster.")
	}
	if err := verifyApprover(tx, r.ApproverKeyId, r.EnrolmentSet, r.Signature, false); err != nil {
		return err
	}
	next := new(pb.EnrolmentSet)
	if proto.Unmarshal(r.EnrolmentSet, next) != nil || next.Domain != "agentkeyring.enrolments.v1" || next.Revision == 0 {
		return invalid("Invalid machine roster.")
	}
	previous := new(pb.SignedEnrolmentSet)
	if err := get(tx, "current", "roster", previous); err == nil {
		old := new(pb.EnrolmentSet)
		if err = proto.Unmarshal(previous.EnrolmentSet, old); err != nil {
			return err
		}
		if next.Revision <= old.Revision {
			if proto.Equal(previous, r) {
				return nil
			}
			return conflict("Machine roster revision did not increase.")
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	present := map[string]bool{}
	for _, machine := range next.Machines {
		if machine.RecipientId == "" || present[machine.RecipientId] {
			return invalid("Duplicate machine in roster.")
		}
		present[machine.RecipientId] = true
		var data, decision []byte
		var state int
		if err := tx.QueryRow("SELECT record,decision,state FROM enrolments WHERE id=?", machine.RecipientId).Scan(&data, &decision, &state); err != nil {
			return denied("Roster names an unknown machine.")
		}
		record := new(pb.EnrolmentRecord)
		if err := proto.Unmarshal(data, record); err != nil {
			return err
		}
		signed := new(pb.SignedEnrolmentDecision)
		if err := proto.Unmarshal(decision, signed); err != nil {
			return err
		}
		statement := new(pb.EnrolmentStatement)
		if err := proto.Unmarshal(signed.Statement, statement); err != nil {
			return err
		}
		expected := &pb.EnrolledMachine{RecipientId: record.RecipientId, MachineLabel: record.MachineLabel, ClientLabel: record.ClientLabel, TailscaleNodeId: record.TailscaleNodeId, TlsPublicKey: record.TlsPublicKey, ReceiverPublicKey: record.ReceiverPublicKey, ReceiverKeyId: record.ReceiverKeyId, AutomaticAllowed: statement.AutomaticAllowed}
		if state != int(pb.EnrolmentChoice_ENROLMENT_CHOICE_APPROVE) || !proto.Equal(machine, expected) {
			return denied("Roster does not match the approved machine keys and permissions.")
		}
	}
	rows, err := tx.Query("SELECT id FROM enrolments WHERE state=?", int(pb.EnrolmentChoice_ENROLMENT_CHOICE_APPROVE))
	if err != nil {
		return err
	}
	var revoked []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			break
		}
		if !present[id] {
			revoked = append(revoked, id)
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return err
	}
	for _, id := range revoked {
		if _, err = tx.Exec("UPDATE enrolments SET state=? WHERE id=?", int(pb.EnrolmentChoice_ENROLMENT_CHOICE_REVOKE), id); err != nil {
			return err
		}
		if err = revokeRecipient(tx, id); err != nil {
			return err
		}
	}
	return put(tx, "current", "roster", r)
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
		if key.KeyId == "" || ids[key.KeyId] || tlsKeys[string(key.TlsPublicKey)] || !validSPKI(key.TlsPublicKey) {
			return invalid("Duplicate or invalid approver keys.")
		}
		ids[key.KeyId] = true
		tlsKeys[string(key.TlsPublicKey)] = true
		if _, err = relaycrypto.PublicKey(key.PublicKey); err != nil {
			return invalid("Invalid approver signing key.")
		}
		before := keyByID(old, key.KeyId)
		if before != nil {
			if !bytes.Equal(before.PublicKey, key.PublicKey) || !bytes.Equal(before.TlsPublicKey, key.TlsPublicKey) {
				return invalid("Key rotation requires a new key ID and pairing.")
			}
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
		if !proto.Equal(pair.Key, key) || !bytes.Equal(compared, oldSigned.KeySet) || time.Now().Unix() >= created+600 || !bytes.Equal(next.PairingTranscriptSha256, relaycrypto.Hash(relaycrypto.PairTranscript(relaySPKI, key.TlsPublicKey, key.PublicKey, oldSigned.KeySet))) {
			return denied("Added approver does not match the compared pairing.")
		}
	}
	if added > 1 {
		return invalid("Pair one new approver at a time.")
	}
	if added == 1 {
		signed := new(pb.SignedEnrolmentSet)
		if err = get(tx, "current", "roster", signed); err != nil {
			return denied("Publish the current signed machine roster before adding an approver.")
		}
		roster := new(pb.EnrolmentSet)
		if err = proto.Unmarshal(signed.EnrolmentSet, roster); err != nil {
			return err
		}
		if roster.Revision != next.EnrolmentSetRevision || !bytes.Equal(next.EnrolmentSetSha256, relaycrypto.Hash(signed.EnrolmentSet)) {
			return denied("New approver set must bind the current signed roster.")
		}
	}
	if err = put(tx, "current", "keys", r); err != nil {
		return err
	}
	return put(tx, "keychain", revisionID(next.Revision), r)
}
