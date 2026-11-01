// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package relay

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func enforcementDevices(keys *pb.ApproverKeySet, config *pb.Configuration) map[string][]byte {
	devices := map[string][]byte{}
	for _, key := range keys.GetKeys() {
		if len(key.TlsPublicKey) > 0 {
			devices[hashID(key.TlsPublicKey)] = key.TlsPublicKey
		}
	}
	for _, machine := range config.GetMachines() {
		devices[hashID(machine.TlsPublicKey)] = machine.TlsPublicKey
	}
	return devices
}
func retainWithdrawal(tx *sql.Tx, update *pb.TrustUpdate, keys *pb.ApproverKeySet, config *pb.Configuration, removed [][]byte) error {
	target, err := relaycrypto.UpdateTarget(update)
	if err != nil {
		return err
	}
	revision := revisionID(target.Revision)
	if _, err = tx.Exec("INSERT INTO trust_updates(kind,revision,hash,value) VALUES(?,?,?,?)", target.Kind, revision, target.UpdateSha256, marshal(update)); err != nil {
		return err
	}
	for _, spki := range enforcementDevices(keys, config) {
		if _, err = tx.Exec("INSERT INTO update_devices(kind,revision,spki) VALUES(?,?,?)", target.Kind, revision, spki); err != nil {
			return err
		}
	}
	for _, spki := range removed {
		// An absent device's earlier obligation is retired only after this later
		// owner-signed withdrawal has confirmations from all remaining devices.
		if _, err = tx.Exec("UPDATE update_devices SET replacement_kind=?,replacement_revision=? WHERE spki=? AND receipt IS NULL AND replacement_kind IS NULL AND NOT(kind=? AND revision=?)", target.Kind, revision, spki, target.Kind, revision); err != nil {
			return err
		}
	}
	return settleWithdrawals(tx)
}
func settleWithdrawals(tx *sql.Tx) error {
	for {
		result, err := tx.Exec(`UPDATE trust_updates AS u SET completed=? WHERE completed IS NULL AND NOT EXISTS (
SELECT 1 FROM update_devices d WHERE d.kind=u.kind AND d.revision=u.revision AND d.receipt IS NULL AND NOT EXISTS (
SELECT 1 FROM trust_updates later WHERE later.kind=d.replacement_kind AND later.revision=d.replacement_revision AND later.completed IS NOT NULL))`, time.Now().Unix())
		if err != nil {
			return err
		}
		n, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if n == 0 {
			return nil
		}
	}
}
func retireDevice(tx *sql.Tx, spki []byte, node string) error {
	_, err := tx.Exec("INSERT INTO retired_devices VALUES(?,?) ON CONFLICT(spki) DO UPDATE SET node=excluded.node", spki, node)
	return err
}
func configurationUpdates(tx *sql.Tx, p peer, after uint64) (*pb.ConfigurationUpdates, error) {
	result := new(pb.ConfigurationUpdates)
	rows, err := tx.Query(`SELECT u.value FROM trust_updates u JOIN update_devices d ON d.kind=u.kind AND d.revision=u.revision WHERE u.kind=? AND d.spki=? AND u.revision>? ORDER BY u.revision`, pb.UpdateKind_UPDATE_KIND_CONFIGURATION, p.spki, revisionID(after))
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var raw []byte
		if err = rows.Scan(&raw); err != nil {
			break
		}
		update := new(pb.TrustUpdate)
		if err = proto.Unmarshal(raw, update); err != nil {
			break
		}
		result.Configurations = append(result.Configurations, update.GetConfiguration())
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, err
	}
	current, config, err := configuration(tx)
	if err != nil {
		return nil, err
	}
	if current != nil && config.Revision >= after && (len(result.Configurations) == 0 || !bytes.Equal(result.Configurations[len(result.Configurations)-1].Configuration, current.Configuration)) {
		result.Configurations = append(result.Configurations, current)
	}
	return result, nil
}
func nextTrustUpdate(tx *sql.Tx, p peer, seen map[string][]byte) (*pb.TrustUpdate, error) {
	rows, err := tx.Query(`SELECT u.kind,u.revision,u.value FROM trust_updates u JOIN update_devices d ON d.kind=u.kind AND d.revision=u.revision WHERE d.spki=? AND d.receipt IS NULL ORDER BY u.kind,u.revision`, p.spki)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var kind int
		var revision string
		var raw []byte
		if err = rows.Scan(&kind, &revision, &raw); err != nil {
			return nil, err
		}
		update := new(pb.TrustUpdate)
		if err = proto.Unmarshal(raw, update); err != nil {
			return nil, err
		}
		if changed(seen, fmt.Sprintf("trust:%d:%s", kind, revision), update) {
			return update, nil
		}
	}
	return nil, rows.Err()
}
func publishUpdateReceipt(tx *sql.Tx, p peer, signed *pb.SignedUpdateReceipt) error {
	statement := new(pb.UpdateReceipt)
	if signed == nil || proto.Unmarshal(signed.Receipt, statement) != nil {
		return invalid("Invalid update receipt.")
	}
	target := &pb.UpdateReceiptQuery{Kind: statement.Kind, Revision: statement.Revision, UpdateSha256: statement.UpdateSha256}
	if err := relaycrypto.VerifyUpdateReceipt(p.spki, signed, target); err != nil {
		return denied(err.Error())
	}
	var hash []byte
	err := tx.QueryRow("SELECT hash FROM trust_updates WHERE kind=? AND revision=?", target.Kind, revisionID(target.Revision)).Scan(&hash)
	if errors.Is(err, sql.ErrNoRows) {
		// Grants and already-pruned confirmations need no receipt history. An ACK
		// only drains the sender's outbox; it is never evidence for the owner.
		return nil
	}
	if err != nil {
		return err
	}
	if !bytes.Equal(hash, target.UpdateSha256) {
		return denied("Receipt hash does not match the saved update.")
	}
	_, err = tx.Exec("UPDATE update_devices SET receipt=COALESCE(receipt,?) WHERE kind=? AND revision=? AND spki=?", marshal(signed), target.Kind, revisionID(target.Revision), p.spki)
	if err != nil {
		return err
	}
	// A device enrolled later may routinely receipt its cached key set. Its
	// signature cannot fulfil any other device's original obligation.
	return settleWithdrawals(tx)
}
func getUpdateReceipts(tx *sql.Tx, query *pb.UpdateReceiptQuery) (*pb.UpdateReceipts, error) {
	result := new(pb.UpdateReceipts)
	rows, err := tx.Query(`SELECT d.receipt FROM update_devices d JOIN trust_updates u ON u.kind=d.kind AND u.revision=d.revision WHERE u.kind=? AND u.revision=? AND u.hash=? AND d.receipt IS NOT NULL ORDER BY d.spki`, query.Kind, revisionID(query.Revision), query.UpdateSha256)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var raw []byte
		if err = rows.Scan(&raw); err != nil {
			return nil, err
		}
		receipt := new(pb.SignedUpdateReceipt)
		if err = proto.Unmarshal(raw, receipt); err != nil {
			return nil, err
		}
		result.Receipts = append(result.Receipts, receipt)
	}
	return result, rows.Err()
}

