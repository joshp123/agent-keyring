// Written by AI on 2026.11.24 by model claude opus 5.5.
package remote

import (
	"cmp"
	"context"
	"strconv"
	"sync"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/box"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"google.golang.org/protobuf/proto"
)

// mailboxLimit is the longest a command waits on the update mailbox: a relay
// out of reach must never hold up an agent, which then uses what it holds.
const mailboxLimit = 1500 * time.Millisecond

// readMailbox reads this computer's update mailbox (keyring.proto, "Update
// mailboxes"): every Mac's and iPhone's slot at once, within mailboxLimit.
// Each bundle found is checked and saved as one from an answer is, and only
// then deleted, so one cut off on the way is read again next time. If taking
// a bundle adds new Mac or iPhone devices to Members, their slots are also
// read in the same pass while budget remains.
func (c *RemoteKeyringClient) readMailbox(ctx context.Context, state *clientstate.State) {
	members, err := parseMembers(state.Members)
	if err != nil {
		return
	}
	relay, err := box.ValidateRelayBoxURL(cmp.Or(state.BoxUrl, box.DefaultURL), loopbackTest())
	if err != nil {
		return
	}
	mailbox, boxes := state.Mailbox, box.NewRelayBoxClient(relay)
	readCtx, cancel := context.WithTimeout(ctx, mailboxLimit)
	defer cancel()
	seen := map[string]bool{}
	for readCtx.Err() == nil {
		batch := mailboxDevices(members, seen)
		if len(batch) == 0 {
			return
		}
		found := c.fetchMailboxSlots(readCtx, boxes, mailbox, batch)
		if !c.applyMailboxSlots(ctx, boxes, mailbox.ReadAuth, batch, found) {
			return
		}
		latest, err := c.Store.LoadClientState(ctx)
		if err != nil || latest.Removed {
			return
		}
		members, err = parseMembers(latest.Members)
		if err != nil {
			return
		}
	}
}

func mailboxDevices(members *pb.Members, seen map[string]bool) []*pb.Device {
	var batch []*pb.Device
	for _, device := range members.Devices {
		if (device.Kind != pb.DeviceKind_DEVICE_KIND_MAC && device.Kind != pb.DeviceKind_DEVICE_KIND_IPHONE) || seen[device.KeyId] {
			continue
		}
		seen[device.KeyId] = true
		batch = append(batch, device)
	}
	return batch
}

func (c *RemoteKeyringClient) fetchMailboxSlots(readCtx context.Context, boxes *box.RelayBoxClient, mailbox *pb.UpdateMailbox, batch []*pb.Device) []*box.FetchedBoxMessage {
	key := box.DeriveUpdateMailboxKey(mailbox.Seed)
	var wg sync.WaitGroup
	found := make([]*box.FetchedBoxMessage, len(batch))
	for i, device := range batch {
		wg.Add(1)
		go func(i int, label, slot string) {
			defer wg.Done()
			picked, err := boxes.FetchRelayBox(readCtx, slot, key, mailbox.ReadAuth)
			if err != nil && readCtx.Err() == nil {
				c.appendRemoteEventLog("mailbox not read device=" + strconv.Quote(label) + " error=" + strconv.Quote(err.Error()))
			}
			found[i] = picked
		}(i, device.Label, box.DeriveUpdateMailboxSlot(mailbox.Seed, device.KeyId))
	}
	wg.Wait()
	return found
}

func (c *RemoteKeyringClient) applyMailboxSlots(ctx context.Context, boxes *box.RelayBoxClient, readAuth string, batch []*pb.Device, found []*box.FetchedBoxMessage) bool {
	updated := false
	for i, picked := range found {
		if picked == nil {
			continue
		}
		bundle := &pb.Bundle{}
		if err := proto.Unmarshal(picked.Message, bundle); err != nil {
			c.appendRemoteEventLog("mailbox unreadable device=" + strconv.Quote(batch[i].Label))
		} else if err := c.keepBundle(ctx, bundle, true); err != nil {
			c.appendRemoteEventLog("mailbox not kept device=" + strconv.Quote(batch[i].Label) + " error=" + strconv.Quote(err.Error()))
			continue
		} else {
			updated = true
			c.appendRemoteEventLog("mailbox taken device=" + strconv.Quote(batch[i].Label))
		}
		doneCtx, doneCancel := context.WithTimeout(context.WithoutCancel(ctx), mailboxLimit)
		if err := boxes.AcknowledgeRelayBox(doneCtx, picked, readAuth); err != nil {
			c.appendRemoteEventLog("mailbox not deleted device=" + strconv.Quote(batch[i].Label) + " error=" + strconv.Quote(err.Error()))
		}
		doneCancel()
	}
	return updated
}
