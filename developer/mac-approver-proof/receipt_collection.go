// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
)

func (p *proof) receiptSQL(statement string) string {
	output, err := exec.Command("/usr/bin/sqlite3", filepath.Join(p.root, "relay", "relay.sqlite"), statement).CombinedOutput()
	require(err == nil, string(output))
	return strings.TrimSpace(string(output))
}

func (p *proof) collectAfterOfflineOwner(target *pb.UpdateReceiptQuery, id string, network *approvalNetwork) {
	p.owner.stop()
	p.runReceiverRemovalCheck(true)
	p.runReceiverRemovalCheck(true)
	where := fmt.Sprintf("kind=%d AND revision='%020d'", target.Kind, target.Revision)
	require(p.receiptSQL("SELECT completed IS NOT NULL AND collected IS NULL FROM trust_updates WHERE "+where) == "1", "offline owner target did not complete without collection")
	p.receiptSQL(fmt.Sprintf("UPDATE trust_updates SET completed=%d WHERE %s", time.Now().Add(-8*24*time.Hour).Unix(), where))
	p.stopRelay()
	p.startRelay()
	require(p.receiptSQL("SELECT COUNT(*) FROM trust_updates WHERE "+where) == "1", "relay discarded uncollected evidence after eight simulated days")
	p.owner = startOwner(p.fixture, p.root)
	p.owner.wait(func(event []string) bool { return event[0] == "WITHDRAWAL" && event[1] == id && event[4] == "true" })
	network.Lock()
	network.loseReply = true
	network.Unlock()
	var collected string
	for deadline := time.Now().Add(30 * time.Second); ; {
		collected = p.receiptSQL("SELECT COALESCE(collected,0) FROM trust_updates WHERE " + where)
		if collected != "0" && collected != "" {
			break
		}
		require(time.Now().Before(deadline), "Swift Mac did not acknowledge saved complete evidence")
		time.Sleep(50 * time.Millisecond)
	}
	p.owner.action("saved")
	ackID := "receipt-collection:" + id
	hash := p.owner.saved[ackID]
	require(hash != "", "lost collection ACK was not retained in the Mac outbox")
	p.owner.stop()
	p.stopRelay()
	network.Lock()
	network.loseReply, network.pauseNewCalls = false, true
	network.Unlock()
	p.startRelay()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.action("saved")
	require(p.owner.withdrawals[id].complete && p.owner.saved[ackID] == hash, "restart lost complete evidence or changed its queued collection acknowledgement")
	network.Lock()
	network.pauseNewCalls = false
	network.Unlock()
	p.waitApplied()
	require(p.receiptSQL("SELECT collected FROM trust_updates WHERE "+where) == collected, "collection retry reset the relay retention clock")
	fmt.Println("PASS actual Swift Mac collects verified evidence after eight simulated offline days; durable collection ACK survives a lost reply and Mac/relay restart without resetting retention")
}
