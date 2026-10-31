// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relay

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

type Store struct {
	mu      sync.Mutex
	db      *sql.DB
	changed chan struct{}
}

func OpenStore(directory string) (*Store, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(directory, 0700); err != nil {
		return nil, err
	}
	path := filepath.Join(directory, "relay.sqlite")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	file.Close()
	if err = os.Chmod(path, 0600); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;
 CREATE TABLE IF NOT EXISTS objects(kind TEXT NOT NULL,id TEXT NOT NULL,value BLOB NOT NULL,PRIMARY KEY(kind,id));
 CREATE TABLE IF NOT EXISTS enrolments(id TEXT PRIMARY KEY,spki BLOB UNIQUE NOT NULL,node TEXT NOT NULL,state INTEGER NOT NULL,record BLOB NOT NULL,decision BLOB,keyset BLOB NOT NULL);
 CREATE TABLE IF NOT EXISTS pairings(id TEXT PRIMARY KEY,node TEXT NOT NULL,request BLOB NOT NULL,keyset BLOB NOT NULL,created INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS leases(id TEXT PRIMARY KEY,recipient TEXT NOT NULL,request BLOB NOT NULL,lease BLOB NOT NULL,decision BLOB,bundle BLOB);
 CREATE TABLE IF NOT EXISTS aliases(recipient TEXT NOT NULL,id TEXT NOT NULL,lease TEXT NOT NULL,request BLOB NOT NULL,PRIMARY KEY(recipient,id));
 CREATE TABLE IF NOT EXISTS phone_escalations(lease TEXT PRIMARY KEY,owner TEXT NOT NULL,record BLOB NOT NULL,local_lease BLOB,answer BLOB);
 CREATE TABLE IF NOT EXISTS push_attempts(lease TEXT NOT NULL,phone TEXT NOT NULL,sent INTEGER NOT NULL DEFAULT 0,retry_at INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(lease,phone));
 CREATE TABLE IF NOT EXISTS local_leases(id TEXT PRIMARY KEY,owner TEXT NOT NULL,request BLOB NOT NULL,lease BLOB NOT NULL,deadline INTEGER,delete_after INTEGER);
 DROP TABLE IF EXISTS operations;`)
	if err != nil {
		db.Close()
		return nil, err
	}
	// Existing unreleased relay stores keep their lease and enrolment records.
	for _, column := range []struct{ table, name, declaration string }{
		{"leases", "deadline", "INTEGER"}, {"leases", "delete_after", "INTEGER"}, {"leases", "decision_hash", "BLOB"},
		{"enrolments", "expires", "INTEGER"}, {"pairings", "expires", "INTEGER"},
	} {
		rows, queryErr := db.Query("SELECT name FROM pragma_table_info(?)", column.table)
		if queryErr != nil {
			db.Close()
			return nil, queryErr
		}
		present := false
		for rows.Next() {
			var name string
			if queryErr = rows.Scan(&name); queryErr != nil {
				break
			}
			present = present || name == column.name
		}
		if queryErr == nil {
			queryErr = rows.Err()
		}
		rows.Close()
		if queryErr == nil && !present {
			_, queryErr = db.Exec("ALTER TABLE " + column.table + " ADD COLUMN " + column.name + " " + column.declaration)
		}
		if queryErr != nil {
			db.Close()
			return nil, queryErr
		}
	}
	_, err = db.Exec(`CREATE INDEX IF NOT EXISTS lease_deadlines ON leases(deadline) WHERE deadline IS NOT NULL;
 CREATE INDEX IF NOT EXISTS lease_history ON leases(delete_after) WHERE delete_after IS NOT NULL;
 CREATE INDEX IF NOT EXISTS enrolment_deadlines ON enrolments(expires) WHERE expires IS NOT NULL;
 CREATE INDEX IF NOT EXISTS pairing_deadlines ON pairings(expires) WHERE expires IS NOT NULL;
 CREATE INDEX IF NOT EXISTS local_deadlines ON local_leases(deadline) WHERE deadline IS NOT NULL;
 CREATE INDEX IF NOT EXISTS local_history ON local_leases(delete_after) WHERE delete_after IS NOT NULL;`)
	if err != nil {
		db.Close()
		return nil, err
	}
	store := &Store{db: db, changed: make(chan struct{})}
	// Populate deadline indexes once when opening a store from the earlier contract.
	tx, before, err := store.begin()
	if err != nil {
		db.Close()
		return nil, err
	}
	defer tx.Rollback()
	leases, err := queryLeases(tx, "SELECT lease FROM leases WHERE deadline IS NULL AND delete_after IS NULL")
	if err == nil {
		for _, lease := range leases {
			if err = saveLease(tx, lease); err != nil {
				break
			}
		}
	}
	if err == nil {
		err = initializeSetupDeadlines(tx)
	}
	if err == nil {
		err = store.commit(tx, before)
	}
	if err != nil {
		db.Close()
		return nil, err
	}
	return store, nil
}
func (s *Store) Close() error { return s.db.Close() }
func marshal(message proto.Message) []byte {
	data, err := proto.Marshal(message)
	if err != nil {
		panic(err)
	}
	return data
}
func get(tx *sql.Tx, kind, id string, message proto.Message) error {
	var value []byte
	err := tx.QueryRow("SELECT value FROM objects WHERE kind=? AND id=?", kind, id).Scan(&value)
	if err != nil {
		return err
	}
	return proto.Unmarshal(value, message)
}
func put(tx *sql.Tx, kind, id string, message proto.Message) error {
	_, err := tx.Exec("INSERT INTO objects VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET value=excluded.value", kind, id, marshal(message))
	return err
}
func currentKeys(tx *sql.Tx) (*pb.SignedApproverKeySet, *pb.ApproverKeySet, error) {
	signed := new(pb.SignedApproverKeySet)
	err := get(tx, "current", "keys", signed)
	if err != nil {
		return nil, nil, err
	}
	keys := new(pb.ApproverKeySet)
	err = proto.Unmarshal(signed.KeySet, keys)
	return signed, keys, err
}
func keyByID(keys *pb.ApproverKeySet, id string) *pb.ApproverKey {
	for _, key := range keys.GetKeys() {
		if key.KeyId == id {
			return key
		}
	}
	return nil
}
func configuration(tx *sql.Tx) (*pb.SignedConfiguration, *pb.Configuration, error) {
	signed := new(pb.SignedConfiguration)
	err := get(tx, "current", "configuration", signed)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, &pb.Configuration{}, nil
	}
	if err != nil {
		return nil, nil, err
	}
	value := new(pb.Configuration)
	err = proto.Unmarshal(signed.Configuration, value)
	return signed, value, err
}
func loginByID(configuration *pb.Configuration, id string) *pb.Login {
	for _, login := range configuration.GetLogins() {
		if login.LoginId == id {
			return login
		}
	}
	return nil
}
func machineByID(configuration *pb.Configuration, id string) *pb.EnrolledMachine {
	for _, machine := range configuration.GetMachines() {
		if machine.RecipientId == id {
			return machine
		}
	}
	return nil
}
func (s *Store) begin() (*sql.Tx, int64, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, 0, err
	}
	var changes int64
	if err = tx.QueryRow("SELECT total_changes()").Scan(&changes); err != nil {
		tx.Rollback()
		return nil, 0, err
	}
	return tx, changes, nil
}
func (s *Store) commit(tx *sql.Tx, before int64) error {
	var after int64
	if err := tx.QueryRow("SELECT total_changes()").Scan(&after); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	if after != before {
		close(s.changed)
		s.changed = make(chan struct{})
	}
	return nil
}
func invalid(message string) error {
	return &rpcError{pb.RpcErrorCode_RPC_ERROR_CODE_INVALID_ARGUMENT, message}
}
func denied(message string) error {
	return &rpcError{pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, message}
}
func conflict(message string) error {
	return &rpcError{pb.RpcErrorCode_RPC_ERROR_CODE_CONFLICT, message}
}
func missing(message string) error {
	return &rpcError{pb.RpcErrorCode_RPC_ERROR_CODE_NOT_FOUND, message}
}

type rpcError struct {
	code    pb.RpcErrorCode
	message string
}

func (e *rpcError) Error() string { return e.message }
func wireError(err error) *pb.RelayWireResponse {
	code := pb.RpcErrorCode_RPC_ERROR_CODE_INTERNAL
	message := "Relay storage failed; rejoin the same request."
	var rpc *rpcError
	if errors.As(err, &rpc) {
		code = rpc.code
		message = rpc.message
	}
	return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Error{Error: &pb.RpcError{Code: code, Message: message}}, EndOfStream: true}
}
func publishAck() *pb.RelayWireResponse {
	return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Publish{Publish: &pb.PublishAck{Accepted: true}}, EndOfStream: true}
}
func enrolAck() *pb.RelayWireResponse {
	return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Enrolment{Enrolment: &pb.EnrolmentAck{Accepted: true}}, EndOfStream: true}
}
func revisionID(revision uint64) string { return fmt.Sprintf("%020d", revision) }

func initializeSetupDeadlines(tx *sql.Tx) error {
	rows, err := tx.Query("SELECT record FROM enrolments WHERE state<>1 AND expires IS NULL")
	if err != nil {
		return err
	}
	var pending []*pb.EnrolmentRecord
	for rows.Next() {
		var raw []byte
		if err = rows.Scan(&raw); err != nil {
			break
		}
		record := new(pb.EnrolmentRecord)
		if err = proto.Unmarshal(raw, record); err != nil {
			break
		}
		pending = append(pending, record)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return err
	}
	for _, record := range pending {
		if _, err = tx.Exec("UPDATE enrolments SET expires=? WHERE id=?", record.CreatedUnixSeconds+600, record.RecipientId); err != nil {
			return err
		}
	}
	_, keys, err := currentKeys(tx)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	// Current pairings retain the stable tailnet node used for authentication.
	rows, err = tx.Query("SELECT id FROM pairings WHERE expires IS NULL")
	if err != nil {
		return err
	}
	var unpaired []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			break
		}
		if keyByID(keys, id) == nil {
			unpaired = append(unpaired, id)
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return err
	}
	for _, id := range unpaired {
		if _, err = tx.Exec("UPDATE pairings SET expires=created+600 WHERE id=?", id); err != nil {
			return err
		}
	}
	return nil
}
