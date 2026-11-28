// Written by AI on 2026.11.18 by model claude opus 5.5; the saved approval on 2026.11.19; direct, with no relay, on 2026.11.21;
// answers in a box on 2026.11.23; boxes only, with the doors cut, on 2026.11.24.
package remote

import (
	"cmp"
	"context"
	"crypto"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/box"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

// answerWithin is how long a request waits for Josh: 10 minutes, shorter
// only in a loopback test.
func answerWithin() time.Duration {
	if text := os.Getenv("AGENT_KEYRING_TEST_ANSWER_WITHIN"); text != "" && loopbackTest() {
		if duration, err := time.ParseDuration(text); err == nil && duration > 0 {
			return duration
		}
	}
	return 10 * time.Minute
}

// dispatchRemoteAuthorityRequest answers the command's local requests on this computer. First it
// settles every request whose time has passed (settleDue), so the devices
// hear how each ended even after the agent that asked has gone.
func (c *RemoteKeyringClient) dispatchRemoteAuthorityRequest(ctx context.Context, request *pb.AgentRequest, receive func(*pb.AgentResponse) bool) error {
	c.settleDue(ctx)
	switch r := request.Request.(type) {
	case *pb.AgentRequest_FindLogins:
		return c.findLogins(ctx, r.FindLogins.Query, receive)
	case *pb.AgentRequest_RequestLease:
		lease, err := c.requestRemoteLease(ctx, r.RequestLease)
		if err != nil {
			return err
		}
		receive(leaseResponse(lease))
		return nil
	case *pb.AgentRequest_GetLease:
		return c.streamRemoteLeaseStatus(ctx, r.GetLease.LeaseId, func(lease *pb.Lease) bool { receive(leaseResponse(lease)); return false })
	case *pb.AgentRequest_WatchLease:
		return c.streamRemoteLeaseStatus(ctx, r.WatchLease.LeaseId, func(lease *pb.Lease) bool { return receive(leaseResponse(lease)) })
	case *pb.AgentRequest_EndLease:
		lease, err := c.releaseRemoteLease(ctx, r.EndLease.LeaseId)
		if err != nil {
			return err
		}
		receive(leaseResponse(lease))
		return nil
	case *pb.AgentRequest_Deliver:
		// The values are opened in openValues, on this machine, with its key.
		receive(&pb.AgentResponse{Response: &pb.AgentResponse_Delivery{Delivery: &pb.LocalCredentialDelivery{Result: &pb.LocalCredentialDelivery_Sealed{Sealed: &pb.OpenedHere{}}}}, EndOfStream: true})
		return nil
	}
	return errors.New("This command is not available on a computer without the Mac app.")
}

func leaseResponse(lease *pb.Lease) *pb.AgentResponse {
	return &pb.AgentResponse{Response: &pb.AgentResponse_Lease{Lease: lease}, EndOfStream: true}
}

func findSavedLeaseRequest(state *clientstate.State, leaseID string) *clientstate.ExpectedRequest {
	for _, saved := range state.Requests {
		if saved.LeaseId == leaseID {
			return saved
		}
	}
	return nil
}

func isRemoteLeaseActive(lease *pb.Lease, now int64) bool {
	return (lease.GetState() == pb.LeaseState_LEASE_STATE_WAITING && now < lease.AnswerByUnixSeconds) ||
		(lease.GetState() == pb.LeaseState_LEASE_STATE_APPROVED && now < lease.NotAfterUnixSeconds)
}

// requestRemoteLease writes, signs and saves a request, then pushes it to Josh's devices.
// The same request id again, or the same task asking for the same login
// while its request waits or its approval lasts, rejoins that request. A
// login Automatic for this computer, whose copy it holds, is granted at once.
func (c *RemoteKeyringClient) requestRemoteLease(ctx context.Context, scope *pb.RequestLeaseRequest) (*pb.Lease, error) {
	switch {
	case strings.TrimSpace(scope.Reason) == "":
		return nil, errors.New("Give a reason: it is shown to the user when they decide.")
	case len(scope.Reason) > 400 || len(scope.AgentLabel) > 100 || len(scope.Project) > 100 || len(scope.TaskRef) > 100:
		return nil, errors.New("The reason must be at most 400 bytes, and the agent, project and task at most 100.")
	}
	boxURL, automatic, err := c.prepareAsk(ctx, scope.LoginId)
	if err != nil {
		return nil, err
	}
	saved, isNew, err := c.saveRequest(ctx, scope, boxURL, automatic)
	if err != nil {
		return nil, err
	}
	if !isNew {
		return c.fetchRemoteLease(ctx, saved.LeaseId)
	}
	if automatic != nil {
		if request := boxRequest(saved); request != nil {
			if err := c.putGrant(ctx, saved.LeaseId, request); err != nil {
				c.appendRemoteEventLog("grant not put id=" + saved.LeaseId + " error=" + strconv.Quote(err.Error()) + " reason=" + strconv.Quote("put again before the first use"))
			}
		}
		c.appendRemoteEventLog("automatic id=" + saved.LeaseId + " login=" + scope.LoginId)
	} else {
		c.appendRemoteEventLog("request id=" + saved.LeaseId + " login=" + scope.LoginId + " route=box")
	}
	if err := c.pushAll(ctx, saved.LeaseId); err != nil && automatic == nil {
		_ = c.Store.UpdateClientState(context.WithoutCancel(ctx), func(state *clientstate.State) error {
			state.Requests = slices.DeleteFunc(state.Requests, func(r *clientstate.ExpectedRequest) bool {
				return r.LeaseId == saved.LeaseId && r.GetLease().GetPushedUnixSeconds() == 0
			})
			return nil
		})
		return nil, err
	}
	return c.fetchRemoteLease(ctx, saved.LeaseId)
}

// prepareAsk checks the login may be asked for, and finds the box URL its
// answer goes to and, if the login is Automatic for this computer, its copy.
func (c *RemoteKeyringClient) prepareAsk(ctx context.Context, loginID string) (string, *pb.SealedLogin, error) {
	current, err := c.refreshRemoteCatalogue(ctx)
	if err != nil {
		return "", nil, err
	}
	login := current.findCatalogueLogin(loginID)
	if err := loginAccessPolicyError(login); err != nil {
		return "", nil, err
	}
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return "", nil, err
	}
	// Answers come to a new box at the relay this computer enrolled through.
	boxURL, err := box.ValidateRelayBoxURL(cmp.Or(state.BoxUrl, box.DefaultURL), loopbackTest())
	if err != nil {
		return "", nil, err
	}
	if login.Rule == pb.Rule_RULE_AUTOMATIC && allowsAutomatic(current.members, state.RecipientId) && hasFreshCatalogue(state) {
		if sealed := current.copyFor(state.RecipientId, login.LoginId); sealed != nil && keyring.VerifySealedLogin(sealed, current.members, login) == nil {
			return boxURL, sealed, nil
		}
	}
	if err := c.canPush(state, current); err != nil {
		return "", nil, err
	}
	return boxURL, nil, nil
}

