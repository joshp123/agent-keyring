// Written by AI on 2026.11.21 by model claude opus 5.5; Stop through a box on 2026.11.23; grants, and the doors cut, on 2026.11.24.
package remote

import (
	"cmp"
	"context"
	"errors"
	"strconv"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/box"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"google.golang.org/protobuf/proto"
)

// checkNotStopped runs before every use of an approval (read, fill, the
// pipe): the approval's grant must still stand at the relay (checkStopInBox).
// A request from before every answer came in a box has no grant, so it
// cannot be checked and is not used.
func (c *RemoteKeyringClient) checkNotStopped(ctx context.Context, leaseID string) error {
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return err
	}
	saved := findSavedLeaseRequest(state, leaseID)
	if saved == nil {
		return errors.New("This computer has no request with that ID.")
	}
	request := boxRequest(saved)
	if request == nil {
		return errNotConfirmed{"this approval has no grant at the relay"}
	}
	return c.checkStopInBox(ctx, leaseID, request)
}

// errNotConfirmed is a use refused because the relay could not say the
// approval still stands: fail closed, and the agent may try again.
type errNotConfirmed struct{ why string }

func (e errNotConfirmed) Error() string {
	return "Could not confirm with the relay that the user has not stopped this approval (" + e.why + "), so it was not used. Try again in a moment; if it keeps failing, lease again."
}

// putGrant creates the grant of an approval, once
// (keyring.proto, "Grants and Stop"), and notes it in the saved request.
func (c *RemoteKeyringClient) putGrant(ctx context.Context, leaseID string, request *pb.Request) error {
	relay, err := box.ValidateRelayBoxURL(cmp.Or(request.AnswerBoxUrl, box.DefaultURL), loopbackTest())
	if err != nil {
		return err
	}
	putCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := box.NewRelayBoxClient(relay).PublishLeaseGrantBox(putCtx, request.AnswerBoxId, request.AnswerBoxKey, request.RequestId); err != nil {
		return err
	}
	return c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		if saved := findSavedLeaseRequest(state, leaseID); saved != nil {
			saved.GrantPut = true
		}
		return nil
	})
}

// checkStopInBox fails closed: the approval is used only if its grant is at the relay, not
// stopped, and opens to this request. A Stop signed by a device in this
// computer's Members ends the approval here for good.
func (c *RemoteKeyringClient) checkStopInBox(ctx context.Context, leaseID string, request *pb.Request) error {
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return err
	}
	if saved := findSavedLeaseRequest(state, leaseID); saved != nil && !saved.GrantPut {
		if err := c.putGrant(ctx, leaseID, request); err != nil {
			c.appendRemoteEventLog("grant not put id=" + leaseID + " error=" + strconv.Quote(err.Error()))
			return errNotConfirmed{"the relay could not be reached"}
		}
	}
	relay, err := box.ValidateRelayBoxURL(cmp.Or(request.AnswerBoxUrl, box.DefaultURL), loopbackTest())
	if err != nil {
		return err
	}
	grant := box.DeriveLeaseGrantBox(request.AnswerBoxId, request.AnswerBoxKey)
	askCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	picked, err := box.NewRelayBoxClient(relay).FetchRelayBox(askCtx, grant.ID, request.AnswerBoxKey, grant.ReadAuth)
	cancel()
	switch {
	case err != nil:
		c.appendRemoteEventLog("grant not read id=" + leaseID + " error=" + strconv.Quote(err.Error()))
		return errNotConfirmed{"the relay could not be reached"}
	case picked == nil:
		c.appendRemoteEventLog("grant missing id=" + leaseID)
		return errNotConfirmed{"the relay has no record of it"}
	case picked.Stopped == nil:
		c.appendRemoteEventLog("grant unmarked id=" + leaseID)
		return errNotConfirmed{"the relay's record of it is not a grant"}
	case !*picked.Stopped && string(picked.Message) == request.RequestId:
		return nil
	case !*picked.Stopped:
		c.appendRemoteEventLog("grant refused id=" + leaseID + " reason=" + strconv.Quote("it is for another request"))
		return errNotConfirmed{"the relay's record of it is for another request"}
	}
	ctx = context.WithoutCancel(ctx)
	members, err := c.freshMembers(ctx)
	if err != nil {
		return err
	}
	signed, end := &pb.Signed{}, &pb.EndRequest{}
	var device *pb.Device
	if proto.Unmarshal(picked.Message, signed) != nil {
		err = errors.New("unreadable")
	} else {
		device, err = checkEnd(signed, members)
	}
	if err != nil || proto.Unmarshal(signed.Payload, end) != nil || end.RequestId != leaseID {
		c.appendRemoteEventLog("stop refused id=" + leaseID + " reason=" + strconv.Quote("not a Stop of this request signed by a device in the user's list"))
		return errNotConfirmed{"the relay says it was stopped, by a device this computer does not know yet"}
	}
	if _, stopped, err := c.endByStop(ctx, leaseID, device); err != nil {
		return err
	} else if stopped {
		c.pushOutcome(ctx, leaseID)
	}
	return nil
}
