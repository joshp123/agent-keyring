// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relay

import (
	"bytes"
	"crypto/rand"
	"crypto/x509"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func newID() string {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(data[:])
}
func (s *Server) enrol(tx *sql.Tx, p peer, r *pb.EnrolRequest, seen map[string][]byte) (*pb.RelayWireResponse, bool, error) {
	if p.approver != "" {
		return nil, false, denied("Approver TLS keys cannot enrol as receiver keys.")
	}
	if r == nil || r.MachineLabel == "" || r.ClientLabel == "" || !bytes.Equal(r.TlsPublicKey, p.spki) {
		return nil, false, invalid("Enrolment must name the machine and its TLS peer key.")
	}
	if _, err := relaycrypto.PublicKey(r.ReceiverPublicKey); err != nil {
		return nil, false, invalid("Invalid receiver key.")
	}
	signed, _, err := currentKeys(tx)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, denied("Pair an approver before enrolling machines.")
	}
	if err != nil {
		return nil, false, err
	}
	var recordBytes, configurationBytes, keysetBytes []byte
	var state int
	err = tx.QueryRow("SELECT record,decision,keyset,state FROM enrolments WHERE spki=?", p.spki).Scan(&recordBytes, &configurationBytes, &keysetBytes, &state)
	if err == nil && state == 0 && len(seen) == 0 {
		previous := new(pb.EnrolmentRecord)
		if decodeErr := proto.Unmarshal(recordBytes, previous); decodeErr != nil {
			return nil, false, decodeErr
		}
		if time.Now().Unix() >= previous.CreatedUnixSeconds+600 || !bytes.Equal(previous.ApproverKeySetSha256, relaycrypto.Hash(signed.KeySet)) {
			if _, err = tx.Exec("DELETE FROM enrolments WHERE spki=? AND state=0", p.spki); err != nil {
				return nil, false, err
			}
			err = sql.ErrNoRows
		}
	}
	if errors.Is(err, sql.ErrNoRows) && seen["enrol"] != nil {
		status := new(pb.EnrolStatus)
		if err = proto.Unmarshal(seen["enrol"], status); err != nil {
			return nil, false, err
		}
		status.State = pb.EnrolState_ENROL_STATE_EXPIRED
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_EnrolStatus{EnrolStatus: status}, EndOfStream: true}, false, nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		relaySPKI, _ := relaycrypto.CertificateSPKI(s.Certificate)
		record := &pb.EnrolmentRecord{RecipientId: newID(), MachineLabel: r.MachineLabel, ClientLabel: r.ClientLabel, TailscaleNodeId: p.node.ID, TailscaleNodeName: p.node.Name, TailscaleTags: p.node.Tags, TlsPublicKey: p.spki, ReceiverPublicKey: r.ReceiverPublicKey, ReceiverKeyId: hashID(r.ReceiverPublicKey), CreatedUnixSeconds: time.Now().Unix(), ApproverKeySetSha256: relaycrypto.Hash(signed.KeySet), Code: relaycrypto.Fingerprint(relaycrypto.EnrolTranscript(relaySPKI, p.spki, r.ReceiverPublicKey, signed.KeySet))}
		recordBytes = marshal(record)
		keysetBytes = marshal(signed)
		_, err = tx.Exec("INSERT INTO enrolments(id,spki,node,state,record,keyset,expires) VALUES(?,?,?,?,?,?,?)", record.RecipientId, p.spki, p.node.ID, 0, recordBytes, keysetBytes, record.CreatedUnixSeconds+600)
	}
	if err != nil {
		return nil, false, err
	}
	record := new(pb.EnrolmentRecord)
	if err = proto.Unmarshal(recordBytes, record); err != nil {
		return nil, false, err
	}
	if !bytes.Equal(record.ReceiverPublicKey, r.ReceiverPublicKey) || record.MachineLabel != r.MachineLabel || record.ClientLabel != r.ClientLabel {
		return nil, false, conflict("These TLS keys already have a different enrolment request.")
	}
	compared := new(pb.SignedApproverKeySet)
	if err = proto.Unmarshal(keysetBytes, compared); err != nil {
		return nil, false, err
	}
	status := &pb.EnrolStatus{State: pb.EnrolState_ENROL_STATE_PENDING, Code: record.Code, RecipientId: record.RecipientId, ApproverKeySet: compared}
	keys := new(pb.ApproverKeySet)
	if err = proto.Unmarshal(compared.KeySet, keys); err != nil {
		return nil, false, err
	}
	status.ApproverKeys = keys.Keys
	switch state {
	case 1:
		status.State = pb.EnrolState_ENROL_STATE_APPROVED
		status.Configuration = new(pb.SignedConfiguration)
		if err = proto.Unmarshal(configurationBytes, status.Configuration); err != nil {
			return nil, false, err
		}
		config := new(pb.Configuration)
		if err = proto.Unmarshal(status.Configuration.Configuration, config); err != nil {
			return nil, false, err
		}
		status.AutomaticAllowed = machineByID(config, record.RecipientId).GetAutomaticAllowed()
	case 2, 3:
		status.State = pb.EnrolState_ENROL_STATE_DENIED
	default:
		if time.Now().Unix() >= record.CreatedUnixSeconds+600 || !bytes.Equal(compared.KeySet, signed.KeySet) {
			status.State = pb.EnrolState_ENROL_STATE_EXPIRED
		}
	}
	more := status.State == pb.EnrolState_ENROL_STATE_PENDING
	if !changed(seen, "enrol", status) {
		return nil, more, nil
	}
	return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_EnrolStatus{EnrolStatus: status}, EndOfStream: !more}, more, nil
}
func (s *Server) pair(tx *sql.Tx, p peer, r *pb.PairApproverRequest, seen map[string][]byte) (*pb.RelayWireResponse, bool, error) {
	if p.recipient != "" {
		return nil, false, denied("Receiver TLS keys cannot pair as approver keys.")
	}
	if r == nil || r.Key == nil || r.Key.KeyId == "" || r.Key.Label == "" || !bytes.Equal(r.TlsPublicKey, p.spki) || !bytes.Equal(r.Key.TlsPublicKey, p.spki) {
		return nil, false, invalid("Pairing keys must match the TLS peer.")
	}
	if _, err := relaycrypto.PublicKey(r.Key.PublicKey); err != nil {
		return nil, false, invalid("Invalid approver signing key.")
	}
	if len(r.Key.EncryptionPublicKey) > 0 {
		if r.Key.Role != pb.ApproverRole_APPROVER_ROLE_PHONE {
			return nil, false, invalid("Only a phone may pair a copy encryption key.")
		}
		if _, err := relaycrypto.PublicKey(r.Key.EncryptionPublicKey); err != nil {
			return nil, false, invalid("Invalid phone copy encryption key.")
		}
	}
	signed, keys, err := currentKeys(tx)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, false, err
	}
	var comparedBytes, requestBytes []byte
	var node string
	var created int64
	err = tx.QueryRow("SELECT node,request,keyset,created FROM pairings WHERE id=?", r.Key.KeyId).Scan(&node, &requestBytes, &comparedBytes, &created)
	if errors.Is(err, sql.ErrNoRows) && seen["pair"] != nil {
		status := &pb.EnrolStatus{State: pb.EnrolState_ENROL_STATE_EXPIRED}
		return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_EnrolStatus{EnrolStatus: status}, EndOfStream: true}, false, nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		comparedBytes = append([]byte{}, signed.GetKeySet()...)
		created = time.Now().Unix()
		node = p.node.ID
		requestBytes = marshal(r)
		_, err = tx.Exec("INSERT INTO pairings(id,node,request,keyset,created,expires) VALUES(?,?,?,?,?,?)", r.Key.KeyId, node, requestBytes, comparedBytes, created, created+600)
		relaySPKI, _ := relaycrypto.CertificateSPKI(s.Certificate)
		s.Log.Info("compare pairing fingerprint on approver", "fingerprint", relaycrypto.Fingerprint(relaycrypto.PairTranscript(relaySPKI, p.spki, r.Key.PublicKey, comparedBytes, r.Key.EncryptionPublicKey)))
	}
	if err != nil {
		return nil, false, err
	}
	old := new(pb.PairApproverRequest)
	if err = proto.Unmarshal(requestBytes, old); err != nil {
		return nil, false, err
	}
	if node != p.node.ID || !proto.Equal(old, r) {
		return nil, false, conflict("Approver key ID already has a different pairing.")
	}
	if keyByID(keys, r.Key.KeyId) == nil && len(seen) == 0 && (time.Now().Unix() >= created+600 || !bytes.Equal(comparedBytes, signed.GetKeySet())) {
		comparedBytes = append([]byte{}, signed.GetKeySet()...)
		created = time.Now().Unix()
		if _, err = tx.Exec("UPDATE pairings SET keyset=?,created=?,expires=? WHERE id=?", comparedBytes, created, created+600, r.Key.KeyId); err != nil {
			return nil, false, err
		}
		relaySPKI, _ := relaycrypto.CertificateSPKI(s.Certificate)
		s.Log.Info("compare restarted pairing fingerprint on approver", "fingerprint", relaycrypto.Fingerprint(relaycrypto.PairTranscript(relaySPKI, p.spki, r.Key.PublicKey, comparedBytes, r.Key.EncryptionPublicKey)))
	}
	status := &pb.EnrolStatus{State: pb.EnrolState_ENROL_STATE_PENDING, ApproverKeySet: signed, ApproverKeys: keys.GetKeys()}
	if key := keyByID(keys, r.Key.KeyId); key != nil && proto.Equal(key, r.Key) {
		status.State = pb.EnrolState_ENROL_STATE_APPROVED
	} else if time.Now().Unix() >= created+600 || !bytes.Equal(comparedBytes, signed.GetKeySet()) {
		status.State = pb.EnrolState_ENROL_STATE_EXPIRED
	}
	more := status.State == pb.EnrolState_ENROL_STATE_PENDING
	if !changed(seen, "pair", status) {
		return nil, more, nil
	}
	return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_EnrolStatus{EnrolStatus: status}, EndOfStream: !more}, more, nil
}
func (s *Server) confirm(tx *sql.Tx, p peer, r *pb.SignedPairingConfirmation) (*pb.RelayWireResponse, error) {
	if r == nil {
		return nil, invalid("Missing pairing confirmation.")
	}
	previous := new(pb.SignedPairingConfirmation)
	if err := get(tx, "confirmation", r.ApproverKeyId, previous); err == nil && proto.Equal(r, previous) && p.approver == r.ApproverKeyId {
		return enrolAck(), nil
	}
	if _, _, err := currentKeys(tx); !errors.Is(err, sql.ErrNoRows) {
		if err != nil {
			return nil, err
		}
		return nil, denied("This relay already has an approver. Add approvers through the pinned approver.")
	}
	var data, compared []byte
	var node string
	var created int64
	if err := tx.QueryRow("SELECT request,keyset,node,created FROM pairings WHERE id=?", r.ApproverKeyId).Scan(&data, &compared, &node, &created); err != nil {
		return nil, missing("No pending pairing.")
	}
	pair := new(pb.PairApproverRequest)
	if err := proto.Unmarshal(data, pair); err != nil {
		return nil, err
	}
	if !bytes.Equal(pair.TlsPublicKey, p.spki) || node != p.node.ID || time.Now().Unix() >= created+600 {
		return nil, denied("Pairing expired or belongs to a different peer.")
	}
	confirmation := new(pb.PairingConfirmation)
	if err := proto.Unmarshal(r.Confirmation, confirmation); err != nil {
		return nil, invalid("Invalid pairing confirmation.")
	}
	relaySPKI, _ := relaycrypto.CertificateSPKI(s.Certificate)
	digest := relaycrypto.Hash(relaycrypto.PairTranscript(relaySPKI, p.spki, pair.Key.PublicKey, compared, pair.Key.EncryptionPublicKey))
	if confirmation.Domain != "agentkeyring.pairconfirm.v1" || !bytes.Equal(confirmation.TranscriptSha256, digest) || confirmation.ConfirmedUnixSeconds < created || confirmation.ConfirmedUnixSeconds > time.Now().Unix()+30 {
		return nil, denied("Pairing confirmation does not match the compared transcript.")
	}
	if err := relaycrypto.Verify(pair.Key.PublicKey, r.Confirmation, r.Signature); err != nil {
		return nil, denied("Invalid pairing signature.")
	}
	initial := r.InitialKeySet
	if initial == nil {
		return nil, invalid("Missing signed initial approver key set.")
	}
	keys := new(pb.ApproverKeySet)
	if proto.Unmarshal(initial.KeySet, keys) != nil || keys.Domain != "agentkeyring.approvers.v1" || keys.Revision != 1 || len(keys.Keys) != 1 || !proto.Equal(keys.Keys[0], pair.Key) || keys.RuleOwnerKeyId != pair.Key.KeyId || !bytes.Equal(keys.PairingTranscriptSha256, digest) || initial.SignerKeyId != pair.Key.KeyId {
		return nil, denied("Invalid initial approver key set.")
	}
	if err := relaycrypto.Verify(pair.Key.PublicKey, initial.KeySet, initial.Signature); err != nil {
		return nil, denied("Invalid key-set signature.")
	}
	if err := relaycrypto.ValidateRoles(keys, keys.RuleOwnerKeyId); err != nil {
		return nil, denied(err.Error())
	}
	if err := put(tx, "current", "keys", initial); err != nil {
		return nil, err
	}
	if err := put(tx, "keychain", revisionID(1), initial); err != nil {
		return nil, err
	}
	if err := put(tx, "confirmation", r.ApproverKeyId, r); err != nil {
		return nil, err
	}
	if _, err := tx.Exec("UPDATE pairings SET expires=NULL WHERE id=?", r.ApproverKeyId); err != nil {
		return nil, err
	}
	return enrolAck(), nil
}
func validSPKI(raw []byte) bool { _, err := x509.ParsePKIXPublicKey(raw); return err == nil }
