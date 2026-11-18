// Written by AI on 2026.11.18 by model claude opus 5.5.
package relay

import (
	"bytes"
	"context"
	"log/slog"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/keyring"
)

// publishMembers accepts the next list of devices and machines. The very
// first comes from a device it lists, over that device's own connection.
func (s *Server) publishMembers(who caller, document *pb.Signed) error {
	current, _ := s.Store.documents()
	next, err := keyring.VerifiedMembers(document, current)
	if err != nil {
		return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "Members refused: "+err.Error())
	}
	if !bytes.Equal(next.RelayTlsPublicKey, s.ownSPKI()) {
		return fail(pb.ErrorCode_ERROR_CODE_INVALID, "These members name a different relay.")
	}
	if current == nil {
		listed := false
		for _, d := range next.Devices {
			listed = listed || (len(d.TlsPublicKey) > 0 && bytes.Equal(d.TlsPublicKey, who.spki))
		}
		if !listed {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "The first members must come from a device they list.")
		}
	} else if who.device == nil {
		return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "Only a device may change the members.")
	}
	return s.Store.update(func(data *saved) error {
		data.Members = marshal(document)
		data.MembersHistory = append(data.MembersHistory, data.Members)
		s.Store.members = next
		known := map[string]bool{}
		for _, d := range next.Devices {
			known[d.KeyId] = true
		}
		for _, m := range next.Machines {
			known[m.MachineId] = true
		}
		for opener := range data.Sealed { // A removed device or machine keeps nothing here.
			if !known[opener] {
				delete(data.Sealed, opener)
			}
		}
		for id, j := range data.Joins {
			if j.State == pb.JoinState_JOIN_STATE_WAITING && known[id] {
				j.State = pb.JoinState_JOIN_STATE_APPROVED
				slog.Info("join approved", "joiner", id)
			}
		}
		return nil
	})
}

func (s *Server) publishCatalogue(document *pb.Signed) error {
	members, current := s.Store.documents()
	next, err := keyring.VerifiedCatalogue(document, members, current)
	if err != nil {
		return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "Catalogue refused: "+err.Error())
	}
	return s.Store.update(func(data *saved) error {
		data.Catalogue = marshal(document)
		s.Store.catalogue = next
		return nil
	})
}

// publishSealedLogins adds or replaces each copy given, empties each opener
// cleared, and removes the machines' copies of each login withdrawn.
func (s *Server) publishSealedLogins(batch *pb.SealedLogins) error {
	members, catalogue := s.Store.documents()
	byOpener := map[string]map[string][]byte{}
	for _, sealed := range batch.Logins {
		if device(members, sealed.OpenerId) == nil && machine(members, sealed.OpenerId) == nil {
			return fail(pb.ErrorCode_ERROR_CODE_INVALID, "A sealed login names an opener that is not a device or machine.")
		}
		if loginIn(catalogue, sealed.LoginId) == nil {
			return fail(pb.ErrorCode_ERROR_CODE_INVALID, "A sealed login is not in the catalogue.")
		}
		if byOpener[sealed.OpenerId] == nil {
			byOpener[sealed.OpenerId] = map[string][]byte{}
		}
		byOpener[sealed.OpenerId][sealed.LoginId] = marshal(sealed)
	}
	return s.Store.update(func(data *saved) error {
		for _, opener := range batch.ClearedOpeners {
			data.Sealed[opener] = map[string][]byte{}
		}
		for opener, logins := range byOpener {
			if data.Sealed[opener] == nil {
				data.Sealed[opener] = map[string][]byte{}
			}
			for id, raw := range logins {
				data.Sealed[opener][id] = raw
			}
		}
		for _, m := range members.GetMachines() {
			for _, id := range batch.WithdrawnLoginIds {
				delete(data.Sealed[m.MachineId], id)
			}
		}
		return nil
	})
}

