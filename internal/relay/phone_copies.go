// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package relay

import (
	"database/sql"
	"errors"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func phoneCopyDestination(keys *pb.ApproverKeySet, destination string) *pb.ApproverKey {
	for _, key := range keys.GetKeys() {
		if relaycrypto.Role(keys, key) == pb.ApproverRole_APPROVER_ROLE_PHONE && len(key.EncryptionPublicKey) > 0 && relaycrypto.CopyDestinationID(key.EncryptionPublicKey) == destination {
			return key
		}
	}
	return nil
}

func storePhoneCopy(tx *sql.Tx, signed *pb.SignedCopyUpdate, update *pb.CopyUpdate, config *pb.Configuration) error {
	ids := map[string]bool{}
	for _, entry := range update.Logins {
		login := loginByID(config, entry.GetLoginId())
		if login == nil || login.Rule != pb.AccessRule_ACCESS_RULE_ASK || ids[login.LoginId] {
			return denied("Phone copy contains a duplicate or non-Ask login outside the current configuration.")
		}
		ids[login.LoginId] = true
		sealed := entry.GetSealed()
		if sealed == nil || sealed.ReceiverKeyId != update.DestinationKeyId || len(sealed.Ciphertext) == 0 {
			return denied("Phone copy is not sealed to its paired destination.")
		}
		if _, err := relaycrypto.PublicKey(sealed.EncapsulatedKey); err != nil {
			return invalid("Invalid phone copy encapsulated key.")
		}
	}
	_, err := tx.Exec("INSERT INTO phone_copies VALUES(?,?) ON CONFLICT(destination) DO UPDATE SET signed=excluded.signed", update.DestinationKeyId, marshal(signed))
	return err
}

func phoneCopy(tx *sql.Tx, p peer) (*pb.SignedCopyUpdate, error) {
	_, keys, err := currentKeys(tx)
	if err != nil {
		return nil, err
	}
	key := keyByID(keys, p.approver)
	if relaycrypto.Role(keys, key) != pb.ApproverRole_APPROVER_ROLE_PHONE || len(key.GetEncryptionPublicKey()) == 0 {
		return nil, denied("Only a paired phone with an encryption key can fetch its copy.")
	}
	var raw []byte
	err = tx.QueryRow("SELECT signed FROM phone_copies WHERE destination=?", relaycrypto.CopyDestinationID(key.EncryptionPublicKey)).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, missing("No login copy has arrived for this phone.")
	}
	if err != nil {
		return nil, err
	}
	value := new(pb.SignedCopyUpdate)
	err = proto.Unmarshal(raw, value)
	return value, err
}

func removePhoneCopy(tx *sql.Tx, key *pb.ApproverKey) error {
	if len(key.EncryptionPublicKey) == 0 {
		return nil
	}
	destination := relaycrypto.CopyDestinationID(key.EncryptionPublicKey)
	if _, err := tx.Exec("DELETE FROM phone_copies WHERE destination=?", destination); err != nil {
		return err
	}
	_, err := tx.Exec("DELETE FROM copy_updates WHERE destination=?", destination)
	return err
}