// saveRequest saves a new signed request, or finds the one this task already
// has. isNew is false when it rejoins one.
func (c *RemoteKeyringClient) saveRequest(ctx context.Context, scope *pb.RequestLeaseRequest, boxURL string, automatic *pb.SealedLogin) (*clientstate.ExpectedRequest, bool, error) {
	var saved *clientstate.ExpectedRequest
	isNew := false
	now := time.Now()
	err := c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		pruneTerminalRequests(state, now.Unix())
		scope.RecipientId = state.RecipientId
		for _, existing := range state.Requests {
			if existing.Scope.RequestId == scope.RequestId {
				if !proto.Equal(existing.Scope, scope) {
					return errors.New("That request ID already names a different task or program.")
				}
				saved = existing
				return nil
			}
		}
		for _, existing := range state.Requests {
			if existing.Scope.LoginId == scope.LoginId && existing.Scope.TaskRef == scope.TaskRef && isRemoteLeaseActive(existing.Lease, now.Unix()) {
				saved = existing // The same task again: the request it already has.
				return nil
			}
		}
		if h := findLoginDenialHold(state, scope.LoginId); h != nil && h.UntilUnixSeconds > now.Unix() && automatic == nil {
			return errors.New(heldOffMessage(h, now))
		}
		made, err := c.newRequest(scope, boxURL, automatic, now)
		if err != nil {
			return err
		}
		saved, isNew = made, true
		state.Requests = append(state.Requests, saved)
		return nil
	})
	return saved, isNew, err
}

