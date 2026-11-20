// Written by AI on 2026.11.18 by model claude opus 5.5.
package relay

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/subtle"
	"log/slog"
	"slices"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/keyring"
)

// publishMembers accepts the next list of devices and machines. The very
// first comes from a device it lists, over that device's own connection.
// Both publish methods check a new document against the current one inside the
// store's lock, so two published at once cannot leave the older one in place.
func (s *Server) publishMembers(who caller, document *pb.Signed) error {
	return s.Store.update(func(data *saved) error {
		current, _ := s.Store.documentsLocked()
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
			if !s.provesSetup(data, next) {
				return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED,
					"This relay waits for its own computer to announce it. Open Agent Keyring on that computer, then connect from this Mac.")
			}
			data.SetupSecret = nil
		} else if who.device == nil {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "Only a device may change the members.")
		}
		data.Members = marshal(document)
		data.MembersHistory = append(data.MembersHistory, data.Members)
		slog.Info("members published", "revision", next.Revision, "devices", len(next.Devices), "computers", len(next.Machines))
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
	return s.Store.update(func(data *saved) error {
		members, current := s.Store.documentsLocked()
		next, err := keyring.VerifiedCatalogue(document, members, current)
		if err != nil {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "Catalogue refused: "+err.Error())
		}
		data.Catalogue = marshal(document)
		s.Store.catalogue = next
		// A login that is Blocked, or no longer listed (a sample password his own copy replaced), has no copy here.
		kept := map[string]bool{}
		for _, login := range next.Logins {
			kept[login.LoginId] = login.Rule != pb.Rule_RULE_BLOCKED
		}
		for opener := range data.Sealed {
			for id := range data.Sealed[opener] {
				if !kept[id] {
					delete(data.Sealed[opener], id)
				}
			}
		}
		return nil
	})
}

