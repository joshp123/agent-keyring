// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relay

import (
	"bytes"
	"context"
	"crypto/tls"
	"database/sql"
	"encoding/hex"
	"errors"
	"log/slog"
	"net"
	"sync"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/apns"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

type Server struct {
	Push        *apns.Sender
	Store       *Store
	Certificate tls.Certificate
	Lookup      NodeLookup
	Log         *slog.Logger
}
type peer struct {
	spki                []byte
	node                Node
	recipient, approver string
}

func (s *Server) Serve(ctx context.Context, listener net.Listener) error {
	if s.Lookup == nil {
		return errors.New("Tailscale node lookup is required")
	}
	if s.Log == nil {
		s.Log = slog.Default()
	}
	stop := context.AfterFunc(ctx, func() { listener.Close() })
	defer stop()
	var active sync.WaitGroup
	if s.Push != nil {
		active.Add(1)
		go func() { defer active.Done(); s.sendPushes(ctx) }()
	}
	defer active.Wait()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		active.Add(1)
		go func() { defer active.Done(); s.serveConnection(ctx, conn) }()
	}
}
func (s *Server) serveConnection(ctx context.Context, raw net.Conn) {
	defer raw.Close()
	stop := context.AfterFunc(ctx, func() { raw.Close() })
	defer stop()
	raw.SetDeadline(time.Now().Add(15 * time.Second))
	conn := tls.Server(raw, &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{s.Certificate}, ClientAuth: tls.RequireAnyClientCert})
	if err := conn.HandshakeContext(ctx); err != nil {
		return
	}
	certificates := conn.ConnectionState().PeerCertificates
	if len(certificates) != 1 {
		return
	}
	if time.Now().Before(certificates[0].NotBefore) || time.Now().After(certificates[0].NotAfter) {
		return
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	node, err := s.Lookup(lookupCtx, raw.RemoteAddr().String())
	cancel()
	if err != nil {
		authority.WriteFrame(conn, wireError(denied("Cannot verify the connecting Tailscale node.")))
		return
	}
	p := peer{spki: certificates[0].RawSubjectPublicKeyInfo, node: node}
	request := new(pb.RelayWireRequest)
	if authority.ReadFrame(conn, request) != nil {
		return
	}
	// One request per connection. Polling is only for durable stream snapshots;
	// there is no second wire protocol and no in-memory-only queue.
	raw.SetReadDeadline(time.Time{})
	disconnected := make(chan struct{})
	go func() {
		// No second method is valid on this connection. Reading detects a
		// disconnected idle watcher without waiting for another work item.
		var extra [1]byte
		conn.Read(extra[:])
		close(disconnected)
		raw.Close()
	}()
	seen := map[string][]byte{}
	for {
		response, more, err := s.dispatch(p, request, seen)
		if err != nil {
			s.Log.Warn("relay request refused", "error", err)
			response = wireError(err)
			more = false
		}
		if response != nil {
			raw.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if authority.WriteFrame(conn, response) != nil {
				return
			}
		}
		if !more {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-disconnected:
			return
		case <-time.After(250 * time.Millisecond):
		}
	}
}
func (s *Server) dispatch(p peer, r *pb.RelayWireRequest, seen map[string][]byte) (response *pb.RelayWireResponse, more bool, err error) {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	tx, err := s.Store.db.Begin()
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback()
	if err = s.expire(tx); err != nil {
		return nil, false, err
	}
	p, err = authenticate(tx, p)
	if err != nil {
		return nil, false, err
	}
	switch request := r.Request.(type) {
	case *pb.RelayWireRequest_Enrol:
		response, more, err = s.enrol(tx, p, request.Enrol, seen)
	case *pb.RelayWireRequest_PairApprover:
		response, more, err = s.pair(tx, p, request.PairApprover, seen)
	case *pb.RelayWireRequest_ConfirmPairing:
		response, err = s.confirm(tx, p, request.ConfirmPairing)
	default:
		if p.recipient == "" && p.approver == "" {
			return nil, false, denied("This TLS key is not enrolled. Run enrol first.")
		}
		switch request := r.Request.(type) {
		case *pb.RelayWireRequest_Client:
			if p.recipient == "" {
				err = denied("This connection is not an enrolled receiver.")
				break
			}
			response, more, err = s.client(tx, p, request.Client, seen)
		case *pb.RelayWireRequest_GetApproverKeys:
			keys, _, e := currentKeys(tx)
			err = e
			response = &pb.RelayWireResponse{Response: &pb.RelayWireResponse_ApproverKeys{ApproverKeys: keys}, EndOfStream: true}
		case *pb.RelayWireRequest_GetApproverKeyChain:
			chain := new(pb.ApproverKeyChain)
			rows, e := tx.Query("SELECT value FROM objects WHERE kind='keychain' AND id>? ORDER BY id", revisionID(request.GetApproverKeyChain.FromRevision))
			if e != nil {
				err = e
				break
			}
			for rows.Next() {
				var data []byte
				if err = rows.Scan(&data); err != nil {
					break
				}
				keys := new(pb.SignedApproverKeySet)
				if err = proto.Unmarshal(data, keys); err != nil {
					break
				}
				chain.KeySets = append(chain.KeySets, keys)
			}
			if err == nil {
				err = rows.Err()
			}
			rows.Close()
			response = &pb.RelayWireResponse{Response: &pb.RelayWireResponse_ApproverKeyChain{ApproverKeyChain: chain}, EndOfStream: true}
		case *pb.RelayWireRequest_GetIndex:
			value := new(pb.SignedIndex)
			err = get(tx, "current", "index", value)
			if errors.Is(err, sql.ErrNoRows) {
				err = missing("No login index published yet.")
			}
			response = &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Index{Index: value}, EndOfStream: true}
		case *pb.RelayWireRequest_GetAutomaticGrant:
			grant := new(pb.SignedAutomaticGrant)
			err = get(tx, "current", "grant", grant)
			if errors.Is(err, sql.ErrNoRows) {
				err = missing("No Automatic authority has been published.")
			}
			response = &pb.RelayWireResponse{Response: &pb.RelayWireResponse_AutomaticGrant{AutomaticGrant: grant}, EndOfStream: true}
		default:
			if p.approver == "" {
				err = denied("Only a pinned approver may call this method.")
				break
			}
			response, more, err = s.approver(tx, p, r, seen)
		}
	}
	if err != nil {
		return nil, false, err
	}
	if response != nil {
		for _, lease := range []*pb.Lease{response.GetClient().GetLease(), response.GetDecision().GetLease(), response.GetLease(), response.GetWork().GetLease()} {
			if err = attachSignedDenial(tx, lease); err != nil {
				return nil, false, err
			}
		}
	}
	err = tx.Commit()
	return response, more, err
}
func authenticate(tx *sql.Tx, p peer) (peer, error) {
	_, keys, err := currentKeys(tx)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return p, err
	}
	for _, key := range keys.GetKeys() {
		if bytes.Equal(key.TlsPublicKey, p.spki) {
			// Pairing records retain the observed tailnet node for pinned approvers too.
			var node string
			if err := tx.QueryRow("SELECT node FROM pairings WHERE id=?", key.KeyId).Scan(&node); err != nil {
				return p, err
			}
			if node != p.node.ID {
				return p, denied("Approver TLS key belongs to a different Tailscale node.")
			}
			p.approver = key.KeyId
			return p, nil
		}
	}
	var id, node string
	var state int
	err = tx.QueryRow("SELECT id,node,state FROM enrolments WHERE spki=?", p.spki).Scan(&id, &node, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return p, nil
	}
	if err != nil {
		return p, err
	}
	if node != p.node.ID {
		return p, denied("Receiver TLS key belongs to a different Tailscale node.")
	}
	if state == int(pb.EnrolmentChoice_ENROLMENT_CHOICE_REVOKE) {
		return p, denied("This machine has been revoked. Enrol with new keys.")
	}
	if state == int(pb.EnrolmentChoice_ENROLMENT_CHOICE_APPROVE) {
		p.recipient = id
	}
	return p, nil
}
func changed(seen map[string][]byte, id string, message proto.Message) bool {
	data := marshal(message)
	if bytes.Equal(seen[id], data) {
		return false
	}
	seen[id] = data
	return true
}
func hashID(data []byte) string { return hex.EncodeToString(relaycrypto.Hash(data)) }