// newRequest signs a request for the scope, with its lease: waiting, or
// approved at once if it is Automatic.
func (c *RemoteKeyringClient) newRequest(scope *pb.RequestLeaseRequest, boxURL string, automatic *pb.SealedLogin, now time.Time) (*clientstate.ExpectedRequest, error) {
	id := make([]byte, 16)
	rand.Read(id)
	request := &pb.Request{Domain: keyring.RequestDomain, RequestId: hex.EncodeToString(id), LoginId: scope.LoginId,
		MachineId: scope.RecipientId, Reason: scope.Reason, Agent: scope.AgentLabel, Project: scope.Project, Task: scope.TaskRef,
		AskedUnixSeconds: now.Unix(), AnswerByUnixSeconds: now.Add(answerWithin()).Unix(), Automatic: automatic != nil}
	request.AnswerBoxId, request.AnswerBoxKey = box.GenerateBoxID()
	if boxURL != box.DefaultURL {
		request.AnswerBoxUrl = boxURL
	}
	signed, err := keyring.SignRequest(request, c.signRemoteLeasePayload)
	if err != nil {
		return nil, err
	}
	raw, _ := proto.Marshal(signed)
	lease := &pb.Lease{RequestId: request.RequestId, LoginId: request.LoginId, State: pb.LeaseState_LEASE_STATE_WAITING,
		AnswerByUnixSeconds: request.AnswerByUnixSeconds, RequestedAtUnixSeconds: request.AskedUnixSeconds,
		AuthorityContext: &pb.LeaseAuthorityContext{TaskRef: scope.TaskRef, Reason: scope.Reason}}
	if automatic != nil {
		lease.ApprovedAtUnixSeconds = now.Unix()
		lease.State, lease.Automatic, lease.NotAfterUnixSeconds = pb.LeaseState_LEASE_STATE_APPROVED, true, now.Unix()+keyring.ApprovalSeconds
	}
	return &clientstate.ExpectedRequest{Scope: proto.Clone(scope).(*pb.RequestLeaseRequest), LeaseId: request.RequestId, Request: raw, Lease: lease}, nil
}

// signRemoteLeasePayload signs with this machine's TLS key, which Members lists as the machine.
func (c *RemoteKeyringClient) signRemoteLeasePayload(payload []byte) ([]byte, error) {
	signer, ok := c.Certificate.PrivateKey.(crypto.Signer)
	if !ok {
		return nil, errors.New("This machine's TLS key cannot sign.")
	}
	return signer.Sign(rand.Reader, keyring.ComputeSHA256(payload), crypto.SHA256)
}

// fetchRemoteLease is the current state of a request, as the command shows it.
func (c *RemoteKeyringClient) fetchRemoteLease(ctx context.Context, leaseID string) (*pb.Lease, error) {
	var result *pb.Lease
	err := c.streamRemoteLeaseStatus(ctx, leaseID, func(lease *pb.Lease) bool { result = lease; return false })
	return result, err
}