func (s *Server) registerPush(who caller, registration *pb.PushRegistration) error {
	members, _ := s.Store.documents()
	target := device(members, registration.DeviceKeyId)
	if target == nil || (target.KeyId != who.device.KeyId && target.Kind != pb.DeviceKind_DEVICE_KIND_WATCH) {
		return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "A device registers its own push token, or its Watch's.")
	}
	if len(registration.ApnsToken) == 0 || registration.ApnsTopic == "" || len(registration.NoticePublicKey) == 0 {
		return fail(pb.ErrorCode_ERROR_CODE_INVALID, "A push registration needs a token, a topic and a notice key.")
	}
	return s.Store.update(func(data *saved) error {
		data.Pushes[registration.DeviceKeyId] = marshal(registration)
		return nil
	})
}

// join records a machine or device asking to join, then streams its state
// until a device approves it by publishing Members that list it.
func (s *Server) join(ctx context.Context, who caller, request *pb.JoinRequest, send func(*pb.RelayResponse) error) error {
	var id string
	switch joining := request.Joining.(type) {
	case *pb.JoinRequest_Machine:
		m := joining.Machine
		if !bytes.Equal(m.TlsPublicKey, who.spki) || m.MachineId != keyring.KeyID(m.TlsPublicKey) || len(m.ReceivingPublicKey) == 0 {
			return fail(pb.ErrorCode_ERROR_CODE_INVALID, "A machine joins with its own TLS key and a receiving key.")
		}
		id = m.MachineId
	case *pb.JoinRequest_Device:
		d := joining.Device
		ownConnection := len(d.TlsPublicKey) > 0 && bytes.Equal(d.TlsPublicKey, who.spki)
		watchThroughIPhone := d.Kind == pb.DeviceKind_DEVICE_KIND_WATCH && who.device != nil
		if (!ownConnection && !watchThroughIPhone) || d.KeyId != keyring.KeyID(d.SigningPublicKey) || len(d.OpeningPublicKey) == 0 {
			return fail(pb.ErrorCode_ERROR_CODE_INVALID, "A device joins with its own keys, or a Watch through its iPhone.")
		}
		id = d.KeyId
	default:
		return fail(pb.ErrorCode_ERROR_CODE_INVALID, "Join as a machine or a device.")
	}
	now := s.now()
	members, _ := s.Store.documents()
	alreadyMember := device(members, id) != nil || machine(members, id) != nil
	err := s.Store.update(func(data *saved) error {
		state := pb.JoinState_JOIN_STATE_WAITING
		if alreadyMember {
			state = pb.JoinState_JOIN_STATE_APPROVED
		}
		data.Joins[id] = &join{Request: marshal(request), Node: who.node, Asked: now.Unix(), State: state}
		return nil
	})
	if err != nil {
		return err
	}
	slog.Info("join asked", "joiner", id, "node", who.node)
	deadline := time.NewTimer(joinWithin)
	defer deadline.Stop()
	for {
		var state pb.JoinState
		var members []byte
		changed := s.Store.read(func(data *saved) {
			state, members = data.Joins[id].State, data.Members
		})
		if state != pb.JoinState_JOIN_STATE_WAITING {
			status := &pb.JoinStatus{State: state}
			if state == pb.JoinState_JOIN_STATE_APPROVED {
				status.Members = &pb.Signed{}
				unmarshal(members, status.Members)
			}
			return send(&pb.RelayResponse{Result: &pb.RelayResponse_Join{Join: status}, EndOfStream: true})
		}
		if err := send(&pb.RelayResponse{Result: &pb.RelayResponse_Join{Join: &pb.JoinStatus{State: state}}}); err != nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case <-deadline.C:
			s.Store.update(func(data *saved) error {
				if data.Joins[id].State == pb.JoinState_JOIN_STATE_WAITING {
					data.Joins[id].State = pb.JoinState_JOIN_STATE_EXPIRED
				}
				return nil
			})
		case <-changed:
		}
	}
}

func (s *Server) pendingJoins() *pb.PendingJoins {
	result := &pb.PendingJoins{}
	s.Store.read(func(data *saved) {
		for _, j := range data.Joins {
			if j.State != pb.JoinState_JOIN_STATE_WAITING {
				continue
			}
			request := &pb.JoinRequest{}
			if unmarshal(j.Request, request) == nil {
				result.Joins = append(result.Joins, &pb.PendingJoin{Request: request, TailscaleNodeName: j.Node, AskedUnixSeconds: j.Asked})
			}
		}
	})
	return result
}
