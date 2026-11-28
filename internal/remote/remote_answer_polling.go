// Written by AI on 2026.11.21 by model claude opus 5.5; answers from a box on 2026.11.23; read, then deleted, and the door cut, on 2026.11.24.
package remote

import (
	"bytes"
	"cmp"
	"context"
	"errors"
	"strconv"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/box"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

// refusedApprovalError is an answer this computer will not take, and why.
type refusedApprovalError string

func (r refusedApprovalError) Error() string { return string(r) }

// freshMembers is the newest Members this computer can have now: it reads
// its update mailbox first, so a device removed a moment ago is refused, and
// goes on with what it holds if the relay does not answer in time.
func (c *RemoteKeyringClient) freshMembers(ctx context.Context) (*pb.Members, error) {
	current, err := c.refreshRemoteCatalogue(ctx)
	if err != nil {
		return nil, err
	}
	return current.members, nil
}

// applyRemoteAnswerUpload checks an answer from a request's answer box and saves it. The
// first answer wins: a later one gets the Lease that ended the request, and
// taken false. only is the one request the answer may be for (its box's).
// Permanent rejections return a refusedApprovalError.
func (c *RemoteKeyringClient) applyRemoteAnswerUpload(ctx context.Context, upload *pb.AnswerUpload, only string) (*pb.Lease, string, bool, error) {
	if upload.Answer == nil && upload.DenyRequestId == "" {
		return nil, "", false, refusedApprovalError("The body must be an AnswerUpload: a signed answer, or a plain denial.")
	}
	answer := &pb.Answer{}
	if upload.Answer != nil && (proto.Unmarshal(upload.Answer.Payload, answer) != nil || answer.Domain != keyring.AnswerDomain) {
		return nil, "", false, refusedApprovalError("The signed answer is not an Answer.")
	}
	members, err := c.freshMembers(ctx)
	if err != nil {
		return nil, "", false, err
	}
	now := time.Now()
	var lease *pb.Lease
	var id string
	taken := false
	err = c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		saved, decision, err := c.checkAnswer(state, upload, answer, members, now)
		if err != nil {
			return err
		}
		id = saved.LeaseId
		if id != only {
			return refusedApprovalError("This answer is for another request than the one whose box it came in.")
		}
		if saved.Lease.State != pb.LeaseState_LEASE_STATE_WAITING {
			lease = proto.Clone(saved.Lease).(*pb.Lease) // The first answer won.
			return nil
		}
		applyAnswer(state, saved, decision, now)
		lease, taken = proto.Clone(saved.Lease).(*pb.Lease), true
		return nil
	})
	return lease, id, taken, err
}

type answerDecision struct {
	choice            pb.Choice
	answeredBy, reply string
	decided, notAfter int64
	approval          []byte
}

func (c *RemoteKeyringClient) checkAnswer(state *clientstate.State, upload *pb.AnswerUpload, answer *pb.Answer, members *pb.Members, now time.Time) (*clientstate.ExpectedRequest, answerDecision, error) {
	if upload.Answer == nil {
		saved := findSavedLeaseRequest(state, upload.DenyRequestId)
		if saved == nil {
			return nil, answerDecision{}, refusedApprovalError("No request of this computer has that id.")
		}
		return saved, answerDecision{choice: pb.Choice_CHOICE_DENY}, nil
	}
	saved, signed := answerRequest(state, answer.RequestSha256)
	if saved == nil {
		return nil, answerDecision{}, refusedApprovalError("No request of this computer has these exact bytes: it was changed, or it is not this computer's.")
	}
	signer, err := keyring.VerifySignedDocument(upload.Answer, members, answer.Choice == pb.Choice_CHOICE_DENY)
	if err != nil {
		return nil, answerDecision{}, refusedApprovalError("This answer is not signed by a device in the user's list of devices: the device was removed, or never added.")
	}
	full := &pb.Approval{Request: signed.Payload, Answer: upload.Answer, Delivery: upload.Delivery}
	decision := answerDecision{choice: answer.Choice, answeredBy: signer.Label, decided: answer.DecidedUnixSeconds}
	switch answer.Choice {
	case pb.Choice_CHOICE_APPROVE:
		if _, err := keyring.OpenApprovedCredential(full, members, c.receiving, now); err != nil {
			return nil, answerDecision{}, refusedApprovalError("This approval could not be checked or opened by this computer: " + err.Error() + ".")
		}
		decision.notAfter = answer.NotAfterUnixSeconds
	case pb.Choice_CHOICE_DENY:
		decision.reply = answer.Reply
	default:
		return nil, answerDecision{}, refusedApprovalError("An answer approves or denies.")
	}
	decision.approval, err = proto.Marshal(full)
	return saved, decision, err
}