// streamRemoteLeaseStatus reports the request's state, then each change while it waits. While
// it waits it reads the request's answer box at box.RelayBoxPollInterval's pace. The answer
// is in the state file; each follower reads it there.
func (c *RemoteKeyringClient) streamRemoteLeaseStatus(ctx context.Context, leaseID string, receive func(*pb.Lease) bool) error {
	var last *pb.Lease
	var next time.Time
	for {
		if !time.Now().Before(next) {
			next = c.pollAnswer(ctx, leaseID, next)
		}
		saved, err := c.settleRemoteLease(ctx, leaseID)
		if err != nil {
			return err
		}
		lease := saved.Lease
		if last == nil || !proto.Equal(last, lease) {
			if !receive(lease) || lease.State != pb.LeaseState_LEASE_STATE_WAITING {
				return nil
			}
			last = lease
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
}

// Poll the answer box before settling timeouts so a decision made in time still counts.
func (c *RemoteKeyringClient) pollAnswer(ctx context.Context, leaseID string, next time.Time) time.Time {
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return next
	}
	saved := findSavedLeaseRequest(state, leaseID)
	if saved.GetLease().GetState() != pb.LeaseState_LEASE_STATE_WAITING {
		return next
	}
	request := boxRequest(saved)
	if request == nil {
		return next
	}
	c.takeBoxAnswer(ctx, saved, request)
	return time.Now().Add(box.RelayBoxPollInterval(time.Since(time.Unix(request.AskedUnixSeconds, 0))))
}

// boxRequest is the saved request if its answers come in a box.
func boxRequest(saved *clientstate.ExpectedRequest) *pb.Request {
	signed := &pb.Signed{}
	if proto.Unmarshal(saved.Request, signed) != nil {
		return nil
	}
	request, err := keyring.ParseLeaseRequestPayload(signed.Payload)
	if err != nil || request.AnswerBoxId == "" {
		return nil
	}
	return request
}

// settleRemoteLease returns the saved request, first moving it on if its time has
// passed: unanswered after answer_by, ended after its approval's window.
// Whoever moves it pushes the outcome.
func (c *RemoteKeyringClient) settleRemoteLease(ctx context.Context, leaseID string) (*clientstate.ExpectedRequest, error) {
	// Read only: a waiting process looks five times a second, and the state
	// file is rewritten only when something moves.
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return nil, err
	}
	saved := findSavedLeaseRequest(state, leaseID)
	if saved == nil || saved.Lease == nil {
		return nil, errors.New("This computer has no request with that ID.")
	}
	if !hasRemoteLeaseExpired(saved.Lease, time.Now().Unix()) {
		return saved, nil
	}
	moved := false
	err = c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		saved = findSavedLeaseRequest(state, leaseID)
		if saved == nil || saved.Lease == nil {
			return errors.New("This computer has no request with that ID.")
		}
		if lease := saved.Lease; hasRemoteLeaseExpired(lease, time.Now().Unix()) {
			moved = true
			if lease.State == pb.LeaseState_LEASE_STATE_WAITING {
				lease.State = pb.LeaseState_LEASE_STATE_UNANSWERED
				lease.EndedAtUnixSeconds = lease.AnswerByUnixSeconds
			} else {
				lease.State, saved.Approval = pb.LeaseState_LEASE_STATE_EXPIRED, nil
				lease.EndedAtUnixSeconds = lease.NotAfterUnixSeconds
			}
		}
		saved = proto.Clone(saved).(*clientstate.ExpectedRequest)
		return nil
	})
	if err == nil && moved {
		c.appendRemoteEventLog("ended id=" + leaseID + " state=" + saved.Lease.State.String())
		c.pushOutcome(ctx, leaseID)
	}
	return saved, err
}

// hasRemoteLeaseExpired is true once a request's time has passed: unanswered after answer_by,
// or its approval's window over.
func hasRemoteLeaseExpired(lease *pb.Lease, now int64) bool {
	return (lease.GetState() == pb.LeaseState_LEASE_STATE_WAITING && now >= lease.GetAnswerByUnixSeconds()) ||
		(lease.GetState() == pb.LeaseState_LEASE_STATE_APPROVED && now >= lease.GetNotAfterUnixSeconds())
}

// settleDue settles every waiting or approved request whose time has passed,
// so each sends its outcome push once, and prunes terminal requests older than 24h.
func (c *RemoteKeyringClient) settleDue(ctx context.Context) {
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return
	}
	now := time.Now().Unix()
	prune := false
	for _, saved := range state.Requests {
		if hasRemoteLeaseExpired(saved.GetLease(), now) {
			if _, err := c.settleRemoteLease(ctx, saved.LeaseId); err != nil {
				c.appendRemoteEventLog("request not settled id=" + saved.LeaseId + " error=" + strconv.Quote(err.Error()))
			}
		} else if staleTerminalRequest(saved, now) {
			prune = true
		}
	}
	if prune {
		_ = c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
			pruneTerminalRequests(state, now)
			return nil
		})
	}
}

// releaseRemoteLease is the agent done with a request: an approval ends, a waiting request
// is cancelled. This computer stops using it at once, and the devices are told.
func (c *RemoteKeyringClient) releaseRemoteLease(ctx context.Context, leaseID string) (*pb.Lease, error) {
	var saved *clientstate.ExpectedRequest
	moved := false
	err := c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		saved = findSavedLeaseRequest(state, leaseID)
		if saved == nil || saved.Lease == nil {
			return errors.New("This computer has no request with that ID.")
		}
		switch saved.Lease.State {
		case pb.LeaseState_LEASE_STATE_WAITING:
			saved.Lease.State, moved = pb.LeaseState_LEASE_STATE_CANCELLED, true
		case pb.LeaseState_LEASE_STATE_APPROVED:
			saved.Lease.State, moved = pb.LeaseState_LEASE_STATE_RELEASED, true
		}
		if moved {
			saved.Lease.EndedAtUnixSeconds = time.Now().Unix()
		}
		saved.Approval = nil
		saved = proto.Clone(saved).(*clientstate.ExpectedRequest)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if moved {
		c.appendRemoteEventLog("ended id=" + leaseID + " state=" + saved.Lease.State.String() + " by=agent")
		c.pushOutcome(ctx, leaseID)
	}
	return saved.Lease, nil
}
