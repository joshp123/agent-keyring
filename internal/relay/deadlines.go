// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relay

import (
	"context"
	"database/sql"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"google.golang.org/protobuf/proto"
)

// The sole timer covers lease deadlines, retry retention, setup expiry and
// notification retries. With no deadline it sleeps until a committed change.
func (s *Server) maintain(ctx context.Context) {
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	defer timer.Stop()
	for {
		s.Store.mu.Lock()
		next, err := s.maintenance()
		wake := s.Store.changed
		s.Store.mu.Unlock()
		if err != nil {
			s.Log.Error("relay deadline maintenance failed", "error", err)
			next = time.Now().Add(5 * time.Second)
		}
		if s.Push != nil {
			select {
			case s.pushReady <- struct{}{}:
			default:
			}
		}
		var deadline <-chan time.Time
		if !next.IsZero() {
			timer.Reset(max(time.Until(next), 0))
			deadline = timer.C
		}
		select {
		case <-ctx.Done():
			return
		case <-wake:
			if deadline != nil && !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
		case <-deadline:
		}
	}
}
func (s *Server) maintenance() (time.Time, error) {
	tx, before, err := s.Store.begin()
	if err != nil {
		return time.Time{}, err
	}
	defer tx.Rollback()
	if err = s.expire(tx); err != nil {
		return time.Time{}, err
	}
	now := time.Now().Unix()
	rows, err := tx.Query("SELECT owner,request,lease FROM local_leases WHERE deadline<=?", now)
	if err != nil {
		return time.Time{}, err
	}
	type local struct {
		owner  string
		record []byte
		lease  *pb.Lease
	}
	var expired []local
	for rows.Next() {
		var owner string
		var record, raw []byte
		if err = rows.Scan(&owner, &record, &raw); err != nil {
			break
		}
		lease := new(pb.Lease)
		if err = proto.Unmarshal(raw, lease); err != nil {
			break
		}
		state := pb.LeaseState_LEASE_STATE_EXPIRED
		if lease.State == pb.LeaseState_LEASE_STATE_PENDING {
			state = pb.LeaseState_LEASE_STATE_UNANSWERED
		}
		end(lease, state)
		expired = append(expired, local{owner, record, lease})
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return time.Time{}, err
	}
	for _, local := range expired {
		if err = saveLocalLease(tx, local.owner, local.record, local.lease); err != nil {
			return time.Time{}, err
		}
	}
	for _, query := range []string{
		"DELETE FROM aliases WHERE lease IN (SELECT id FROM leases WHERE delete_after<=?)",
		"DELETE FROM leases WHERE delete_after<=?",
		"DELETE FROM objects WHERE kind IN ('local-revoke','local-clear') AND id IN (SELECT id FROM local_leases WHERE delete_after<=?)",
		"DELETE FROM local_leases WHERE delete_after<=?",
		"DELETE FROM enrolments WHERE expires<=?",
		"DELETE FROM pairings WHERE expires<=?",
	} {
		if _, err = tx.Exec(query, now); err != nil {
			return time.Time{}, err
		}
	}
	var next sql.NullInt64
	query := `SELECT MIN(deadline) FROM (
 SELECT MIN(deadline) deadline FROM leases WHERE deadline IS NOT NULL UNION ALL
 SELECT MIN(delete_after) FROM leases WHERE delete_after IS NOT NULL UNION ALL
 SELECT MIN(deadline) FROM local_leases WHERE deadline IS NOT NULL UNION ALL
 SELECT MIN(delete_after) FROM local_leases WHERE delete_after IS NOT NULL UNION ALL
 SELECT MIN(expires) FROM enrolments WHERE expires IS NOT NULL UNION ALL
 SELECT MIN(expires) FROM pairings WHERE expires IS NOT NULL`
	if s.Push != nil {
		query += " UNION ALL SELECT MIN(p.retry_at) FROM push_attempts p JOIN phone_escalations e ON e.lease=p.lease WHERE p.sent=0 AND e.answer IS NULL AND p.retry_at>?"
	}
	query += ")"
	var args []any
	if s.Push != nil {
		args = append(args, now)
	}
	if err = tx.QueryRow(query, args...).Scan(&next); err != nil {
		return time.Time{}, err
	}
	if err = s.Store.commit(tx, before); err != nil {
		return time.Time{}, err
	}
	if next.Valid {
		return time.Unix(next.Int64, 0), nil
	}
	return time.Time{}, nil
}
