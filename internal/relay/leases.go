// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relay

import (
	"database/sql"
	"encoding/hex"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"google.golang.org/protobuf/proto"
)

func loadLease(tx *sql.Tx, id string) (*pb.Lease, []byte, error) {
	var leaseBytes, record []byte
	err := tx.QueryRow("SELECT lease,request FROM leases WHERE id=?", id).Scan(&leaseBytes, &record)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, missing("Lease not found.")
	}
	if err != nil {
		return nil, nil, err
	}
	lease := new(pb.Lease)
	err = proto.Unmarshal(leaseBytes, lease)
	return lease, record, err
}
func saveLease(tx *sql.Tx, l *pb.Lease) error {
	_, err := tx.Exec("UPDATE leases SET lease=? WHERE id=?", marshal(l), l.LeaseId)
	return err
}
func terminal(l *pb.Lease) bool {
	return l.State != pb.LeaseState_LEASE_STATE_PENDING && l.State != pb.LeaseState_LEASE_STATE_ACTIVE
}
func end(l *pb.Lease, state pb.LeaseState) { l.State = state; l.EndedAtUnixSeconds = time.Now().Unix() }
func allLeases(tx *sql.Tx) ([]*pb.Lease, error) {
	rows, err := tx.Query("SELECT lease FROM leases ORDER BY rowid")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []*pb.Lease
	for rows.Next() {
		var data []byte
		if err = rows.Scan(&data); err != nil {
			return nil, err
		}
		l := new(pb.Lease)
		if err = proto.Unmarshal(data, l); err != nil {
			return nil, err
		}
		result = append(result, l)
	}
	return result, rows.Err()
}
func (s *Server) expire(tx *sql.Tx) error {
	leases, err := allLeases(tx)
	if err != nil {
		return err
	}
	now := time.Now().Unix()
	for _, l := range leases {
		if l.State == pb.LeaseState_LEASE_STATE_PENDING && now >= l.PendingUntilUnixSeconds {
			end(l, pb.LeaseState_LEASE_STATE_UNANSWERED)
			if err = saveLease(tx, l); err != nil {
				return err
			}
		}
		if l.State == pb.LeaseState_LEASE_STATE_ACTIVE && now >= l.NotAfterUnixSeconds {
			end(l, pb.LeaseState_LEASE_STATE_EXPIRED)
			if err = saveLease(tx, l); err != nil {
				return err
			}
		}
	}
	return nil
}
func ownedLease(tx *sql.Tx, p peer, id string) (*pb.Lease, error) {
	l, _, err := loadLease(tx, id)
	if err != nil {
		return nil, err
	}
	if l.GetRecipient().GetRecipientId() != p.recipient {
		return nil, denied("Lease belongs to a different recipient.")
	}
	return l, nil
}
func (s *Server) client(tx *sql.Tx, p peer, r *pb.WireRequest, seen map[string][]byte) (*pb.RelayWireResponse, bool, error) {
	if r == nil {
		return nil, false, invalid("Missing client method.")
	}
	var result *pb.WireResponse
	more := false
	switch request := r.Request.(type) {
	case *pb.WireRequest_FindLogins:
		idx, err := index(tx)
		if err != nil {
			return nil, false, err
		}
		found := &pb.FindLoginsResponse{MirrorRefreshedUnixSeconds: idx.MirrorRefreshedUnixSeconds}
		query := strings.ToLower(request.FindLogins.Query)
		for _, login := range idx.Logins {
			if strings.Contains(strings.ToLower(login.Title+" "+login.Account+" "+strings.Join(login.Sites, " ")), query) {
				found.Logins = append(found.Logins, login)
			}
		}
		result = &pb.WireResponse{Response: &pb.WireResponse_Logins{Logins: found}}
	case *pb.WireRequest_RequestLease:
		lease, err := s.requestLease(tx, p, request.RequestLease)
		if err != nil {
			return nil, false, err
		}
		result = &pb.WireResponse{Response: &pb.WireResponse_Lease{Lease: lease}}
	case *pb.WireRequest_GetLease, *pb.WireRequest_WatchLease, *pb.WireRequest_EndLease:
		var id string
		switch v := r.Request.(type) {
		case *pb.WireRequest_GetLease:
			id = v.GetLease.LeaseId
		case *pb.WireRequest_WatchLease:
			id = v.WatchLease.LeaseId
		case *pb.WireRequest_EndLease:
			id = v.EndLease.LeaseId
		}
		lease, err := ownedLease(tx, p, id)
		if err != nil {
			return nil, false, err
		}
		if r.GetEndLease() != nil && !terminal(lease) {
			if lease.State == pb.LeaseState_LEASE_STATE_PENDING {
				end(lease, pb.LeaseState_LEASE_STATE_CANCELLED)
			} else {
				end(lease, pb.LeaseState_LEASE_STATE_RELEASED)
			}
			if err = saveLease(tx, lease); err != nil {
				return nil, false, err
			}
		}
		more = r.GetWatchLease() != nil && !terminal(lease)
		if r.GetWatchLease() != nil && !changed(seen, "lease", lease) {
			return nil, more, nil
		}
		result = &pb.WireResponse{Response: &pb.WireResponse_Lease{Lease: lease}}
	case *pb.WireRequest_BeginOperation:
		value, err := s.begin(tx, p, request.BeginOperation)
		if err != nil {
			return nil, false, err
		}
		result = &pb.WireResponse{Response: &pb.WireResponse_BeginOperation{BeginOperation: value}}
	case *pb.WireRequest_FinishOperation:
		value, err := s.finish(tx, p, request.FinishOperation)
		if err != nil {
			return nil, false, err
		}
		result = &pb.WireResponse{Response: &pb.WireResponse_Operation{Operation: value}}
	case *pb.WireRequest_GetOperation:
		value, err := s.operation(tx, p, request.GetOperation)
		if err != nil {
			return nil, false, err
		}
		result = &pb.WireResponse{Response: &pb.WireResponse_GetOperation_{GetOperation_: value}}
	default:
		return nil, false, invalid("The relay does not execute browser or program operations.")
	}
	result.EndOfStream = !more
	return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Client{Client: result}, EndOfStream: !more}, more, nil
}
func (s *Server) requestLease(tx *sql.Tx, p peer, r *pb.RequestLeaseRequest) (*pb.Lease, error) {
	if r == nil || r.LoginId == "" || r.TaskRef == "" || r.RequestId == "" || r.RecipientId != p.recipient {
		return nil, invalid("Name a login, task, request ID and this enrolled recipient.")
	}
	switch r.Purpose {
	case pb.Purpose_PURPOSE_BROWSER_SIGN_IN, pb.Purpose_PURPOSE_AGENT_PROCESS:
		if r.Program != nil {
			return nil, invalid("Program is only valid for program purpose.")
		}
	case pb.Purpose_PURPOSE_PROGRAM:
		if r.Program == nil || !filepath.IsAbs(r.Program.Executable) {
			return nil, invalid("Program purpose requires an absolute executable path.")
		}
	default:
		return nil, invalid("Unknown lease purpose.")
	}
	var id string
	var original []byte
	err := tx.QueryRow("SELECT lease,request FROM aliases WHERE recipient=? AND id=?", p.recipient, r.RequestId).Scan(&id, &original)
	if err == nil {
		before := new(pb.RequestLeaseRequest)
		if proto.Unmarshal(original, before) != nil {
			return nil, errors.New("corrupt request alias")
		}
		if !proto.Equal(r, before) {
			return nil, conflict("Request ID already names different contents.")
		}
		l, _, err := loadLease(tx, id)
		return l, err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	leases, err := allLeases(tx)
	if err != nil {
		return nil, err
	}
	for _, l := range leases {
		if l.Recipient.RecipientId == p.recipient && l.LoginId == r.LoginId && l.TaskRef == r.TaskRef && l.Purpose == r.Purpose && !terminal(l) {
			if !proto.Equal(l.Program, r.Program) {
				return nil, conflict("End the existing lease before changing its program.")
			}
			_, err = tx.Exec("INSERT INTO aliases VALUES(?,?,?,?)", p.recipient, r.RequestId, l.LeaseId, marshal(r))
			return l, err
		}
	}
	idx, err := index(tx)
	if err != nil {
		return nil, err
	}
	login := loginByID(idx, r.LoginId)
	if login == nil {
		return nil, missing("Login is not in the published index.")
	}
	var enrolledBytes []byte
	if err = tx.QueryRow("SELECT record FROM enrolments WHERE id=?", p.recipient).Scan(&enrolledBytes); err != nil {
		return nil, err
	}
	enrolled := new(pb.EnrolmentRecord)
	if err = proto.Unmarshal(enrolledBytes, enrolled); err != nil {
		return nil, err
	}
	now := time.Now().Unix()
	l := &pb.Lease{LeaseId: newID(), LoginId: r.LoginId, TaskRef: r.TaskRef, Purpose: r.Purpose, Reason: r.Reason, Program: r.Program, State: pb.LeaseState_LEASE_STATE_PENDING, RequestedAtUnixSeconds: now, PendingUntilUnixSeconds: now + 600, Recipient: &pb.Recipient{RecipientId: p.recipient, MachineLabel: enrolled.MachineLabel, ClientLabel: enrolled.ClientLabel}, Sites: login.Sites}
	for _, old := range leases {
		if old.State == pb.LeaseState_LEASE_STATE_DENIED && old.Recipient.RecipientId == p.recipient && old.LoginId == r.LoginId && old.RetryNotBeforeUnixSeconds > now {
			end(l, pb.LeaseState_LEASE_STATE_DENIED)
			l.RetryNotBeforeUnixSeconds = old.RetryNotBeforeUnixSeconds
		}
	}
	if login.Rule == pb.AccessRule_ACCESS_RULE_BLOCKED {
		end(l, pb.LeaseState_LEASE_STATE_DENIED)
		l.Reply = "This login is blocked."
	}
	record := &pb.RequestRecord{LeaseId: l.LeaseId, RequestId: r.RequestId, LoginId: r.LoginId, TaskRef: r.TaskRef, Purpose: r.Purpose, Reason: r.Reason, AgentLabel: enrolled.ClientLabel, RecipientId: p.recipient, Program: r.Program, CreatedUnixSeconds: now, PendingUntilUnixSeconds: now + 600, TailscaleNodeName: p.node.Name, TailscaleAddress: p.node.Address, Automatic: login.Rule == pb.AccessRule_ACCESS_RULE_AUTOMATIC}
	if _, err = tx.Exec("INSERT INTO leases VALUES(?,?,?,?,NULL,NULL)", l.LeaseId, p.recipient, marshal(record), marshal(l)); err != nil {
		return nil, err
	}
	_, err = tx.Exec("INSERT INTO aliases VALUES(?,?,?,?)", p.recipient, r.RequestId, l.LeaseId, marshal(r))
	return l, err
}
func retryKey(id string, digest []byte) (string, error) {
	if id != "" {
		return "id:" + id, nil
	}
	if len(digest) != 32 {
		return "", invalid("Operation requires a SHA-256 digest.")
	}
	return "sha256:" + hex.EncodeToString(digest), nil
}
func (s *Server) operation(tx *sql.Tx, p peer, r *pb.GetOperationRequest) (*pb.GetOperationResponse, error) {
	if _, err := ownedLease(tx, p, r.LeaseId); err != nil {
		return nil, err
	}
	key, err := retryKey(r.RequestId, r.OperationDigest)
	if err != nil {
		return nil, err
	}
	var data []byte
	err = tx.QueryRow("SELECT record FROM operations WHERE lease=? AND retry=?", r.LeaseId, key).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return &pb.GetOperationResponse{}, nil
	}
	if err != nil {
		return nil, err
	}
	record := new(pb.OperationRecord)
	if err = proto.Unmarshal(data, record); err != nil {
		return nil, err
	}
	return &pb.GetOperationResponse{Operation: record}, nil
}
func (s *Server) begin(tx *sql.Tx, p peer, r *pb.BeginOperationRequest) (*pb.BeginOperationResponse, error) {
	l, err := ownedLease(tx, p, r.LeaseId)
	if err != nil {
		return nil, err
	}
	if len(r.OperationDigest) != 32 {
		return nil, invalid("Operation requires a SHA-256 digest.")
	}
	key, err := retryKey(r.RequestId, r.OperationDigest)
	if err != nil {
		return nil, err
	}
	r = proto.Clone(r).(*pb.BeginOperationRequest)
	slices.Sort(r.Fields)
	var requestBytes, recordBytes []byte
	err = tx.QueryRow("SELECT request,record FROM operations WHERE lease=? AND retry=?", l.LeaseId, key).Scan(&requestBytes, &recordBytes)
	if err == nil {
		old := new(pb.BeginOperationRequest)
		if err = proto.Unmarshal(requestBytes, old); err != nil {
			return nil, err
		}
		if !proto.Equal(r, old) {
			return nil, conflict("Operation retry has different contents.")
		}
		record := new(pb.OperationRecord)
		if err = proto.Unmarshal(recordBytes, record); err != nil {
			return nil, err
		}
		return &pb.BeginOperationResponse{OperationId: record.OperationId, Result: &pb.BeginOperationResponse_AlreadyStarted{AlreadyStarted: record}}, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if l.State != pb.LeaseState_LEASE_STATE_ACTIVE {
		return nil, denied("Lease is not active.")
	}
	idx, err := index(tx)
	if err != nil {
		return nil, err
	}
	login := loginByID(idx, l.LoginId)
	if login == nil || login.Rule == pb.AccessRule_ACCESS_RULE_BLOCKED {
		return nil, denied("Current login policy refuses delivery.")
	}
	if (r.Kind == pb.OperationKind_OPERATION_KIND_FILL && l.Purpose != pb.Purpose_PURPOSE_BROWSER_SIGN_IN) || (r.Kind == pb.OperationKind_OPERATION_KIND_EXECUTE_PROGRAM && l.Purpose != pb.Purpose_PURPOSE_PROGRAM) || (r.Kind == pb.OperationKind_OPERATION_KIND_READ && l.Purpose != pb.Purpose_PURPOSE_AGENT_PROCESS) || r.Kind < 1 || r.Kind > 3 {
		return nil, denied("Operation does not match the approved purpose.")
	}
	if len(r.Fields) == 0 || (r.Kind != pb.OperationKind_OPERATION_KIND_FILL && len(r.Fields) != 1) {
		return nil, invalid("Select the fields required by this operation.")
	}
	for i, field := range r.Fields {
		if field < 1 || field > 3 || (i > 0 && field == r.Fields[i-1]) {
			return nil, invalid("Unknown or duplicate credential field.")
		}
		if field == pb.CredentialField_CREDENTIAL_FIELD_ONE_TIME_CODE && !login.HasOneTimeCode {
			return nil, denied("This login has no one-time code.")
		}
	}
	var decisionBytes, bundleBytes, approvedRecord []byte
	if err = tx.QueryRow("SELECT decision,bundle,request FROM leases WHERE id=?", l.LeaseId).Scan(&decisionBytes, &bundleBytes, &approvedRecord); err != nil {
		return nil, err
	}
	decision := new(pb.SignedDecision)
	bundle := new(pb.SealedBundle)
	if err = proto.Unmarshal(decisionBytes, decision); err != nil {
		return nil, err
	}
	if err = proto.Unmarshal(bundleBytes, bundle); err != nil {
		return nil, err
	}
	record := &pb.OperationRecord{OperationId: newID(), Kind: r.Kind, StartedUnixSeconds: time.Now().Unix()}
	if _, err = tx.Exec("INSERT INTO operations VALUES(?,?,?,?)", l.LeaseId, key, marshal(r), marshal(record)); err != nil {
		return nil, err
	}
	decision.Bundle = nil
	return &pb.BeginOperationResponse{OperationId: record.OperationId, Result: &pb.BeginOperationResponse_Sealed{Sealed: &pb.SealedDelivery{Decision: decision, Bundle: bundle, RequestRecord: approvedRecord}}}, nil
}
func (s *Server) finish(tx *sql.Tx, p peer, r *pb.FinishOperationRequest) (*pb.OperationRecord, error) {
	if _, err := ownedLease(tx, p, r.LeaseId); err != nil {
		return nil, err
	}
	rows, err := tx.Query("SELECT retry,record FROM operations WHERE lease=?", r.LeaseId)
	if err != nil {
		return nil, err
	}
	var key string
	var record *pb.OperationRecord
	for rows.Next() {
		var retry string
		var data []byte
		if err = rows.Scan(&retry, &data); err != nil {
			break
		}
		candidate := new(pb.OperationRecord)
		if err = proto.Unmarshal(data, candidate); err != nil {
			break
		}
		if candidate.OperationId == r.OperationId {
			key = retry
			record = candidate
			break
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, err
	}
	if record == nil {
		return nil, missing("Operation not found.")
	}
	next := proto.Clone(record).(*pb.OperationRecord)
	switch outcome := r.Outcome.(type) {
	case *pb.FinishOperationRequest_Fill:
		if record.Kind != pb.OperationKind_OPERATION_KIND_FILL || outcome.Fill < 1 || outcome.Fill > 9 {
			return nil, invalid("Invalid fill outcome.")
		}
		next.Outcome = &pb.OperationRecord_Fill{Fill: outcome.Fill}
	case *pb.FinishOperationRequest_Program:
		if record.Kind != pb.OperationKind_OPERATION_KIND_EXECUTE_PROGRAM || outcome.Program < 1 || outcome.Program > 5 || (outcome.Program == pb.ProgramOutcome_PROGRAM_OUTCOME_EXITED) != (r.ExitCode != nil) {
			return nil, invalid("Invalid program outcome or exit status.")
		}
		next.Outcome = &pb.OperationRecord_Program{Program: outcome.Program}
		next.ExitCode = r.ExitCode
	case *pb.FinishOperationRequest_ReadDelivered:
		if record.Kind != pb.OperationKind_OPERATION_KIND_READ {
			return nil, invalid("Invalid read outcome.")
		}
		next.Outcome = &pb.OperationRecord_ReadDelivered{ReadDelivered: outcome.ReadDelivered}
	default:
		return nil, invalid("Missing operation outcome.")
	}
	if record.Kind != pb.OperationKind_OPERATION_KIND_EXECUTE_PROGRAM && r.ExitCode != nil {
		return nil, invalid("Only program outcomes have an exit status.")
	}
	if record.Outcome != nil {
		if !proto.Equal(record, next) {
			return nil, conflict("Operation result was already recorded.")
		}
		return record, nil
	}
	_, err = tx.Exec("UPDATE operations SET record=? WHERE lease=? AND retry=?", marshal(next), r.LeaseId, key)
	return next, err
}

// attachSignedDenial reconstructs the response envelope from the exact durable
// upload. It is never a new signature or a proof for a suppression-created lease.
func attachSignedDenial(tx *sql.Tx, lease *pb.Lease) error {
	if lease == nil {
		return nil
	}
	lease.SignedDenial = nil
	if lease.State != pb.LeaseState_LEASE_STATE_DENIED || lease.Reply == "" {
		return nil
	}
	var decisionBytes, record []byte
	if err := tx.QueryRow("SELECT decision,request FROM leases WHERE id=?", lease.LeaseId).Scan(&decisionBytes, &record); err != nil {
		return err
	}
	if len(decisionBytes) == 0 {
		return nil
	}
	decision := new(pb.SignedDecision)
	if err := proto.Unmarshal(decisionBytes, decision); err != nil {
		return err
	}
	statement := new(pb.DecisionStatement)
	if err := proto.Unmarshal(decision.Statement, statement); err != nil {
		return err
	}
	if statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN && statement.Choice == pb.DecisionChoice_DECISION_CHOICE_DENY && decision.Reply != "" {
		decision.Bundle = nil
		lease.SignedDenial = &pb.SealedDelivery{Decision: decision, RequestRecord: record}
	}
	return nil
}
