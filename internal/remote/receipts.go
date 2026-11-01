// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package remote

import (
	"bytes"
	"context"
	"crypto"
	"errors"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func (c *Client) saveTrustUpdate(ctx context.Context, update *pb.TrustUpdate) error {
	target, err := relaycrypto.UpdateTarget(update)
	if err != nil {
		return err
	}
	signer, ok := c.Certificate.PrivateKey.(crypto.Signer)
	if !ok {
		return errors.New("TLS identity cannot authenticate update receipts.")
	}
	return c.Store.Update(ctx, func(state *clientstate.State) error {
		switch value := update.Update.(type) {
		case *pb.TrustUpdate_ApproverKeys:
			current, e := keySet(state.Approvers)
			if e != nil {
				return e
			}
			if target.Revision < current.Revision {
				return errors.New("The relay replayed an older approver update.")
			}
			if target.Revision == current.Revision {
				if !bytes.Equal(value.ApproverKeys.KeySet, state.Approvers.KeySet) || value.ApproverKeys.SignerKeyId != state.Approvers.SignerKeyId {
					return errors.New("The relay returned conflicting approver keys.")
				}
			} else if e = advanceKeys(state, &pb.ApproverKeyChain{KeySets: []*pb.SignedApproverKeySet{value.ApproverKeys}}); e != nil {
				return e
			}
		case *pb.TrustUpdate_Configuration:
			if _, e := verifyConfiguration(state, value.Configuration); e != nil {
				return e
			}
			state.Configuration = proto.Clone(value.Configuration).(*pb.SignedConfiguration)
		}
		for _, pending := range state.PendingUpdateReceipts {
			receipt := new(pb.UpdateReceipt)
			if proto.Unmarshal(pending.Receipt, receipt) != nil {
				return errors.New("Invalid saved update receipt.")
			}
			if receipt.Kind == target.Kind && receipt.Revision == target.Revision && bytes.Equal(receipt.UpdateSha256, target.UpdateSha256) {
				return nil
			}
		}
		receipt, e := relaycrypto.SignUpdateReceipt(signer, target)
		if e != nil {
			return e
		}
		state.PendingUpdateReceipts = append(state.PendingUpdateReceipts, receipt)
		return nil
	})
}
func (c *Client) flushUpdateReceipts(ctx context.Context) error {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return err
	}
	for _, receipt := range state.PendingUpdateReceipts {
		response, e := c.call(ctx, &pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishUpdateReceipt{PublishUpdateReceipt: receipt}})
		if e != nil {
			return e
		}
		if !response.GetPublish().GetAccepted() {
			return errors.New("The relay did not acknowledge the saved device receipt.")
		}
		if e = c.Store.Update(ctx, func(current *clientstate.State) error {
			var remaining []*pb.SignedUpdateReceipt
			for _, pending := range current.PendingUpdateReceipts {
				if !bytes.Equal(pending.Receipt, receipt.Receipt) {
					remaining = append(remaining, pending)
				}
			}
			current.PendingUpdateReceipts = remaining
			return nil
		}); e != nil {
			return e
		}
	}
	return nil
}
