// Written by AI on 2026.11.21 by model claude opus 5.5; kept here, not sent to the Mac, on 2026.11.24.
package remote

import (
	"context"
	"fmt"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"google.golang.org/protobuf/proto"
)

const ComplaintDomain = "agentkeyring.complaint.v2"

const (
	keptComplaints     = 5000
	MaxComplaintsBytes = 2 << 20
)

// RecordRemoteComplaint keeps an agent's complaint in this computer's state, for
// whoever builds Agent Keyring to read with ReadRemoteComplaints. It goes nowhere else.
func (c *RemoteKeyringClient) RecordRemoteComplaint(ctx context.Context, complaint *pb.Complaint) error {
	complaint.Domain, complaint.Computer = ComplaintDomain, c.label
	raw, err := proto.Marshal(complaint)
	if err != nil {
		return err
	}
	complaints := &clientstate.State{Complaints: [][]byte{raw}}
	if proto.Size(complaints) > MaxComplaintsBytes {
		return fmt.Errorf("The complaint exceeds the %d MiB storage limit.", MaxComplaintsBytes>>20)
	}
	if err := c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		state.Complaints = append(state.Complaints, raw)
		first := len(state.Complaints)
		size := 0
		for first > 0 && len(state.Complaints)-first < keptComplaints {
			complaints.Complaints = state.Complaints[first-1 : first]
			size += proto.Size(complaints)
			if size > MaxComplaintsBytes {
				break
			}
			first--
		}
		state.Complaints = state.Complaints[first:]
		return nil
	}); err != nil {
		return err
	}
	c.appendRemoteEventLog("complaint kept")
	return nil
}

// ReadRemoteComplaints is what agents on this computer have complained about since then, oldest first.
func (c *RemoteKeyringClient) ReadRemoteComplaints(ctx context.Context, since int64) ([]*pb.Complaint, error) {
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return nil, err
	}
	var found []*pb.Complaint
	for _, raw := range state.Complaints {
		complaint := &pb.Complaint{}
		if proto.Unmarshal(raw, complaint) == nil && complaint.AtUnixSeconds >= since {
			found = append(found, complaint)
		}
	}
	return found, nil
}
