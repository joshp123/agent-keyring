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

func registerPush(tx *sql.Tx, p peer, r *pb.PushRegistration) error {
	_, keys, err := currentKeys(tx)
	if err != nil {
		return err
	}
	if r.ApproverKeyId != p.approver || relaycrypto.Role(keys, keyByID(keys, p.approver)) != pb.ApproverRole_APPROVER_ROLE_PHONE {
		return denied("Only the paired phone may register its push token.")
	}
	if len(r.ApnsDeviceToken) == 0 {
		_, err = tx.Exec("DELETE FROM objects WHERE kind='push' AND id=?", p.approver)
		return err
	}
	if len(r.ApnsDeviceToken) > 256 {
		return invalid("Invalid push token.")
	}
	if err = put(tx, "push", p.approver, r); err != nil {
		return err
	}
	_, err = tx.Exec("UPDATE push_attempts SET sent=0,retry_at=0 WHERE phone=? AND sent=?", p.approver, pushRefused)
	return err
}
func escalationLease(tx *sql.Tx, id string) (*pb.Lease, []byte, string, error) {
	var owner string
	var record, local []byte
	err := tx.QueryRow("SELECT owner,record,local_lease FROM phone_escalations WHERE lease=?", id).Scan(&owner, &record, &local)
	if err != nil {
		return nil, nil, "", err
	}
	if local == nil {
		lease, _, err := loadLease(tx, id)
		return lease, record, owner, err
	}
	lease := new(pb.Lease)
	err = proto.Unmarshal(local, lease)
	return lease, record, owner, err
}
func localScopeMatches(lease *pb.Lease, record *pb.RequestRecord) bool {
	return lease != nil && record.LeaseId != "" && record.RequestId != "" && record.RecipientId != "" && lease.LeaseId == record.LeaseId && lease.LoginId == record.LoginId && lease.TaskRef == record.TaskRef && lease.Purpose == record.Purpose && lease.Reason == record.Reason && lease.GetRecipient().GetRecipientId() == record.RecipientId && proto.Equal(lease.Program, record.Program) && lease.RequestedAtUnixSeconds == record.CreatedUnixSeconds && lease.PendingUntilUnixSeconds == record.PendingUntilUnixSeconds && record.PendingUntilUnixSeconds == record.CreatedUnixSeconds+600 && !record.Automatic
}
func escalate(tx *sql.Tx, p peer, r *pb.PhoneEscalation) error {
	record := new(pb.RequestRecord)
	if proto.Unmarshal(r.Record, record) != nil || record.LeaseId != r.LeaseId {
		return invalid("Escalation requires the exact request record.")
	}
	var oldOwner string
	var oldRecord, oldLocal []byte
	err := tx.QueryRow("SELECT owner,record,local_lease FROM phone_escalations WHERE lease=?", r.LeaseId).Scan(&oldOwner, &oldRecord, &oldLocal)
	if err == nil {
		if oldOwner != p.approver || !bytes.Equal(oldRecord, r.Record) || (oldLocal == nil) != (r.LocalLease == nil) {
			return conflict("Escalation already belongs to another request or Mac.")
		}
		// The original pending snapshot may be retried after a committed outcome.
		if r.LocalLease != nil && !localScopeMatches(r.LocalLease, record) {
			return invalid("Local snapshot differs from its record.")
		}
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	idx, err := index(tx)
	if err != nil {
		return err
	}
	login := loginByID(idx, record.LoginId)
	if login == nil || login.Rule != pb.AccessRule_ACCESS_RULE_ASK || record.Automatic {
		return denied("Only pending Ask requests escalate.")
	}
	now := time.Now().Unix()
	if record.CreatedUnixSeconds > now+30 || record.CreatedUnixSeconds <= 0 || record.PendingUntilUnixSeconds <= now || record.PendingUntilUnixSeconds != record.CreatedUnixSeconds+600 {
		return denied("Escalation is outside its original pending lifetime.")
	}
	var local []byte
	if r.LocalLease != nil {
		var count int
		if err = tx.QueryRow("SELECT count(*) FROM leases WHERE id=?", r.LeaseId).Scan(&count); err != nil {
			return err
		}
		if count != 0 {
			return conflict("Local lease collides with a remote lease.")
		}
		if r.LocalLease.State != pb.LeaseState_LEASE_STATE_PENDING || !localScopeMatches(r.LocalLease, record) || r.LocalLease.ApprovedAtUnixSeconds != 0 || r.LocalLease.NotAfterUnixSeconds != 0 || r.LocalLease.EndedAtUnixSeconds != 0 || r.LocalLease.SignedDenial != nil {
			return invalid("Invalid local pending lease snapshot.")
		}
		local = marshal(r.LocalLease)
	} else {
		lease, exact, err := loadLease(tx, r.LeaseId)
		if err != nil {
			return err
		}
		if !bytes.Equal(exact, r.Record) || lease.State != pb.LeaseState_LEASE_STATE_PENDING {
			return denied("Remote request is not identical and pending.")
		}
	}
	_, err = tx.Exec("INSERT INTO phone_escalations VALUES(?,?,?,?,NULL)", r.LeaseId, p.approver, r.Record, local)
	return err
}
func answerPhone(tx *sql.Tx, p peer, r *pb.SignedPhoneDecision) (*pb.DecisionAck, error) {
	_, keys, err := currentKeys(tx)
	if err != nil {
		return nil, err
	}
	if r.PhoneKeyId != p.approver {
		return nil, denied("Phone answer must name the pinned phone.")
	}
	key, err := relaycrypto.KeyForRole(keys, r.PhoneKeyId, pb.ApproverRole_APPROVER_ROLE_PHONE)
	if err != nil {
		return nil, denied(err.Error())
	}
	decision := new(pb.PhoneDecision)
	if proto.Unmarshal(r.Decision, decision) != nil || decision.Domain != "agentkeyring.phonedecision.v1" {
		return nil, invalid("Invalid phone decision.")
	}
	lease, record, _, err := escalationLease(tx, decision.LeaseId)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, missing("Request was not escalated.")
	}
	if err != nil {
		return nil, err
	}
	var accepted []byte
	if err = tx.QueryRow("SELECT answer FROM phone_escalations WHERE lease=?", lease.LeaseId).Scan(&accepted); err != nil {
		return nil, err
	}
	if len(accepted) > 0 {
		return &pb.DecisionAck{Accepted: bytes.Equal(accepted, marshal(r)), Lease: lease, Detail: "Phone answer already recorded; Mac outcome is authoritative."}, nil
	}
	if lease.State != pb.LeaseState_LEASE_STATE_PENDING {
		return &pb.DecisionAck{Lease: lease, Detail: "The request is no longer pending."}, nil
	}
	now := time.Now().Unix()
	if !bytes.Equal(decision.RequestDigest, relaycrypto.Digest("agentkeyring.request.v1", record)) || !bytes.Equal(decision.ReplySha256, relaycrypto.Hash([]byte(r.Reply))) || decision.DecidedUnixSeconds < lease.RequestedAtUnixSeconds || decision.DecidedUnixSeconds >= lease.PendingUntilUnixSeconds || decision.DecidedUnixSeconds > now+30 || now >= lease.PendingUntilUnixSeconds {
		return nil, denied("Phone answer differs from this pending request.")
	}
	switch decision.Choice {
	case pb.DecisionChoice_DECISION_CHOICE_APPROVE:
		if decision.NotAfterUnixSeconds <= now || decision.NotAfterUnixSeconds <= decision.DecidedUnixSeconds || decision.NotAfterUnixSeconds > decision.DecidedUnixSeconds+1800 {
			return nil, denied("Invalid phone approval deadline.")
		}
	case pb.DecisionChoice_DECISION_CHOICE_DENY:
		if decision.NotAfterUnixSeconds != 0 {
			return nil, invalid("Denial has no approval deadline.")
		}
	default:
		return nil, invalid("Invalid phone choice.")
	}
	if decision.Choice != pb.DecisionChoice_DECISION_CHOICE_DENY || r.Reply != "" || len(r.Signature) > 0 {
		if relaycrypto.Verify(key, r.Decision, r.Signature) != nil {
			return nil, denied("Invalid phone signature.")
		}
	}
	_, err = tx.Exec("UPDATE phone_escalations SET answer=? WHERE lease=?", marshal(r), lease.LeaseId)
	return &pb.DecisionAck{Accepted: true, Lease: lease, Detail: "Waiting for your Mac."}, err
}
func updateLocalPhoneLease(tx *sql.Tx, p peer, r *pb.LocalPhoneLeaseUpdate) (*pb.DecisionAck, error) {
	if r.Lease == nil {
		return nil, invalid("Local lease snapshot is required.")
	}
	old, raw, owner, err := escalationLease(tx, r.Lease.LeaseId)
	if err != nil {
		return nil, err
	}
	var local []byte
	if err = tx.QueryRow("SELECT local_lease FROM phone_escalations WHERE lease=?", old.LeaseId).Scan(&local); err != nil {
		return nil, err
	}
	if owner != p.approver || local == nil || !bytes.Equal(r.RequestDigest, relaycrypto.Digest("agentkeyring.request.v1", raw)) {
		return nil, denied("Only the owning Mac may report this local lease.")
	}
	record := new(pb.RequestRecord)
	if err = proto.Unmarshal(raw, record); err != nil {
		return nil, err
	}
	next := r.Lease
	if !localScopeMatches(next, record) || next.SignedDenial != nil || next.State < pb.LeaseState_LEASE_STATE_PENDING || next.State > pb.LeaseState_LEASE_STATE_UNANSWERED {
		return nil, invalid("Local outcome differs from its request scope.")
	}
	if proto.Equal(old, next) {
		return &pb.DecisionAck{Accepted: true, Lease: old}, nil
	}
	// No older report can reopen an ended lease or change a committed deadline.
	if terminal(old) {
		cleared := proto.Clone(old).(*pb.Lease)
		cleared.RetryNotBeforeUnixSeconds = 0
		if old.State != pb.LeaseState_LEASE_STATE_DENIED || !proto.Equal(cleared, next) {
			return &pb.DecisionAck{Lease: old, Detail: "Local lease already ended."}, nil
		}
	} else if old.State == pb.LeaseState_LEASE_STATE_ACTIVE && (next.State == pb.LeaseState_LEASE_STATE_PENDING || next.ApprovedAtUnixSeconds != old.ApprovedAtUnixSeconds || next.NotAfterUnixSeconds != old.NotAfterUnixSeconds) {
		return &pb.DecisionAck{Lease: old, Detail: "Older local snapshot refused."}, nil
	}
	if next.State == pb.LeaseState_LEASE_STATE_ACTIVE && (next.ApprovedAtUnixSeconds < record.CreatedUnixSeconds || next.ApprovedAtUnixSeconds >= record.PendingUntilUnixSeconds || next.NotAfterUnixSeconds <= next.ApprovedAtUnixSeconds || next.NotAfterUnixSeconds > next.ApprovedAtUnixSeconds+1800) {
		return nil, invalid("Invalid local approval lifetime.")
	}
	if _, err = tx.Exec("UPDATE phone_escalations SET local_lease=? WHERE lease=?", marshal(next), next.LeaseId); err != nil {
		return nil, err
	}
	if terminal(next) {
		if _, err = tx.Exec("DELETE FROM objects WHERE kind='local-revoke' AND id=?", next.LeaseId); err != nil {
			return nil, err
		}
	}
	if next.State == pb.LeaseState_LEASE_STATE_DENIED && next.RetryNotBeforeUnixSeconds == 0 {
		_, err = tx.Exec("DELETE FROM objects WHERE kind='local-clear' AND id=?", next.LeaseId)
	}
	return &pb.DecisionAck{Accepted: true, Lease: next}, err
}
func revokeLocal(tx *sql.Tx, id string) (*pb.Lease, error) {
	var local []byte
	err := tx.QueryRow("SELECT local_lease FROM phone_escalations WHERE lease=?", id).Scan(&local)
	if errors.Is(err, sql.ErrNoRows) || err == nil && local == nil {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	lease := new(pb.Lease)
	if err = proto.Unmarshal(local, lease); err != nil {
		return nil, err
	}
	if !terminal(lease) {
		err = put(tx, "local-revoke", id, &pb.LocalLeaseAction{Action: &pb.LocalLeaseAction_RevokeLease{RevokeLease: &pb.LeaseReference{LeaseId: id}}})
	}
	return lease, err
}
func queueLocalClear(tx *sql.Tx, r *pb.ClearDenialRequest) error {
	rows, err := tx.Query("SELECT lease,local_lease FROM phone_escalations WHERE local_lease IS NOT NULL")
	if err != nil {
		return err
	}
	var ids []string
	for rows.Next() {
		var id string
		var data []byte
		if err = rows.Scan(&id, &data); err != nil {
			break
		}
		lease := new(pb.Lease)
		if err = proto.Unmarshal(data, lease); err != nil {
			break
		}
		if lease.State == pb.LeaseState_LEASE_STATE_DENIED && lease.LoginId == r.LoginId && lease.GetRecipient().GetRecipientId() == r.RecipientId && lease.RetryNotBeforeUnixSeconds != 0 {
			ids = append(ids, id)
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return err
	}
	for _, id := range ids {
		if err = put(tx, "local-clear", id, &pb.LocalLeaseAction{Action: &pb.LocalLeaseAction_ClearDenial{ClearDenial: r}}); err != nil {
			return err
		}
	}
	return nil
}
func phoneWork(tx *sql.Tx, p peer, seen map[string][]byte) (*pb.RelayWireResponse, error) {
	_, keys, err := currentKeys(tx)
	if err != nil {
		return nil, err
	}
	phone := relaycrypto.Role(keys, keyByID(keys, p.approver)) == pb.ApproverRole_APPROVER_ROLE_PHONE
	rows, err := tx.Query("SELECT lease,owner,record,local_lease,answer FROM phone_escalations ORDER BY rowid")
	if err != nil {
		return nil, err
	}
	type entry struct {
		id, owner             string
		record, local, answer []byte
	}
	var entries []entry
	for rows.Next() {
		var e entry
		if err = rows.Scan(&e.id, &e.owner, &e.record, &e.local, &e.answer); err != nil {
			break
		}
		entries = append(entries, e)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		lease, _, _, err := escalationLease(tx, e.id)
		if err != nil {
			return nil, err
		}
		if phone {
			digest := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", e.record))
			requestKey := "phone-request:" + digest
			if lease.State == pb.LeaseState_LEASE_STATE_PENDING && seen[requestKey] == nil {
				seen[requestKey] = []byte{1}
				pending := &pb.PendingRequest{Record: e.record, SourceMacKeyId: e.owner}
				if e.local != nil {
					pending.LocalLease = lease
				}
				return workResponse(&pb.ApproverWork{Item: &pb.ApproverWork_Request{Request: pending}}), nil
			}
			if lease.State != pb.LeaseState_LEASE_STATE_PENDING && bytes.Equal(seen[requestKey], []byte{1}) {
				seen[requestKey] = []byte{2}
				return workResponse(&pb.ApproverWork{Item: &pb.ApproverWork_CancelledRequestDigestHex{CancelledRequestDigestHex: digest}}), nil
			}
			if (!terminal(lease) || seen["lease:"+e.id] != nil) && changed(seen, "lease:"+e.id, lease) {
				return workResponse(&pb.ApproverWork{Item: &pb.ApproverWork_Lease{Lease: lease}}), nil
			}
		} else if e.owner == p.approver {
			if lease.State == pb.LeaseState_LEASE_STATE_PENDING && len(e.answer) > 0 {
				answer := new(pb.SignedPhoneDecision)
				if err = proto.Unmarshal(e.answer, answer); err != nil {
					return nil, err
				}
				if changed(seen, "answer:"+e.id, answer) {
					return workResponse(&pb.ApproverWork{Item: &pb.ApproverWork_PhoneDecision{PhoneDecision: answer}}), nil
				}
			}
			if e.local != nil {
				for _, kind := range []string{"local-revoke", "local-clear"} {
					action := new(pb.LocalLeaseAction)
					err = get(tx, kind, e.id, action)
					if err == nil && changed(seen, kind+":"+e.id, action) {
						return workResponse(&pb.ApproverWork{Item: &pb.ApproverWork_LocalLeaseAction{LocalLeaseAction: action}}), nil
					}
					if err != nil && !errors.Is(err, sql.ErrNoRows) {
						return nil, err
					}
				}
			}
		}
	}
	return nil, nil
}