func acknowledgeUpdateReceipts(tx *sql.Tx, p peer, target *pb.UpdateReceiptQuery) error {
	_, keys, err := currentKeys(tx)
	if err != nil {
		return err
	}
	if p.approver != keys.RuleOwnerKeyId {
		return denied("Only the rule owner may acknowledge collected device receipts.")
	}
	if target == nil || target.Revision == 0 || len(target.UpdateSha256) != 32 || (target.Kind != pb.UpdateKind_UPDATE_KIND_APPROVER_KEYS && target.Kind != pb.UpdateKind_UPDATE_KIND_CONFIGURATION) {
		return invalid("Acknowledgement must name an exact permission update.")
	}
	var hash []byte
	var completed sql.NullInt64
	err = tx.QueryRow("SELECT hash,completed FROM trust_updates WHERE kind=? AND revision=?", target.Kind, revisionID(target.Revision)).Scan(&hash, &completed)
	if errors.Is(err, sql.ErrNoRows) {
		return nil // Idempotent after completed evidence has already been pruned.
	}
	if err != nil {
		return err
	}
	if !bytes.Equal(hash, target.UpdateSha256) {
		return denied("Acknowledgement hash does not match the saved update.")
	}
	if !completed.Valid {
		return denied("Device confirmations for this update are not complete.")
	}
	_, err = tx.Exec("UPDATE trust_updates SET collected=COALESCE(collected,?) WHERE kind=? AND revision=?", time.Now().Unix(), target.Kind, revisionID(target.Revision))
	return err
}
