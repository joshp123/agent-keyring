// Written by AI on 2026.11.18 by model claude opus 5.5.
package remote

import (
	"context"
	"errors"
	"fmt"
	"time"

	v1 "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

const automaticPrefix = "automatic-"

// exchange answers the command's local requests through the relay.
func (c *Client) exchange(ctx context.Context, request *v1.WireRequest, receive func(*v1.WireResponse) bool) error {
	switch r := request.Request.(type) {
	case *v1.WireRequest_FindLogins:
		response, err := c.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_Find{Find: &pb.FindRequest{Query: r.FindLogins.Query}}})
		if err != nil {
			return err
		}
		result := &v1.FindLoginsResponse{}
		for _, login := range response.GetFind().GetLogins() {
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
		receive(&v1.WireResponse{Response: &v1.WireResponse_Delivery{Delivery: &v1.Delivery{Result: &v1.Delivery_Sealed{Sealed: &v1.SealedDelivery{}}}}, EndOfStream: true})
		return nil
	}
	return errors.New("This command is not available through the relay.")
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

// ask uses this machine's own sealed copy for an Automatic login, and
// otherwise asks the relay. The scope is saved first, so a retry joins it.
func (c *Client) ask(ctx context.Context, scope *v1.RequestLeaseRequest) (*v1.Lease, error) {
	var saved *clientstate.ExpectedRequest
	err := c.Store.Update(ctx, func(state *clientstate.State) error {
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
		saved = &clientstate.ExpectedRequest{Scope: proto.Clone(scope).(*v1.RequestLeaseRequest)}
		state.Requests = append(state.Requests, saved)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if saved.LeaseId != "" {
		return c.lease(ctx, saved.LeaseId)
	}
	if sealed, _ := c.automaticCopy(ctx, scope.LoginId); sealed != nil {
		notAfter := time.Now().Add(keyring.ApprovalSeconds * time.Second).Unix()
		id := automaticPrefix + scope.RequestId
		if err := c.save(ctx, scope.RequestId, func(e *clientstate.ExpectedRequest) {
			e.LeaseId, e.AutomaticNotAfterUnixSeconds = id, notAfter
		}); err != nil {
			return nil, err
		}
		c.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_ReportUse{ReportUse: &pb.UseReport{LoginId: scope.LoginId,
			Agent: scope.AgentLabel, Reason: scope.Reason, UsedUnixSeconds: time.Now().Unix()}}})
		return c.lease(ctx, id)
	}
	response, err := c.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_Ask{Ask: &pb.AskRequest{LoginId: scope.LoginId,
		Purpose: pb.Purpose(scope.Purpose), Program: program(scope.Program), Reason: scope.Reason, Agent: scope.AgentLabel,
		Project: scope.Project, Task: scope.TaskRef, ClientRequestId: scope.RequestId}}})
	if err != nil {
		return nil, err
	}
	remote := response.GetLease()
	if remote == nil || remote.RequestId == "" {
		return nil, errors.New("The relay did not return a request.")
	}
	if err := c.save(ctx, scope.RequestId, func(e *clientstate.ExpectedRequest) { e.LeaseId = remote.RequestId }); err != nil {
		return nil, err
	}
	return c.translate(ctx, saved.Scope, remote)
}

func program(p *v1.ProgramCommand) *pb.ProgramCommand {
	if p == nil {
		return nil
	}
	return &pb.ProgramCommand{Executable: p.Executable, Arguments: p.Arguments}
}

func (c *Client) save(ctx context.Context, requestID string, change func(*clientstate.ExpectedRequest)) error {
	return c.Store.Update(ctx, func(state *clientstate.State) error {
		for _, e := range state.Requests {
			if e.Scope.RequestId == requestID {
				change(e)
				return nil
			}
		}
		return errors.New("The saved request is missing.")
	})
}

