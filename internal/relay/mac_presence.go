// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package relay

import (
	"database/sql"
	"errors"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
)

func (s *Server) trackMacWatcher(p peer, request *pb.RelayWireRequest) (func(), error) {
	if request.GetWatchWork() == nil {
		return func() {}, nil
	}
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	tx, err := s.Store.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	p, err = authenticate(tx, p)
	if err != nil {
		return nil, err
	}
	_, keys, err := currentKeys(tx)
	if err != nil {
		return nil, err
	}
	if p.approver != request.GetWatchWork().ApproverKeyId || relaycrypto.Role(keys, keyByID(keys, p.approver)) != pb.ApproverRole_APPROVER_ROLE_MAC {
		return func() {}, nil
	}
	s.macWatchers[p.approver]++
	return func() { s.closeMacWatcher(p.approver) }, nil
}

func (s *Server) closeMacWatcher(id string) {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	s.macWatchers[id]--
	if s.macWatchers[id] > 0 {
		return
	}
	delete(s.macWatchers, id)
	tx, before, err := s.Store.begin()
	if err == nil {
		defer tx.Rollback()
		err = s.escalateOffline(tx)
		if err == nil {
			err = s.Store.commit(tx, before)
		}
	}
	if err != nil {
		s.Log.Error("cannot escalate requests after Mac disconnect", "error", err)
	}
}

func (s *Server) escalateOffline(tx *sql.Tx) error {
	_, keys, err := currentKeys(tx)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, key := range keys.Keys {
		if relaycrypto.Role(keys, key) == pb.ApproverRole_APPROVER_ROLE_MAC && s.macWatchers[key.KeyId] > 0 {
			return nil
		}
	}
	_, config, err := configuration(tx)
	if err != nil {
		return err
	}
	leases, err := queryLeases(tx, "SELECT lease FROM leases WHERE deadline IS NOT NULL AND id NOT IN (SELECT lease FROM phone_escalations)")
	if err != nil {
		return err
	}
	for _, lease := range leases {
		if lease.State != pb.LeaseState_LEASE_STATE_PENDING || loginByID(config, lease.LoginId).GetRule() != pb.AccessRule_ACCESS_RULE_ASK {
			continue
		}
		_, record, err := loadLease(tx, lease.LeaseId)
		if err != nil {
			return err
		}
		if err = escalate(tx, peer{approver: keys.RuleOwnerKeyId}, &pb.PhoneEscalation{LeaseId: lease.LeaseId, Record: record}); err != nil {
			return err
		}
	}
	return nil
}
