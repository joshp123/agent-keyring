// Written by AI on 2026.11.18 by model claude opus 5.5; the saved approval on 2026.11.19; direct, with no relay, on 2026.11.21.
package remote

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	v1 "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/door"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

// automaticLimit is how long a command waits for the Mac's revisions before
// it uses what it holds. A shut MacBook must never hold up an agent.
const automaticLimit = 500 * time.Millisecond

// answerWithin is how long a request waits for Josh: 10 minutes, shorter
// only in a loopback test.
func answerWithin() time.Duration {
	if text := os.Getenv("AGENT_KEYRING_TEST_ANSWER_WITHIN"); text != "" && door.Testing() {
		if duration, err := time.ParseDuration(text); err == nil && duration > 0 {
			return duration
		}
	}
	return 10 * time.Minute
}

// exchange answers the command's local requests on this computer.
func (c *Client) exchange(ctx context.Context, request *v1.WireRequest, receive func(*v1.WireResponse) bool) error {
	switch r := request.Request.(type) {
	case *v1.WireRequest_FindLogins:
		current, err := c.refresh(ctx, automaticLimit)
		if err != nil {
			return err
		}
		result := &v1.FindLoginsResponse{}
		words := strings.Fields(strings.ToLower(r.FindLogins.Query))
		for _, login := range current.catalogue.GetLogins() {
			text := strings.ToLower(login.Title + " " + login.Account + " " + strings.Join(login.Sites, " ") + " " + login.LoginId)
			if slices.ContainsFunc(words, func(word string) bool { return !strings.Contains(text, word) }) {
				continue
			}
			result.Logins = append(result.Logins, &v1.Login{LoginId: login.LoginId, Title: login.Title, Sites: login.Sites,
				Account: login.Account, HasOneTimeCode: login.HasOneTimeCode, Rule: v1.AccessRule(login.Rule)})
		}
		receive(&v1.WireResponse{Response: &v1.WireResponse_Logins{Logins: result}, EndOfStream: true})
		return nil
	case *v1.WireRequest_RequestLease:
		lease, err := c.ask(ctx, r.RequestLease)
		if err != nil {
			return err
		}
		receive(leaseResponse(lease))
		return nil
	case *v1.WireRequest_GetLease:
		return c.follow(ctx, r.GetLease.LeaseId, func(lease *v1.Lease) bool { receive(leaseResponse(lease)); return false })
	case *v1.WireRequest_WatchLease:
		return c.follow(ctx, r.WatchLease.LeaseId, func(lease *v1.Lease) bool { return receive(leaseResponse(lease)) })
	case *v1.WireRequest_EndLease:
		lease, err := c.end(ctx, r.EndLease.LeaseId)
		if err != nil {
			return err
		}
		receive(leaseResponse(lease))
		return nil
	case *v1.WireRequest_Deliver:
		// The values are opened in openValues, on this machine, with its key.
		receive(&v1.WireResponse{Response: &v1.WireResponse_Delivery{Delivery: &v1.Delivery{Result: &v1.Delivery_Sealed{Sealed: &v1.OpenedHere{}}}}, EndOfStream: true})
		return nil
	}
	return errors.New("This command is not available on a computer without the Mac app.")
}

func leaseResponse(lease *v1.Lease) *v1.WireResponse {
	return &v1.WireResponse{Response: &v1.WireResponse_Lease{Lease: lease}, EndOfStream: true}
}

func expected(state *clientstate.State, leaseID string) *clientstate.ExpectedRequest {
	for _, saved := range state.Requests {
		if saved.LeaseId == leaseID {
			return saved
		}
	}
	return nil
}

func ongoing(lease *pb.Lease, now int64) bool {
	return (lease.GetState() == pb.LeaseState_LEASE_STATE_WAITING && now < lease.AnswerByUnixSeconds) ||
		(lease.GetState() == pb.LeaseState_LEASE_STATE_APPROVED && now < lease.NotAfterUnixSeconds)
}