// automaticCopy is this machine's sealed copy of an Automatic login and its
// sites, if the signed catalogue says Automatic and a device sealed it here.
func (c *Client) automaticCopy(ctx context.Context, loginID string) (*pb.SealedLogin, []string) {
	members, err := c.members(ctx)
	if err != nil {
		return nil, nil
	}
	response, err := c.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_Catalogue{Catalogue: &pb.Empty{}}})
	if err != nil || response.GetSigned() == nil {
		return nil, nil
	}
	catalogue, err := keyring.VerifiedCatalogue(response.GetSigned(), members, nil)
	if err != nil {
		return nil, nil
	}
	var sites []string
	automatic := false
	for _, login := range catalogue.Logins {
		if login.LoginId == loginID && login.Rule == pb.Rule_RULE_AUTOMATIC {
			automatic, sites = true, login.Sites
		}
	}
	if !automatic {
		return nil, nil
	}
	response, err = c.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_AutomaticLogins{AutomaticLogins: &pb.Empty{}}})
	if err != nil {
		return nil, nil
	}
	for _, sealed := range response.GetSealedLogins().GetLogins() {
		if sealed.LoginId == loginID {
			return sealed, sites
		}
	}
	return nil, nil
}

// lease is the current state of a request, as the command shows it.
func (c *Client) lease(ctx context.Context, leaseID string) (*v1.Lease, error) {
	var result *v1.Lease
	err := c.follow(ctx, leaseID, func(lease *v1.Lease) bool { result = lease; return false })
	return result, err
}

// follow reports the request's state, then each change while it waits.
func (c *Client) follow(ctx context.Context, leaseID string, receive func(*v1.Lease) bool) error {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return err
	}
	saved := expected(state, leaseID)
	if saved == nil {
		return errors.New("This machine has no request with that ID.")
	}
	if saved.AutomaticNotAfterUnixSeconds > 0 {
		lease := scoped(saved.Scope, leaseID)
		lease.ApprovedBy, lease.NotAfterUnixSeconds = v1.ApprovedBy_APPROVED_BY_AUTOMATIC_RULE, saved.AutomaticNotAfterUnixSeconds
		switch {
		case saved.Ended:
			lease.State = v1.LeaseState_LEASE_STATE_RELEASED
		case time.Now().Unix() >= saved.AutomaticNotAfterUnixSeconds:
			lease.State = v1.LeaseState_LEASE_STATE_EXPIRED
		default:
			lease.State = v1.LeaseState_LEASE_STATE_ACTIVE
		}
		receive(lease)
		return nil
	}
	var translateError error
	err = c.relay(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_Watch{Watch: &pb.RequestReference{RequestId: leaseID}}}, func(response *pb.RelayResponse) bool {
		lease, err := c.translate(ctx, saved.Scope, response.GetLease())
		if err != nil {
			translateError = err
			return false
		}
		return receive(lease)
	})
	if translateError != nil {
		return translateError
	}
	return err
}

func scoped(scope *v1.RequestLeaseRequest, leaseID string) *v1.Lease {
	return &v1.Lease{LeaseId: leaseID, LoginId: scope.LoginId, TaskRef: scope.TaskRef, Purpose: scope.Purpose, Program: scope.Program,
		Reason: scope.Reason, Recipient: &v1.Recipient{RecipientId: scope.RecipientId}}
}

// translate maps the relay's state onto the command's, keeping the scope this
// machine saved and showing a reply only once its signature is checked.
func (c *Client) translate(ctx context.Context, scope *v1.RequestLeaseRequest, remote *pb.Lease) (*v1.Lease, error) {
	if remote == nil {
		return nil, errors.New("The relay returned no request state.")
	}
	if remote.LoginId != scope.LoginId {
		return nil, errors.New("The relay changed the login of this request.")
	}
	lease := scoped(scope, remote.RequestId)
	lease.PendingUntilUnixSeconds, lease.NotAfterUnixSeconds = remote.AnswerByUnixSeconds, remote.NotAfterUnixSeconds
	lease.RetryNotBeforeUnixSeconds = remote.RetryNotBeforeUnixSeconds
	switch remote.State {
	case pb.LeaseState_LEASE_STATE_WAITING:
		lease.State = v1.LeaseState_LEASE_STATE_PENDING
	case pb.LeaseState_LEASE_STATE_APPROVED:
		lease.State = v1.LeaseState_LEASE_STATE_ACTIVE
	case pb.LeaseState_LEASE_STATE_DENIED:
		lease.State = v1.LeaseState_LEASE_STATE_DENIED
		if remote.Reply != "" {
			lease.Reply = c.signedReply(ctx, remote.RequestId)
		}
	case pb.LeaseState_LEASE_STATE_UNANSWERED:
		lease.State = v1.LeaseState_LEASE_STATE_UNANSWERED
	case pb.LeaseState_LEASE_STATE_CANCELLED:
		lease.State = v1.LeaseState_LEASE_STATE_CANCELLED
	case pb.LeaseState_LEASE_STATE_ENDED:
		lease.State = v1.LeaseState_LEASE_STATE_RELEASED
		if remote.NotAfterUnixSeconds > 0 && time.Now().Unix() >= remote.NotAfterUnixSeconds {
			lease.State = v1.LeaseState_LEASE_STATE_EXPIRED
		}
	default:
		return nil, errors.New("The relay returned an unknown request state.")
	}
	return lease, nil
}

