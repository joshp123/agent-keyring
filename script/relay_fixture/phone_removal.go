// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func phoneCheckpoint(directory, field string) ([]byte, error) {
	return exec.Command("/usr/bin/plutil", "-extract", field, "raw", "-o", "-", filepath.Join(directory, "approver", "phone-answers-v3.plist")).Output()
}

func phoneCheckpointKeys(directory string) *pb.ApproverKeySet {
	value, err := phoneCheckpoint(directory, "keySet")
	must(err)
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(value)))
	must(err)
	var signed pb.SignedApproverKeySet
	must(proto.Unmarshal(raw, &signed))
	var keys pb.ApproverKeySet
	must(proto.Unmarshal(signed.KeySet, &keys))
	return &keys
}

// The stopped real relay is deliberately made stale; all payload signatures
// still come from the real fixture owner. No phone checkpoint is edited.
func restorePhoneProofKeys(directory string, keys *pb.SignedApproverKeySet, hideNewer bool) {
	db, err := sql.Open("sqlite", filepath.Join(directory, "relay", "relay.sqlite"))
	must(err)
	defer db.Close()
	_, err = db.Exec("UPDATE objects SET value=? WHERE kind='current' AND id='keys'", encoded(keys))
	must(err)
	var set pb.ApproverKeySet
	must(proto.Unmarshal(keys.KeySet, &set))
	_, err = db.Exec("INSERT OR REPLACE INTO objects(kind,id,value) VALUES('keychain',?,?)", fmt.Sprintf("%020d", set.Revision), encoded(keys))
	must(err)
	if hideNewer {
		_, err = db.Exec("DELETE FROM objects WHERE kind='keychain' AND id>?", fmt.Sprintf("%020d", set.Revision))
		must(err)
	}
}

func (p *proof) swiftRemovalProof(phone *phoneProcess, key *pb.ApproverKey, network *phoneNetwork, directory string) {
	defer func() { phone.stop() }()
	phone.command("stop")
	// A valid key-set advance must survive a subsequent invalid config fetch.
	previous := p.keys
	var advanced pb.ApproverKeySet
	must(proto.Unmarshal(previous.KeySet, &advanced))
	advanced.Revision++
	raw := encoded(&advanced)
	p.keys = &pb.SignedApproverKeySet{KeySet: raw, Signature: sign(p.signer, raw), SignerKeyId: p.key.KeyId}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
	p.stop()
	invalid := proto.Clone(p.signedConfiguration).(*pb.SignedConfiguration)
	invalid.Signature = []byte("invalid signature")
	replacePhoneProofConfiguration(p.directory, invalid)
	p.start()
	require(strings.HasPrefix(phone.command("refresh"), "ERROR"), "invalid configuration was accepted")
	require(phoneCheckpointKeys(directory).Revision == advanced.Revision, "failed configuration fetch discarded verified key-set advance")
	p.stop()
	restorePhoneProofKeys(p.directory, previous, true)
	replacePhoneProofConfiguration(p.directory, p.signedConfiguration)
	p.start()
	phone.stop()
	phone = startPhone(phone.cmd.Path, directory)
	phone.command("stop")
	require(phone.command("refresh") == "REFRESHED" && phoneCheckpointKeys(directory).Revision == advanced.Revision, "stale relay undid saved key-set advance after restart")
	p.stop()
	restorePhoneProofKeys(p.directory, p.keys, false)
	p.start()
	fmt.Println("PASS actual Swift phone saves verified keys before a failing configuration fetch; restart and stale relay cannot lower the saved key revision")

	// Keep a sealed copy and an authenticated answer whose ACK was lost.
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	phone.command("start")
	lease := good(p.client.call(leaseRequest("removed-phone", "removed-phone-task", p.enrolled.RecipientId))).GetClient().GetLease()
	record := p.phoneRequest(lease.LeaseId)
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: lease.LeaseId, Record: record}}}))
	id := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", record))
	phone.wait("requests", id+"=waitingForYou")
	phone.command("stop")
	countPath := filepath.Join(directory, "authorization-count")
	count, err := os.ReadFile(countPath)
	must(err)
	before, err := strconv.Atoi(string(count))
	must(err)
	hold := filepath.Join(directory, "hold-authorization")
	must(os.WriteFile(hold, []byte("hold"), 0600))
	phone.send("approve\t" + id)
	deadline := time.Now().Add(20 * time.Second)
	for {
		count, err = os.ReadFile(countPath)
		must(err)
		if string(count) == strconv.Itoa(before+1) {
			break
		}
		require(time.Now().Before(deadline), "removal fixture did not reach authorization")
		time.Sleep(20 * time.Millisecond)
	}
	network.Lock()
	network.loseReply = true
	network.Unlock()
	must(os.Rename(hold, hold+".released"))
	for {
		current := good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: lease.LeaseId}}}))).GetClient().GetLease()
		if current.State == pb.LeaseState_LEASE_STATE_ACTIVE {
			break
		}
		require(time.Now().Before(deadline), "answer did not reach relay before lost ACK")
		time.Sleep(20 * time.Millisecond)
	}
	network.down()
	require(strings.Contains(phone.line(), "sendingAnswer"), "answer ACK was not lost")
	network.Lock()
	network.loseReply = false
	network.Unlock()
	network.up()
	_, err = phoneCheckpoint(directory, "copy.signedUpdate")
	must(err)
	_, err = phoneCheckpoint(directory, "outbox.0")
	must(err)
	previous = p.keys
	removed := proto.Clone(&advanced).(*pb.ApproverKeySet)
	removed.Revision++
	removed.Keys = nil
	for _, candidate := range advanced.Keys {
		if candidate.KeyId != key.KeyId {
			removed.Keys = append(removed.Keys, candidate)
		}
	}
	raw = encoded(removed)
	removal := &pb.SignedApproverKeySet{KeySet: raw, Signature: sign(p.signer, raw), SignerKeyId: p.key.KeyId}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: removal}}))
	p.stop()
	// An honest relay keeps removed identities as read-only update recipients.
	p.start()
	failure := phone.command("refresh")
	require(strings.Contains(failure, "no longer an approver"), "phone did not reject its own removal: "+failure)
	require(phoneCheckpointKeys(directory).Revision == removed.Revision, "phone forgot its verified removal")
	for _, field := range []string{"copy", "configuration", "outbox.0"} {
		_, err := phoneCheckpoint(directory, field)
		require(err != nil, "removed phone retained "+field)
	}
	require(phone.command("requests") == "REQUESTS\t", "removed phone retained pending answers/history")
	p.stop()
	restorePhoneProofKeys(p.directory, previous, true)
	p.start()
	for iteration := 0; iteration < 2; iteration++ {
		require(strings.Contains(phone.command("refresh"), "no longer an approver"), "stale relay restored removed phone")
		require(phoneCheckpointKeys(directory).Revision == removed.Revision, "stale relay lowered the removal floor")
		after, err := os.ReadFile(countPath)
		must(err)
		require(bytes.Equal(count, after), "removal or rollback asked for authorization")
		phone.stop()
		phone = startPhone(phone.cmd.Path, directory)
		require(strings.Contains(phone.command("status"), "notPaired"), "removed phone reopened as paired")
	}
	fmt.Println("PASS actual Swift phone durably learns its own removal, clears sealed copy and queued signed answer, and stays removed after restart when the real relay serves old signed data; no authorization")
}
