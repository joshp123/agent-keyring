// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relay

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/apns"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
)

const (
	pushPending = iota
	pushAccepted
	pushRefused
)

type pushJob struct {
	lease, phone, collapse string
	registration           *pb.PushRegistration
	expires                int64
}

func (s *Server) pushJobs() ([]pushJob, error) {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	tx, err := s.Store.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	_, keys, err := currentKeys(tx)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	rows, err := tx.Query("SELECT lease FROM phone_escalations WHERE answer IS NULL")
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			break
		}
		ids = append(ids, id)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, err
	}
	var jobs []pushJob
	for _, id := range ids {
		lease, record, _, err := escalationLease(tx, id)
		if err != nil {
			return nil, err
		}
		if lease.State != pb.LeaseState_LEASE_STATE_PENDING || lease.PendingUntilUnixSeconds <= time.Now().Unix() {
			continue
		}
		for _, key := range keys.Keys {
			if relaycrypto.Role(keys, key) != pb.ApproverRole_APPROVER_ROLE_PHONE {
				continue
			}
			registration := new(pb.PushRegistration)
			err = get(tx, "push", key.KeyId, registration)
			if errors.Is(err, sql.ErrNoRows) {
				continue
			}
			if err != nil {
				return nil, err
			}
			if _, err = tx.Exec("INSERT INTO push_attempts(lease,phone) VALUES(?,?) ON CONFLICT DO NOTHING", id, key.KeyId); err != nil {
				return nil, err
			}
			var sent int
			var retry int64
			if err = tx.QueryRow("SELECT sent,retry_at FROM push_attempts WHERE lease=? AND phone=?", id, key.KeyId).Scan(&sent, &retry); err != nil {
				return nil, err
			}
			if sent == pushPending && retry <= time.Now().Unix() {
				jobs = append(jobs, pushJob{id, key.KeyId, hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", record)), registration, lease.PendingUntilUnixSeconds})
			}
		}
	}
	return jobs, tx.Commit()
}
func (s *Server) sendPushes(ctx context.Context) {
	for {
		jobs, err := s.pushJobs()
		if err != nil {
			s.Log.Error("cannot load pending notifications", "error", err)
		}
		for _, job := range jobs {
			// Recheck after earlier network calls: an answer may have arrived meanwhile.
			current, err := s.pushJobs()
			if err != nil {
				break
			}
			pending := false
			for _, candidate := range current {
				if candidate.lease == job.lease && candidate.phone == job.phone {
					job = candidate
					pending = true
					break
				}
			}
			if !pending {
				continue
			}
			result, sendErr := s.Push.Send(ctx, job.registration.ApnsDeviceToken, job.registration.ApnsProduction, job.collapse, job.expires)
			if sendErr != nil {
				s.Log.Warn("phone notification not accepted", "lease", job.lease, "status", result.Status, "reason", result.Reason, "error", sendErr)
			}
			if err = s.recordPush(job, result, sendErr); err != nil {
				s.Log.Error("cannot save notification outcome", "error", err)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}
func (s *Server) recordPush(job pushJob, result apns.Result, sendErr error) error {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	tx, err := s.Store.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	sent := pushPending
	retry := result.RetryAt.Unix()
	if sendErr == nil {
		sent = pushAccepted
	} else if result.Status == 0 {
		retry = time.Now().Add(5 * time.Second).Unix()
	} else if result.RetryAt.IsZero() {
		sent = pushRefused
	}
	current := new(pb.PushRegistration)
	if sendErr != nil && get(tx, "push", job.phone, current) == nil && !bytes.Equal(marshal(current), marshal(job.registration)) {
		sent = pushPending
		retry = 0
	}
	if result.InvalidToken {
		if _, err = tx.Exec("DELETE FROM objects WHERE kind='push' AND id=? AND value=?", job.phone, marshal(job.registration)); err != nil {
			return err
		}
	}
	if _, err = tx.Exec("UPDATE push_attempts SET sent=?,retry_at=? WHERE lease=? AND phone=?", sent, retry, job.lease, job.phone); err != nil {
		return err
	}
	return tx.Commit()
}