// signedReply is the denial's words if a device signed them, else nothing.
func (c *Client) signedReply(ctx context.Context, requestID string) string {
	members, err := c.members(ctx)
	if err != nil {
		return ""
	}
	response, err := c.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_Collect{Collect: &pb.RequestReference{RequestId: requestID}}})
	if err != nil {
		return ""
	}
	answer, _, err := keyring.VerifiedAnswer(response.GetApproval(), members)
	if err != nil || answer.Choice != pb.Choice_CHOICE_DENY {
		return ""
	}
	return answer.Reply
}

func (c *Client) end(ctx context.Context, leaseID string) (*v1.Lease, error) {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return nil, err
	}
	saved := expected(state, leaseID)
	if saved == nil {
		return nil, errors.New("This machine has no request with that ID.")
	}
	if saved.AutomaticNotAfterUnixSeconds > 0 {
		if err := c.save(ctx, saved.Scope.RequestId, func(e *clientstate.ExpectedRequest) { e.Ended = true }); err != nil {
			return nil, err
		}
		return c.lease(ctx, leaseID)
	}
	response, err := c.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_End{End: &pb.RequestReference{RequestId: leaseID}}})
	if err != nil {
		return nil, err
	}
	return c.translate(ctx, saved.Scope, response.GetLease())
}

// openValues opens the login for an approved request on this machine: the
// device's delivery, checked against the pinned devices, or this machine's
// own copy of an Automatic login.
func (c *Client) openValues(ctx context.Context, lease *v1.Lease, _ *v1.Delivery) (*v1.CredentialValues, []string, error) {
	now := time.Now()
	state, err := c.Store.Load(ctx)
	if err != nil {
		return nil, nil, err
	}
	saved := expected(state, lease.LeaseId)
	if saved == nil {
		return nil, nil, errors.New("This machine has no request with that ID.")
	}
	var username, password string
	var sites []string
	var codes []*pb.TimedCode
	if saved.AutomaticNotAfterUnixSeconds > 0 {
		if saved.Ended || now.Unix() >= saved.AutomaticNotAfterUnixSeconds {
			return nil, nil, errors.New("This use of the Automatic login has ended. Ask again if the task still needs it.")
		}
		sealed, automaticSites := c.automaticCopy(ctx, saved.Scope.LoginId)
		if sealed == nil {
			return nil, nil, errors.New("This login is no longer Automatic for this machine. Ask again.")
		}
		secret, err := keyring.OpenLogin(sealed, c.receiving)
		if err != nil {
			return nil, nil, errors.New("This machine could not open its copy of the login.")
		}
		username, password = secret.Username, secret.Password
		if codes, err = keyring.OneTimeCodes(secret, now.Unix(), now.Unix()+1); err != nil {
			return nil, nil, err
		}
		sites = automaticSites
	} else {
		members, err := c.members(ctx)
		if err != nil {
			return nil, nil, err
		}
		response, err := c.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_Collect{Collect: &pb.RequestReference{RequestId: lease.LeaseId}}})
		if err != nil {
			return nil, nil, err
		}
		approval := response.GetApproval()
		request, err := keyring.ParseRequest(approval.GetRequest())
		if err != nil || request.RequestId != lease.LeaseId || request.MachineId != state.RecipientId || request.LoginId != saved.Scope.LoginId {
			return nil, nil, errors.New("The relay returned an approval for a different request.")
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