// publishSealedLogins adds or replaces each copy given, empties each opener
// cleared, and removes the machines' copies of each login withdrawn. Copies of
// a Blocked login are not kept.
func (s *Server) publishSealedLogins(batch *pb.SealedLogins) error {
	return s.Store.update(func(data *saved) error {
		members, catalogue := s.Store.documentsLocked()
		byOpener := map[string]map[string][]byte{}
		for _, sealed := range batch.Logins {
			if device(members, sealed.OpenerId) == nil && machine(members, sealed.OpenerId) == nil {
				return fail(pb.ErrorCode_ERROR_CODE_INVALID, "A sealed login names an opener that is not a device or machine.")
			}
			login := loginIn(catalogue, sealed.LoginId)
			if login == nil {
				return fail(pb.ErrorCode_ERROR_CODE_INVALID, "A sealed login is not in the catalogue.")
			}
			if login.Rule == pb.Rule_RULE_BLOCKED {
				continue
			}
			if byOpener[sealed.OpenerId] == nil {
				byOpener[sealed.OpenerId] = map[string][]byte{}
			}
			byOpener[sealed.OpenerId][sealed.LoginId] = marshal(sealed)
		}
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
	slog.Info("push address registered", "device", target.Label, "topic", registration.ApnsTopic, "production", registration.ApnsProduction)
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
	err := s.Store.update(func(data *saved) error {
		members, _ := s.Store.documentsLocked()
		// Already a member, rejoining with the same TLS key (a machine's id is its TLS key's hash).
		state := pb.JoinState_JOIN_STATE_WAITING
		if d := device(members, id); machine(members, id) != nil || (d != nil && (who.device != nil || bytes.Equal(d.TlsPublicKey, who.spki))) {
			state = pb.JoinState_JOIN_STATE_APPROVED
		}
		if existing := data.Joins[id]; existing != nil && existing.State == pb.JoinState_JOIN_STATE_WAITING && !bytes.Equal(existing.SPKI, who.spki) {
			return fail(pb.ErrorCode_ERROR_CODE_CONFLICT, "Another join with these keys is waiting.")
		}
		data.Joins[id] = &join{Request: marshal(request), SPKI: who.spki, Node: who.node, Asked: now.Unix(), State: state, Local: who.local}
		return nil
	})
	if err != nil {
		return err
	}
	slog.Info("join asked", "joiner", id, "node", who.node)
	deadline := time.NewTimer(joinWithin)
	defer deadline.Stop()
	heartbeat := time.NewTicker(30 * time.Second) // The waiting device hears it is still waiting, so it never times out.
	defer heartbeat.Stop()
	for {
		var state pb.JoinState
		var members, refusal []byte
		changed := s.Store.read(func(data *saved) {
			state, members, refusal = data.Joins[id].State, data.Members, data.Joins[id].Refusal
		})
		if state != pb.JoinState_JOIN_STATE_WAITING {
			status := &pb.JoinStatus{State: state}
			if state == pb.JoinState_JOIN_STATE_APPROVED {
				status.Members = &pb.Signed{}
				unmarshal(members, status.Members)
			}
			if state == pb.JoinState_JOIN_STATE_REFUSED {
				status.Refusal = &pb.JoinRefusal{}
				unmarshal(refusal, status.Refusal)
			}
			return send(&pb.RelayResponse{Result: &pb.RelayResponse_Join{Join: status}, EndOfStream: true})
		}
		if err := send(&pb.RelayResponse{Result: &pb.RelayResponse_Join{Join: &pb.JoinStatus{State: state}}}); err != nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case <-heartbeat.C:
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

// refuseJoin ends a machine's waiting join, if the refusal carries the key
// whose hash the machine sent: only the device that invited it can make it.
func (s *Server) refuseJoin(refusal *pb.JoinRefusal) error {
	return s.Store.update(func(data *saved) error {
		j := data.Joins[refusal.JoinerId]
		request := &pb.JoinRequest{}
		if j == nil || unmarshal(j.Request, request) != nil || request.GetMachine() == nil {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "No computer is asking to join with that ID.")
		}
		if len(request.RefusalKeySha256) == 0 || subtle.ConstantTimeCompare(keyring.SHA256(refusal.Key), request.RefusalKeySha256) != 1 {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "Only the device that invited this computer can refuse it.")
		}
		if j.State != pb.JoinState_JOIN_STATE_WAITING {
			return fail(pb.ErrorCode_ERROR_CODE_CONFLICT, "This join has already ended.")
		}
		j.State, j.Refusal = pb.JoinState_JOIN_STATE_REFUSED, marshal(refusal)
		slog.Info("join refused", "joiner", refusal.JoinerId)
		return nil
	})
}

func (s *Server) pendingJoins() *pb.PendingJoins {
	result := &pb.PendingJoins{}
	s.Store.read(func(data *saved) { result.Joins = pendingJoinsLocked(data) })
	return result
}

// pendingJoinsLocked lists the joins still waiting, oldest first.
func pendingJoinsLocked(data *saved) []*pb.PendingJoin {
	var joins []*pb.PendingJoin
	for _, j := range data.Joins {
		if j.State != pb.JoinState_JOIN_STATE_WAITING {
			continue
		}
		request := &pb.JoinRequest{}
		if unmarshal(j.Request, request) == nil {
			joins = append(joins, &pb.PendingJoin{Request: request, TailscaleNodeName: j.Node, AskedUnixSeconds: j.Asked})
		}
	}
	slices.SortFunc(joins, func(a, b *pb.PendingJoin) int { return int(a.AskedUnixSeconds - b.AskedUnixSeconds) })
	return joins
}

// provesSetup: an empty relay takes its first members list only from someone
// who reached its own computer, so nobody else on the network can take it
// first. Either the list carries proof of the secret the relay gave our app
// there (setup_proof), or the computer that stays on, which it names, asked
// to join from the relay's own address (an agent's setup-relay and enrol).
func (s *Server) provesSetup(data *saved, next *pb.Members) bool {
	if len(data.SetupSecret) > 0 && len(next.Devices) > 0 &&
		hmac.Equal(next.SetupProof, keyring.SetupProof(data.SetupSecret, s.ownSPKI(), next.Devices[0].KeyId)) {
		return true
	}
	j := data.Joins[next.RelayMachineId]
	return next.RelayMachineId != "" && j != nil && j.Local
}

// setupOffer gives the one-time secret to a caller on the relay's own
// computer while the relay has no members: our app there leaves it in
// iCloud Keychain for the Mac to find.
func (s *Server) setupOffer(who caller) (*pb.SetupOffer, error) {
	if !who.local {
		return nil, fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "Only the relay's own computer may ask for its setup offer.")
	}
	offer := &pb.SetupOffer{RelayTlsPublicKey: s.ownSPKI()}
	err := s.Store.update(func(data *saved) error {
		if current, _ := s.Store.documentsLocked(); current != nil {
			return fail(pb.ErrorCode_ERROR_CODE_CONFLICT, "This relay is already set up.")
		}
		if len(data.SetupSecret) == 0 {
			data.SetupSecret = make([]byte, 32)
			rand.Read(data.SetupSecret)
		}
		offer.Secret = data.SetupSecret
		return nil
	})
	if err != nil {
		return nil, err
	}
	slog.Info("setup offer given")
	return offer, nil
}
