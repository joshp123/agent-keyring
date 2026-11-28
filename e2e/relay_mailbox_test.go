// Written by AI on 2026.11.23 by model claude opus 5.5.
package e2e

import (
	"bytes"
	"testing"

	"github.com/opentrawl/agent-keyring/internal/box"
)

// At this scale an answer lasts 12 seconds and a grant lasts 54 seconds.
const boxLifetimes = "0.02"

func TestRelayReplacesAndConsumesMultiChunkMailbox(t *testing.T) {
	address := startRelay(t)

	ctx := t.Context()
	boxes, seed := box.NewRelayBoxClient(address), bytes.Repeat([]byte{7}, 32)
	slot, key := box.DeriveUpdateMailboxSlot(seed, "test-device"), box.DeriveUpdateMailboxKey(seed)
	options := box.RelayBoxPutOptions{TTL: box.TTLUpdate, Mode: box.ModeReplace, ReadAuth: box.GenerateBoxAuthToken(), WriteAuth: box.GenerateBoxAuthToken()}
	// An update larger than one box is read back whole, the newer of two writes.
	for _, fill := range []byte{1, 2} {
		body := bytes.Repeat([]byte{fill}, 400<<10)
		if err := boxes.PutRelayBox(ctx, slot, key, body, options); err != nil {
			t.Fatalf("put %d: %v", fill, err)
		}
	}
	picked, err := boxes.FetchRelayBox(ctx, slot, key, options.ReadAuth)
	if err != nil || picked == nil || !bytes.Equal(picked.Message, bytes.Repeat([]byte{2}, 400<<10)) {
		t.Fatalf("get: %v, found %t", err, picked != nil)
	}
	if err := boxes.AcknowledgeRelayBox(ctx, picked, options.ReadAuth); err != nil {
		t.Fatal(err)
	}
	if again, err := boxes.FetchRelayBox(ctx, slot, key, options.ReadAuth); again != nil || err != nil {
		t.Fatalf("still there after it was read and deleted: %v", err)
	}
}

func checkRelayLogs(t *testing.T, relay *lineProcess, readiness string) {
	t.Helper()
	relay.stopLineProcess()
	if got := relay.stderr.String(); got != "" {
		t.Errorf("relay wrote to stderr: %s", got)
	}
	if got := relay.stdout.String(); got != readiness+"\n" {
		t.Errorf("relay printed more than its address")
	}
}