// ask writes, signs and saves a request, then pushes it to Josh's devices.
// The same request id again, or the same task asking for the same login
// while its request waits or its approval lasts, rejoins that request. A
// login Automatic for this computer, whose copy it holds, is granted at once.
func (c *Client) ask(ctx context.Context, scope *v1.RequestLeaseRequest) (*v1.Lease, error) {
	switch {
	case strings.TrimSpace(scope.Reason) == "":
		return nil, errors.New("Give a reason: it is shown to Josh when he decides.")
	case len(scope.Reason) > 400 || len(scope.AgentLabel) > 100 || len(scope.Project) > 100 || len(scope.TaskRef) > 100:
		return nil, errors.New("The reason must be at most 400 bytes, and the agent, project and task at most 100.")
	}
	answerAddress, err := door.Address()
	if err != nil {
		return nil, err
	}
	current, err := c.refresh(ctx, automaticLimit)
	if err != nil {
		return nil, err
	}
	login := current.login(scope.LoginId)
	if login == nil {
		return nil, errors.New("No such password. Use 'agent-keyring find' for its login ID.")
	}
	if login.Rule == pb.Rule_RULE_BLOCKED {
		return nil, errors.New("This password is blocked for agents.")
	}
	state, err := c.Store.Load(ctx)
	if err != nil {
		return nil, err
	}
	var automatic *pb.SealedLogin
	if login.Rule == pb.Rule_RULE_AUTOMATIC && allowsAutomatic(current.members, state.RecipientId) {
		if sealed := current.copyFor(state.RecipientId, login.LoginId); sealed != nil && keyring.CheckSealed(sealed, current.members, login) == nil {
			automatic = sealed
		}
	}
	if automatic == nil {
		if err := c.canPush(state, current); err != nil {
			return nil, err
		}
	}
	spki := c.certificateSPKI()
	var saved *clientstate.ExpectedRequest
	fresh := false
	now := time.Now()
	err = c.Store.Update(ctx, func(state *clientstate.State) error {
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
			if existing.Scope.LoginId == scope.LoginId && existing.Scope.TaskRef == scope.TaskRef && ongoing(existing.Lease, now.Unix()) {
				saved = existing // The same task again: the request it already has.
				return nil
			}
		}
		if h := hold(state, scope.LoginId); h != nil && h.UntilUnixSeconds > now.Unix() && automatic == nil {
			return errors.New(heldOffMessage(h, now))
		}
		id := make([]byte, 16)
		rand.Read(id)
		request := &pb.Request{Domain: keyring.RequestDomain, RequestId: hex.EncodeToString(id), LoginId: scope.LoginId,
			MachineId: scope.RecipientId, Reason: scope.Reason, Agent: scope.AgentLabel, Project: scope.Project, Task: scope.TaskRef,
			AskedUnixSeconds: now.Unix(), AnswerByUnixSeconds: now.Add(answerWithin()).Unix(), Automatic: automatic != nil,
			AnswerAddress: answerAddress, AnswerTlsPublicKey: spki}
		signed, err := keyring.SignRequest(request, c.sign)
		if err != nil {
			return err
		}
		raw, _ := proto.Marshal(signed)
		lease := &pb.Lease{RequestId: request.RequestId, LoginId: request.LoginId, State: pb.LeaseState_LEASE_STATE_WAITING,
			AnswerByUnixSeconds: request.AnswerByUnixSeconds}
		if automatic != nil {
			lease.State, lease.Automatic, lease.NotAfterUnixSeconds = pb.LeaseState_LEASE_STATE_APPROVED, true, now.Unix()+keyring.ApprovalSeconds
		}
		saved = &clientstate.ExpectedRequest{Scope: proto.Clone(scope).(*v1.RequestLeaseRequest), LeaseId: request.RequestId, Request: raw, Lease: lease}
		state.Requests = append(state.Requests, saved)
		fresh = true
		return nil
	})
	if err != nil {
		return nil, err
	}
	if !fresh {
		return c.lease(ctx, saved.LeaseId)
	}
	c.holdDoor() // Before the push, so a quick answer finds the door open.
	if automatic != nil {
		if !current.reached {
			c.log("automatic used without the Mac id=" + saved.LeaseId + " login=" + scope.LoginId + " reason=" + strconv.Quote("the Mac did not answer within 500 ms; used this computer's own copy"))
		}
		c.log("automatic id=" + saved.LeaseId + " login=" + scope.LoginId)
	} else {
		c.log("request id=" + saved.LeaseId + " login=" + scope.LoginId + " answer_address=" + answerAddress)
	}
	if err := c.pushAll(ctx, saved.LeaseId); err != nil && automatic == nil {
		c.end(ctx, saved.LeaseId)
		return nil, err
	}
	return c.lease(ctx, saved.LeaseId)
}