func answerRequest(state *clientstate.State, digest []byte) (*clientstate.ExpectedRequest, *pb.Signed) {
	var saved *clientstate.ExpectedRequest
	var signed *pb.Signed
	for _, candidate := range state.Requests {
		document := &pb.Signed{}
		if proto.Unmarshal(candidate.Request, document) == nil && bytes.Equal(keyring.ComputeSHA256(document.Payload), digest) {
			saved, signed = candidate, document
		}
	}
	return saved, signed
}

func applyAnswer(state *clientstate.State, saved *clientstate.ExpectedRequest, decision answerDecision, now time.Time) {
	// A box is picked up only while a command here runs, so a signed answer
	// is judged by when the device says Josh decided.
	decided := now.Unix()
	if decision.decided > 0 && decision.decided < decided {
		decided = decision.decided
	}
	if decided >= saved.Lease.AnswerByUnixSeconds {
		saved.Lease.State = pb.LeaseState_LEASE_STATE_UNANSWERED
		saved.Lease.EndedAtUnixSeconds = saved.Lease.AnswerByUnixSeconds
	} else if decision.choice == pb.Choice_CHOICE_APPROVE {
		saved.Lease.State, saved.Lease.NotAfterUnixSeconds = pb.LeaseState_LEASE_STATE_APPROVED, decision.notAfter
		saved.Lease.ApprovedAtUnixSeconds = decided
		releaseHold(state, saved.Scope.LoginId)
	} else {
		saved.Lease.State = pb.LeaseState_LEASE_STATE_DENIED
		saved.Lease.EndedAtUnixSeconds = decided
		saved.Lease.RetryNotBeforeUnixSeconds = holdOff(state, saved.Scope.LoginId, decision.reply, now)
	}
	if saved.Lease.State != pb.LeaseState_LEASE_STATE_UNANSWERED {
		saved.Lease.AnsweredBy, saved.Lease.Reply, saved.Approval = decision.answeredBy, decision.reply, decision.approval
	}
}

// takeBoxAnswer reads the answer box of a waiting request, if a device has
// answered there, and takes the answer: the lists that came with it first, so
// an answer from a device added since still checks. Only once the answer is
// saved (or refused) is the box deleted; transient or store errors leave the
// box untouched to retry. A refused answer deletes the bad box entry and keeps
// polling until answer_by so another device can still answer. True if the
// request moved.
func (c *RemoteKeyringClient) takeBoxAnswer(ctx context.Context, saved *clientstate.ExpectedRequest, request *pb.Request) bool {
	relay, err := box.ValidateRelayBoxURL(cmp.Or(request.AnswerBoxUrl, box.DefaultURL), loopbackTest())
	if err != nil {
		c.appendRemoteEventLog("answer box not reached id=" + saved.LeaseId + " error=" + strconv.Quote(err.Error()))
		return false
	}
	boxes := box.NewRelayBoxClient(relay)
	picked, err := boxes.FetchRelayBox(ctx, request.AnswerBoxId, request.AnswerBoxKey, "")
	if picked == nil && err == nil {
		return false
	}
	if err != nil && !errors.Is(err, box.ErrUnreadable) {
		c.logAnswerReadError(ctx, saved.LeaseId, err)
		return false
	}
	// Read: whatever stops the agent now, take it.
	ctx = context.WithoutCancel(ctx)
	upload := &pb.AnswerUpload{}
	if err == nil && proto.Unmarshal(picked.Message, upload) != nil {
		err = errors.New("the answer in the box is not an AnswerUpload")
	}
	if err != nil {
		c.appendRemoteEventLog("answer box unreadable id=" + saved.LeaseId + " error=" + strconv.Quote(err.Error()))
		if err := c.endUnanswered(ctx, saved.LeaseId); err != nil {
			c.appendRemoteEventLog("unreadable answer not settled id=" + saved.LeaseId + " error=" + strconv.Quote(err.Error()))
			return false
		}
		return true
	}
	if upload.Bundle != nil {
		if err := c.keepBundle(ctx, upload.Bundle, true); err != nil {
			c.appendRemoteEventLog("lists from the answer not kept id=" + saved.LeaseId + " error=" + strconv.Quote(err.Error()))
		}
	}
	lease, id, taken, err := c.applyRemoteAnswerUpload(ctx, upload, saved.LeaseId)
	if err != nil {
		var r refusedApprovalError
		if !errors.As(err, &r) {
			c.appendRemoteEventLog("answer not taken id=" + saved.LeaseId + " route=box error=" + strconv.Quote(err.Error()))
			return false
		}
		c.appendRemoteEventLog("answer refused id=" + saved.LeaseId + " route=box reason=" + strconv.Quote(err.Error()))
	} else if taken {
		c.notifyAnswer(ctx, lease, id, request)
	}
	if err := boxes.AcknowledgeRelayBox(ctx, picked, ""); err != nil {
		c.appendRemoteEventLog("answer box not deleted id=" + saved.LeaseId + " error=" + strconv.Quote(err.Error()))
	}
	return taken
}

