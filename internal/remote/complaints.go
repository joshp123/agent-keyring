// Written by AI on 2026.11.21 by model claude opus 5.5.
package remote

import (
	"context"
	"net/http"
	"strconv"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"google.golang.org/protobuf/proto"
)

const ComplaintDomain = "agentkeyring.complaint.v2"

// Complain files an agent's complaint with the Mac. It is kept here first,
// so one the Mac cannot take now goes at the next contact with its door.
// sent is false if it is waiting here.
func (c *Client) Complain(ctx context.Context, complaint *pb.Complaint) (sent bool, err error) {
	complaint.Domain, complaint.Computer = ComplaintDomain, c.label
	raw, err := proto.Marshal(complaint)
	if err != nil {
		return false, err
	}
	if err := c.Store.Update(ctx, func(state *clientstate.State) error {
		state.Complaints = append(state.Complaints, raw)
		return nil
	}); err != nil {
		return false, err
	}
	sendCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return c.sendComplaints(sendCtx) == nil, nil
}

// sendComplaints gives the Mac every complaint waiting here, oldest first,
// and forgets each it takes.
func (c *Client) sendComplaints(ctx context.Context) error {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return err
	}
	for _, raw := range state.Complaints {
		complaint := &pb.Complaint{}
		if proto.Unmarshal(raw, complaint) == nil {
			if err := c.mac(ctx, http.MethodPost, "/v2/complaint", complaint, nil); err != nil {
				return err
			}
		}
		if err := c.Store.Update(ctx, func(state *clientstate.State) error {
			if len(state.Complaints) > 0 && string(state.Complaints[0]) == string(raw) {
				state.Complaints = state.Complaints[1:]
			}
			return nil
		}); err != nil {
			return err
		}
		c.log("complaint sent")
	}
	return nil
}

// Complaints is what agents have complained about since then, from the Mac.
func (c *Client) Complaints(ctx context.Context, since int64) ([]*pb.Complaint, error) {
	result := &pb.Complaints{}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	err := c.mac(ctx, http.MethodGet, "/v2/complaints?since="+strconv.FormatInt(since, 10), nil, result)
	return result.Complaints, err
}
