// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package relay

import (
	"bytes"
	"crypto/hpke"
	"database/sql"
	"errors"
	"slices"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func sameSites(a, b []string) bool {
	a, b = slices.Clone(a), slices.Clone(b)
	slices.Sort(a)
	slices.Sort(b)
	return slices.Equal(a, b)
}

func (s *Server) publishCopyUpdate(tx *sql.Tx, signed *pb.SignedCopyUpdate) error {
	if signed == nil {
		return invalid("Missing copy update.")
	}
	_, keys, err := currentKeys(tx)
	if err != nil {
		return err
	}
	public, err := relaycrypto.KeyForRole(keys, signed.SignerKeyId, pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY)
	if err != nil || relaycrypto.Verify(public, signed.Update, signed.Signature) != nil {
		return denied("Copy update requires a current Mac delivery signature.")
	}
	update := new(pb.CopyUpdate)
	if proto.Unmarshal(signed.Update, update) != nil || update.Domain != "agentkeyring.copy-update.v1" || update.Revision == 0 {
		return invalid("Invalid copy update.")
	}
	_, config, err := configuration(tx)
	if err != nil {
		return err
	}
	if update.ConfigurationRevision != config.Revision || config.Revision == 0 {
		return denied("Copy update must name the current configuration.")
	}
	phone := phoneCopyDestination(keys, update.DestinationKeyId)
	if phone == nil && (update.DestinationKeyId != s.automaticKeys().EncryptionKeyId || !s.delegatesAutomatic(config)) {
		return denied("Configuration does not authorize this relay copy destination.")
	}
	var previous string
	var digest []byte
	err = tx.QueryRow("SELECT revision,update_hash FROM copy_updates WHERE destination=?", update.DestinationKeyId).Scan(&previous, &digest)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if err == nil && revisionID(update.Revision) <= previous {
		if revisionID(update.Revision) == previous && bytes.Equal(digest, relaycrypto.Hash(signed.Update)) {
			return nil
		}
		return conflict("Copy update revision did not increase.")
	}
	if phone != nil {
		if err = storePhoneCopy(tx, signed, update, config); err != nil {
			return err
		}
		return rememberCopyRevision(tx, update, signed.Update)
	}
	private, err := s.Store.automaticEncryption.ECDH()
	if err != nil {
		return err
	}
	openerKey, err := hpke.NewDHKEMPrivateKey(private)
	if err != nil {
		return err
	}
	contents := make(map[string][]byte)
	defer func() {
		for _, data := range contents {
			clear(data)
		}
	}()
	for _, login := range update.Logins {
		metadata := loginByID(config, login.GetLoginId())
		if metadata == nil || metadata.Rule != pb.AccessRule_ACCESS_RULE_AUTOMATIC || contents[login.LoginId] != nil {
			return denied("Copy contains a duplicate or non-Automatic login outside the current configuration.")
		}
		sealed := login.GetSealed()
		if sealed == nil || sealed.ReceiverKeyId != update.DestinationKeyId {
			return denied("Copy is sealed to a different destination.")
		}
		opener, err := hpke.NewRecipient(sealed.EncapsulatedKey, openerKey, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(relaycrypto.CopyLoginInfo))
		if err != nil {
			return denied("Invalid sealed login copy.")
		}
		raw, err := opener.Open(relaycrypto.CopyLoginAAD(update.DestinationKeyId, update.ConfigurationRevision, update.Revision, login.LoginId), sealed.Ciphertext)
		if err != nil {
			return denied("Cannot open the sealed login copy.")
		}
		contents[login.LoginId] = raw
		value := new(pb.AutomaticLoginContents)
		if proto.Unmarshal(raw, value) != nil || value.LoginId != login.LoginId || !sameSites(value.Sites, metadata.Sites) || metadata.HasOneTimeCode != (len(value.TotpSeed) > 0) {
			return denied("Login copy contents do not match the configured login and destinations.")
		}
		if err := validateCodeParameters(value); err != nil {
			return err
		}
	}
	if _, err = tx.Exec("DELETE FROM automatic_logins"); err != nil {
		return err
	}
	for id, raw := range contents {
		if _, err = tx.Exec("INSERT INTO automatic_logins VALUES(?,?)", id, raw); err != nil {
			return err
		}
	}
	if err = rememberCopyRevision(tx, update, signed.Update); err != nil {
		return err
	}
	leases, err := queryLeases(tx, "SELECT lease FROM leases WHERE deadline IS NOT NULL")
	if err != nil {
		return err
	}
	for _, lease := range leases {
		if lease.ApprovedBy == pb.ApprovedBy_APPROVED_BY_AUTOMATIC_RULE {
			if _, err = tx.Exec("UPDATE leases SET decision=NULL,bundle=NULL WHERE id=?", lease.LeaseId); err != nil {
				return err
			}
		}
		if _, err = s.activateAutomatic(tx, lease); err != nil {
			return err
		}
	}
	return nil
}

func rememberCopyRevision(tx *sql.Tx, update *pb.CopyUpdate, raw []byte) error {
	_, err := tx.Exec("INSERT INTO copy_updates VALUES(?,?,?) ON CONFLICT(destination) DO UPDATE SET revision=excluded.revision,update_hash=excluded.update_hash", update.DestinationKeyId, revisionID(update.Revision), relaycrypto.Hash(raw))
	return err
}

func (s *Server) pruneAutomaticCopies(tx *sql.Tx, next *pb.Configuration) error {
	rows, err := tx.Query("SELECT id,contents FROM automatic_logins")
	if err != nil {
		return err
	}
	var remove []string
	for rows.Next() {
		var id string
		var raw []byte
		if err = rows.Scan(&id, &raw); err != nil {
			break
		}
		value := new(pb.AutomaticLoginContents)
		err = proto.Unmarshal(raw, value)
		clear(raw)
		if err != nil {
			break
		}
		login := loginByID(next, id)
		if !s.delegatesAutomatic(next) || login == nil || login.Rule != pb.AccessRule_ACCESS_RULE_AUTOMATIC || !sameSites(value.Sites, login.Sites) || login.HasOneTimeCode != (len(value.TotpSeed) > 0) {
			remove = append(remove, id)
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return err
	}
	for _, id := range remove {
		if _, err = tx.Exec("DELETE FROM automatic_logins WHERE id=?", id); err != nil {
			return err
		}
	}
	return nil
}