func allowsAutomatic(members *pb.Members, machineID string) bool {
	for _, m := range members.GetMachines() {
		if m.MachineId == machineID {
			return m.AutomaticAllowed
		}
	}
	return false
}

// sign signs with this machine's TLS key, which Members lists as the machine.
func (c *Client) sign(payload []byte) ([]byte, error) {
	signer, ok := c.Certificate.PrivateKey.(crypto.Signer)
	if !ok {
		return nil, errors.New("This machine's TLS key cannot sign.")
	}
	return signer.Sign(rand.Reader, keyring.SHA256(payload), crypto.SHA256)
}

// lease is the current state of a request, as the command shows it.
func (c *Client) lease(ctx context.Context, leaseID string) (*v1.Lease, error) {
	var result *v1.Lease
	err := c.follow(ctx, leaseID, func(lease *v1.Lease) bool { result = lease; return false })
	return result, err
}

// follow reports the request's state, then each change while it waits.
// While it runs this process tries to hold the door, so an answer reaches
// this computer whichever of its processes holds it. The answer is in the
// state file; each follower reads it there.
func (c *Client) follow(ctx context.Context, leaseID string, receive func(*v1.Lease) bool) error {
	c.holdDoor()
	var last *v1.Lease
	for {
		saved, err := c.settle(ctx, leaseID)
		if err != nil {
			return err
		}
		lease := translate(saved)
		if last == nil || !proto.Equal(last, lease) {
			if !receive(lease) || lease.State != v1.LeaseState_LEASE_STATE_PENDING {
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

// settle returns the saved request, first moving it on if its time has
// passed: unanswered after answer_by, ended after its approval's window.
// Whoever moves it pushes the outcome.
func (c *Client) settle(ctx context.Context, leaseID string) (*clientstate.ExpectedRequest, error) {
	due := func(lease *pb.Lease, now int64) bool {
		return (lease.State == pb.LeaseState_LEASE_STATE_WAITING && now >= lease.AnswerByUnixSeconds) ||
			(lease.State == pb.LeaseState_LEASE_STATE_APPROVED && now >= lease.NotAfterUnixSeconds)
	}
	// Read only: a waiting process looks five times a second, and the state
	// file is rewritten only when something moves.
	state, err := c.Store.Load(ctx)
	if err != nil {
		return nil, err
	}
	saved := expected(state, leaseID)
	if saved == nil || saved.Lease == nil {
		return nil, errors.New("This computer has no request with that ID.")
	}
	if !due(saved.Lease, time.Now().Unix()) {
		return saved, nil
	}
	moved := false
	err = c.Store.Update(ctx, func(state *clientstate.State) error {
		saved = expected(state, leaseID)
		if saved == nil || saved.Lease == nil {
			return errors.New("This computer has no request with that ID.")
		}
		if lease := saved.Lease; due(lease, time.Now().Unix()) {
			moved = true
			if lease.State == pb.LeaseState_LEASE_STATE_WAITING {
				lease.State = pb.LeaseState_LEASE_STATE_UNANSWERED
			} else {
				lease.State, saved.Approval = pb.LeaseState_LEASE_STATE_ENDED, nil
			}
		}
		saved = proto.Clone(saved).(*clientstate.ExpectedRequest)
		return nil
	})
	if moved {
		c.log("ended id=" + leaseID + " state=" + saved.Lease.State.String())
		c.pushAll(ctx, leaseID)
	}
	return saved, err
}

// translate maps the request's state onto the command's, showing a reply
// only once its signature has been checked (it is saved only then).
func translate(saved *clientstate.ExpectedRequest) *v1.Lease {
	remote, scope := saved.Lease, saved.Scope
	lease := &v1.Lease{LeaseId: saved.LeaseId, LoginId: scope.LoginId, TaskRef: scope.TaskRef, Reason: scope.Reason,
		Recipient: &v1.Recipient{RecipientId: scope.RecipientId}, PendingUntilUnixSeconds: remote.AnswerByUnixSeconds,
		NotAfterUnixSeconds: remote.NotAfterUnixSeconds, RetryNotBeforeUnixSeconds: remote.RetryNotBeforeUnixSeconds}
	switch remote.State {
	case pb.LeaseState_LEASE_STATE_WAITING:
		lease.State = v1.LeaseState_LEASE_STATE_PENDING
		switch {
		case remote.ArrivedUnixSeconds > 0:
			lease.StatusLines = []string{"It reached " + printable(remote.ArrivedOn) + "."}
		case remote.PushedUnixSeconds > 0:
			lease.StatusLines = []string{"Apple took the notification for Josh's iPhone and Apple Watch."}
		}
	case pb.LeaseState_LEASE_STATE_APPROVED:
		lease.State = v1.LeaseState_LEASE_STATE_ACTIVE
		if remote.Automatic {
			lease.ApprovedBy = v1.ApprovedBy_APPROVED_BY_AUTOMATIC_RULE
		}
	case pb.LeaseState_LEASE_STATE_DENIED:
		lease.State, lease.Reply = v1.LeaseState_LEASE_STATE_DENIED, remote.Reply
	case pb.LeaseState_LEASE_STATE_UNANSWERED:
		lease.State = v1.LeaseState_LEASE_STATE_UNANSWERED
	case pb.LeaseState_LEASE_STATE_CANCELLED:
		lease.State = v1.LeaseState_LEASE_STATE_CANCELLED
	case pb.LeaseState_LEASE_STATE_ENDED:
		lease.State = v1.LeaseState_LEASE_STATE_RELEASED
		if remote.EndedBy != "" {
			lease.State = v1.LeaseState_LEASE_STATE_REVOKED
			lease.StatusLines = []string{"Josh stopped it on " + printable(remote.EndedBy) + "."}
		} else if time.Now().Unix() >= remote.NotAfterUnixSeconds {
			lease.State = v1.LeaseState_LEASE_STATE_EXPIRED
		}
	}
	return lease
}

// end is the agent done with a request: an approval ends, a waiting request
// is cancelled. This computer stops using it at once, and the devices are told.
func (c *Client) end(ctx context.Context, leaseID string) (*v1.Lease, error) {
	var saved *clientstate.ExpectedRequest
	moved := false
	err := c.Store.Update(ctx, func(state *clientstate.State) error {
		saved = expected(state, leaseID)
		if saved == nil || saved.Lease == nil {
			return errors.New("This computer has no request with that ID.")
		}
		switch saved.Lease.State {
		case pb.LeaseState_LEASE_STATE_WAITING:
			saved.Lease.State, moved = pb.LeaseState_LEASE_STATE_CANCELLED, true
		case pb.LeaseState_LEASE_STATE_APPROVED:
			saved.Lease.State, moved = pb.LeaseState_LEASE_STATE_ENDED, true
		}
		saved.Approval = nil
		saved = proto.Clone(saved).(*clientstate.ExpectedRequest)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if moved {
		c.log("ended id=" + leaseID + " state=" + saved.Lease.State.String() + " by=agent")
		c.pushAll(ctx, leaseID)
	}
	return translate(saved), nil
}

// openValues opens the password for an approved request on this computer:
// the device's delivery, checked against the newest Members held, or this
// computer's own copy of an Automatic password. First it asks the Mac for a
// Stop a device left there (checkStopAtMac).
func (c *Client) openValues(ctx context.Context, lease *v1.Lease, _ *v1.Delivery) (*v1.CredentialValues, []string, error) {
	now := time.Now()
	saved, err := c.settle(ctx, lease.LeaseId)
	if err != nil {
		return nil, nil, err
	}
	if saved.Lease.State == pb.LeaseState_LEASE_STATE_APPROVED {
		if err := c.checkStopAtMac(ctx, lease.LeaseId); err != nil {
			return nil, nil, err
		}
		if saved, err = c.settle(ctx, lease.LeaseId); err != nil {
			return nil, nil, err
		}
	}
	switch current := translate(saved); current.State {
	case v1.LeaseState_LEASE_STATE_ACTIVE:
	case v1.LeaseState_LEASE_STATE_RELEASED:
		return nil, nil, errors.New("This lease was released. Lease again if the task still needs the password.")
	case v1.LeaseState_LEASE_STATE_REVOKED:
		return nil, nil, fmt.Errorf("This lease has ended: %s Lease again only if the task still needs the password.", current.StatusLines[0])
	default:
		return nil, nil, errors.New("This lease is not approved. Check it with 'agent-keyring status'.")
	}
	var username, password string
	var sites []string
	var codes []*pb.TimedCode
	if saved.Lease.Automatic {
		current, err := c.refresh(ctx, automaticLimit)
		if err != nil {
			return nil, nil, err
		}
		if !current.reached {
			c.log("automatic used without the Mac id=" + saved.LeaseId + " reason=" + strconv.Quote("the Mac did not answer within 500 ms; used this computer's own copy"))
		}
		listed := current.login(saved.Scope.LoginId)
		var sealed *pb.SealedLogin
		if listed != nil && listed.Rule == pb.Rule_RULE_AUTOMATIC && allowsAutomatic(current.members, saved.Scope.RecipientId) {
			sealed = current.copyFor(saved.Scope.RecipientId, listed.LoginId)
		}
		if sealed == nil || keyring.CheckSealed(sealed, current.members, listed) != nil {
			return nil, nil, errors.New("This password is no longer Automatic for this computer. Ask again.")
		}
		secret, err := keyring.OpenLogin(sealed, c.receiving)
		if err != nil || keyring.CheckBound(secret, listed) != nil {
			return nil, nil, errors.New("This computer could not open its copy of the password.")
		}
		username, password, sites = secret.Username, secret.Password, listed.Sites
		if codes, err = keyring.OneTimeCodes(secret, now.Unix(), now.Unix()+1); err != nil {
			return nil, nil, err
		}
	} else {
		state, err := c.Store.Load(ctx)
		if err != nil {
			return nil, nil, err
		}
		members, err := parseMembers(state.Members)
		if err != nil {
			return nil, nil, err
		}
		approval := &pb.Approval{}
		if proto.Unmarshal(saved.Approval, approval) != nil || !ownRequest(approval, saved) {
			return nil, nil, errors.New("This computer's saved approval is unreadable. Lease again.")
		}
		contents, err := keyring.OpenApproval(approval, members, c.receiving, now)
		if err != nil {
			return nil, nil, fmt.Errorf("This approval could not be checked or opened: %w", err)
		}
		username, password, sites, codes = contents.Username, contents.Password, contents.Sites, contents.OneTimeCodes
	}
	values := &v1.CredentialValues{Username: username, Password: password}
	for _, code := range codes {
		if code.ValidFromUnixSeconds <= now.Unix() && now.Unix() < code.ValidUntilUnixSeconds {
			values.OneTimeCode = code.Code
		}
	}
	return values, sites, nil
}

// ownRequest is true if the approval is over exactly the request this computer signed.
func ownRequest(approval *pb.Approval, saved *clientstate.ExpectedRequest) bool {
	signed := &pb.Signed{}
	return len(saved.Request) > 0 && proto.Unmarshal(saved.Request, signed) == nil && bytes.Equal(approval.GetRequest(), signed.Payload)
}

// ---- The hold after a denial ---------------------------------------------------

// A denial keeps this computer from asking for that password again straight
// away: a minute after the first denial, five after a second in a row,
// fifteen after more. An approval, or an hour with no denial, starts again.
func holdFor(inARow int32) time.Duration {
	switch inARow {
	case 1:
		return time.Minute
	case 2:
		return 5 * time.Minute
	default:
		return 15 * time.Minute
	}
}

func hold(state *clientstate.State, loginID string) *clientstate.Hold {
	for _, h := range state.Holds {
		if h.LoginId == loginID {
			return h
		}
	}
	return nil
}

// holdOff records a denial and returns when this computer may ask again.
func holdOff(state *clientstate.State, loginID, reply string, now time.Time) int64 {
	h := hold(state, loginID)
	if h == nil {
		h = &clientstate.Hold{LoginId: loginID}
		state.Holds = append(state.Holds, h)
	}
	if now.Unix()-h.UntilUnixSeconds > 3600 {
		h.InARow = 0
	}
	h.InARow++
	h.UntilUnixSeconds, h.Reply = now.Add(holdFor(h.InARow)).Unix(), reply
	return h.UntilUnixSeconds
}

func releaseHold(state *clientstate.State, loginID string) {
	state.Holds = slices.DeleteFunc(state.Holds, func(h *clientstate.Hold) bool { return h.LoginId == loginID })
}

// heldOffMessage tells the agent when it may ask again, and his words.
func heldOffMessage(h *clientstate.Hold, now time.Time) string {
	wait := time.Duration(h.UntilUnixSeconds-now.Unix()) * time.Second
	message := "Josh denied this password for this computer. Ask again after " + time.Unix(h.UntilUnixSeconds, 0).Format("15:04:05") +
		" (in " + wait.Round(time.Second).String() + ")."
	if h.Reply != "" {
		message += " His reply, word for word: \"" + printable(h.Reply) + "\""
	}
	return message
}