func (c *RemoteKeyringClient) logAnswerReadError(ctx context.Context, id string, err error) {
	if ctx.Err() == nil {
		c.appendRemoteEventLog("answer box not reached id=" + id + " error=" + strconv.Quote(err.Error()))
	}
}

func (c *RemoteKeyringClient) notifyAnswer(ctx context.Context, lease *pb.Lease, id string, request *pb.Request) {
	c.appendRemoteEventLog("answer id=" + id + " state=" + lease.State.String() + " by=" + strconv.Quote(lease.AnsweredBy) + " route=box")
	if lease.State == pb.LeaseState_LEASE_STATE_APPROVED {
		if err := c.putGrant(ctx, id, request); err != nil {
			c.appendRemoteEventLog("grant not put id=" + id + " error=" + strconv.Quote(err.Error()) + " reason=" + strconv.Quote("put again before the first use"))
		}
	}
	c.pushOutcome(ctx, id)
}

// endUnanswered ends a waiting request whose answer could not be taken.
func (c *RemoteKeyringClient) endUnanswered(ctx context.Context, leaseID string) error {
	moved := false
	err := c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		if saved := findSavedLeaseRequest(state, leaseID); saved != nil && saved.Lease.State == pb.LeaseState_LEASE_STATE_WAITING {
			saved.Lease.State, moved = pb.LeaseState_LEASE_STATE_UNANSWERED, true
			saved.Lease.EndedAtUnixSeconds = time.Now().Unix()
		}
		return nil
	})
	if err == nil && moved {
		c.pushOutcome(ctx, leaseID)
	}
	return err
}

// checkEnd accepts a Stop signed by the reply key of a device in members,
// naming that device.
func checkEnd(signed *pb.Signed, members *pb.Members) (*pb.Device, error) {
	end := &pb.EndRequest{}
	if proto.Unmarshal(signed.GetPayload(), end) != nil || end.Domain != keyring.EndDomain {
		return nil, keyring.ErrWrongDomain
	}
	device, err := keyring.VerifySignedDocument(signed, members, true)
	if err != nil {
		return nil, err
	}
	if signed.SignerKeyId != device.ReplyKeyId || end.DeviceKeyId != device.KeyId {
		return nil, keyring.ErrNotAllowed
	}
	return device, nil
}

// endByStop ends an approved request at once, as Josh's Stop on device.
// Anything else is left as it is. Returns the request's Lease, and whether it
// moved, in which case the caller tells the devices (pushAll).
func (c *RemoteKeyringClient) endByStop(ctx context.Context, requestID string, device *pb.Device) (*pb.Lease, bool, error) {
	var lease *pb.Lease
	stopped := false
	err := c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		saved := findSavedLeaseRequest(state, requestID)
		if saved == nil {
			return refusedApprovalError("No request of this computer has that id.")
		}
		if saved.Lease.State == pb.LeaseState_LEASE_STATE_APPROVED {
			saved.Lease.State, saved.Lease.EndedBy, saved.Approval, stopped = pb.LeaseState_LEASE_STATE_ENDED, device.Label, nil, true
			saved.Lease.EndedAtUnixSeconds = time.Now().Unix()
		}
		lease = proto.Clone(saved.Lease).(*pb.Lease)
		return nil
	})
	if err != nil {
		return nil, false, err
	}
	if stopped {
		c.appendRemoteEventLog("stopped id=" + requestID + " by=" + strconv.Quote(device.Label))
	}
	return lease, stopped, nil
}
