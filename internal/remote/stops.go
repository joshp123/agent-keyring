// Written by AI on 2026.11.21 by model claude opus 5.5.
package remote

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"google.golang.org/protobuf/proto"
)

// checkStopAtMac runs before every use of an approval (read, fill, the pipe).
// When no process here held the door, a device's Stop could not reach it, so
// the device left it at the Mac (POST /v2/stop). This asks the Mac for one,
// within half a second, as the Automatic freshness check does. A Stop there,
// checked against this computer's Members and naming exactly this request,
// ends the approval as a Stop at the door would. If the Mac cannot be asked,
// the use goes ahead and the log says so (docs/state-machines.md, "A Stop
// left at the Mac").
func (c *Client) checkStopAtMac(ctx context.Context, leaseID string) error {
	signed := &pb.Signed{}
	askCtx, cancel := context.WithTimeout(ctx, automaticLimit)
	err := c.mac(askCtx, http.MethodGet, "/v2/stops?request="+url.QueryEscape(leaseID), nil, signed)
	cancel()
	var refusal macRefused
	if errors.As(err, &refusal) && refusal.status == http.StatusNotFound {
		return nil
	}
	if err != nil {
		c.log("used without asking the Mac for a Stop id=" + leaseID + " error=" + strconv.Quote(err.Error()))
		return nil
	}
	state, err := c.Store.Load(ctx)
	if err != nil {
		return err
	}
	current, err := held(state)
	if err != nil {
		return err
	}
	end := &pb.EndRequest{}
	device, err := checkEnd(signed, current.members)
	if err != nil || proto.Unmarshal(signed.Payload, end) != nil || end.RequestId != leaseID {
		c.log("stop at the Mac refused id=" + leaseID + " reason=" + strconv.Quote("not a Stop of this request signed by a device in the user's list"))
		return nil
	}
	if _, stopped, err := c.endByStop(ctx, leaseID, device, "mac"); err != nil {
		return err
	} else if stopped {
		c.pushAll(ctx, leaseID)
	}
	return nil
}
