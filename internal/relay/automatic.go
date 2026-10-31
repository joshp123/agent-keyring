// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package relay

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/hpke"
	"crypto/rand"
	"database/sql"
	"errors"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func copiedLogin(tx *sql.Tx, id string) (*pb.AutomaticLoginContents, error) {
	var raw []byte
	err := tx.QueryRow("SELECT contents FROM automatic_logins WHERE id=?", id).Scan(&raw)
	if err != nil {
		return nil, err
	}
	defer clear(raw)
	contents := new(pb.AutomaticLoginContents)
	err = proto.Unmarshal(raw, contents)
	return contents, err
}

func (s *Server) activateAutomatic(tx *sql.Tx, lease *pb.Lease) (bool, error) {
	if lease.State != pb.LeaseState_LEASE_STATE_PENDING || time.Now().Unix() >= lease.PendingUntilUnixSeconds {
		return false, nil
	}
	_, config, err := configuration(tx)
	if err != nil {
		return false, err
	}
	login, machine := loginByID(config, lease.LoginId), machineByID(config, lease.GetRecipient().GetRecipientId())
	if !s.delegatesAutomatic(config) || login.GetRule() != pb.AccessRule_ACCESS_RULE_AUTOMATIC || !machine.GetAutomaticAllowed() {
		return false, nil
	}
	var exists int
	err = tx.QueryRow("SELECT 1 FROM automatic_logins WHERE id=?", lease.LoginId).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	_, raw, err := loadLease(tx, lease.LeaseId)
	if err != nil {
		return false, err
	}
	record := new(pb.RequestRecord)
	if err = proto.Unmarshal(raw, record); err != nil {
		return false, err
	}
	if !record.Automatic {
		return false, nil
	}
	lease.State = pb.LeaseState_LEASE_STATE_ACTIVE
	lease.ApprovedBy = pb.ApprovedBy_APPROVED_BY_AUTOMATIC_RULE
	lease.ApprovedAtUnixSeconds = time.Now().Unix()
	lease.NotAfterUnixSeconds = lease.ApprovedAtUnixSeconds + 1800
	return true, saveLease(tx, lease)
}

func (s *Server) prepareAutomaticDelivery(tx *sql.Tx, lease *pb.Lease, config *pb.Configuration) error {
	login, machine := loginByID(config, lease.LoginId), machineByID(config, lease.GetRecipient().GetRecipientId())
	if login.GetRule() != pb.AccessRule_ACCESS_RULE_AUTOMATIC || !machine.GetAutomaticAllowed() {
		return denied("Current configuration refuses Automatic delivery.")
	}
	contents, err := copiedLogin(tx, lease.LoginId)
	if errors.Is(err, sql.ErrNoRows) {
		return &rpcError{pb.RpcErrorCode_RPC_ERROR_CODE_UNAVAILABLE, "The Automatic login copy is not available yet."}
	}
	if err != nil {
		return err
	}
	if !sameSites(contents.Sites, login.Sites) {
		return denied("Login copy destinations no longer match the configuration.")
	}
	var cached, record []byte
	if err = tx.QueryRow("SELECT bundle,request FROM leases WHERE id=?", lease.LeaseId).Scan(&cached, &record); err != nil {
		return err
	}
	if len(cached) > 0 {
		return nil
	}
	codes, err := automaticCodes(contents, time.Now().Unix(), lease.NotAfterUnixSeconds)
	if err != nil {
		return err
	}
	bundleContents := &pb.BundleContents{LeaseId: lease.LeaseId, LoginId: lease.LoginId, Sites: login.Sites, Username: contents.Username, Password: contents.Password, OneTimeCodes: codes, NotAfterUnixSeconds: lease.NotAfterUnixSeconds}
	raw := marshal(bundleContents)
	defer clear(raw)
	receiver, err := ecdh.P256().NewPublicKey(machine.ReceiverPublicKey)
	if err != nil {
		return err
	}
	hpkeKey, err := hpke.NewDHKEMPublicKey(receiver)
	if err != nil {
		return err
	}
	encapsulated, sealer, err := hpke.NewSender(hpkeKey, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte("agentkeyring.bundle.v1"))
	if err != nil {
		return err
	}
	digest := relaycrypto.Digest("agentkeyring.request.v1", record)
	ciphertext, err := sealer.Seal(digest, raw)
	if err != nil {
		return err
	}
	bundle := &pb.SealedBundle{EncapsulatedKey: encapsulated, Ciphertext: ciphertext, ReceiverKeyId: machine.ReceiverKeyId}
	statement := &pb.DecisionStatement{Domain: "agentkeyring.decision.v1", RequestDigest: digest, Choice: pb.DecisionChoice_DECISION_CHOICE_APPROVE, ApprovedAtUnixSeconds: lease.ApprovedAtUnixSeconds, NotAfterUnixSeconds: lease.NotAfterUnixSeconds, RecipientId: machine.RecipientId, ReceiverKeyId: machine.ReceiverKeyId, BundleCiphertextSha256: relaycrypto.Hash(ciphertext), LeaseId: lease.LeaseId, ReplySha256: relaycrypto.Hash(nil), Authority: pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE, ConfigurationRevision: config.Revision}
	statementBytes := marshal(statement)
	signature, err := ecdsa.SignASN1(rand.Reader, s.Store.automaticSigning, relaycrypto.Hash(statementBytes))
	if err != nil {
		return err
	}
	decision := &pb.SignedDecision{Statement: statementBytes, Signature: signature, ApproverKeyId: config.AutomaticKeyId}
	_, err = tx.Exec("UPDATE leases SET decision=?,bundle=? WHERE id=?", marshal(decision), marshal(bundle), lease.LeaseId)
	return err
}
