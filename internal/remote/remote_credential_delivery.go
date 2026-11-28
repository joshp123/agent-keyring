// Written by AI on 2026.11.27 by model claude opus 5.5.
package remote

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

// findLogins sends the catalogue's logins whose words hold every word asked for.
func (c *RemoteKeyringClient) findLogins(ctx context.Context, query string, receive func(*pb.AgentResponse) bool) error {
	current, err := c.refreshRemoteCatalogue(ctx)
	if err != nil {
		return err
	}
	result := &pb.FindLoginsResponse{}
	words := strings.Fields(strings.ToLower(query))
	for _, login := range current.catalogue.GetLogins() {
		text := strings.ToLower(login.Title + " " + login.Account + " " + strings.Join(login.Sites, " ") + " " + login.LoginId)
		if slices.ContainsFunc(words, func(word string) bool { return !strings.Contains(text, word) }) {
			continue
		}
		result.Logins = append(result.Logins, login)
	}
	receive(&pb.AgentResponse{Response: &pb.AgentResponse_Logins{Logins: result}, EndOfStream: true})
	return nil
}

func terminalLease(state pb.LeaseState) bool {
	switch state {
	case pb.LeaseState_LEASE_STATE_DENIED,
		pb.LeaseState_LEASE_STATE_UNANSWERED,
		pb.LeaseState_LEASE_STATE_ENDED, pb.LeaseState_LEASE_STATE_EXPIRED, pb.LeaseState_LEASE_STATE_RELEASED,
		pb.LeaseState_LEASE_STATE_CANCELLED:
		return true
	}
	return false
}

func staleTerminalRequest(request *clientstate.ExpectedRequest, now int64) bool {
	lease := request.GetLease()
	if lease == nil || !terminalLease(lease.State) {
		return false
	}
	endedAt := max(lease.AnswerByUnixSeconds, lease.NotAfterUnixSeconds)
	return endedAt > 0 && now-endedAt > 24*60*60
}

func pruneTerminalRequests(state *clientstate.State, now int64) {
	state.Requests = slices.DeleteFunc(state.Requests, func(request *clientstate.ExpectedRequest) bool {
		return staleTerminalRequest(request, now)
	})
}

// hasFreshCatalogue is true while this computer may use its Automatic copies on its own:
// until its newest Freshness (keyring.proto, "Update mailboxes").
func hasFreshCatalogue(state *clientstate.State) bool {
	return time.Now().Unix() < state.FreshUntilUnixSeconds
}

var errStale = errors.New("This computer has not heard from the user's Mac or iPhone for a week, so it no longer uses Automatic passwords on its own. Lease again: the request goes to the user, and their approval brings this computer's lists up to date.")

func allowsAutomatic(members *pb.Members, machineID string) bool {
	for _, m := range members.GetMachines() {
		if m.MachineId == machineID {
			return true
		}
	}
	return false
}

// openedRemoteCredential is a password opened on this computer, with the codes for its time.
type openedRemoteCredential struct {
	username, password string
	sites              []string
	codes              []*pb.TimedCode
	now                time.Time
}

// openValues opens the password for an approved request on this computer:
// the device's delivery, checked against the newest Members held, or this
// computer's own copy of an Automatic password. First it checks the
// approval's grant at the relay (checkNotStopped).
func (c *RemoteKeyringClient) openValues(ctx context.Context, lease *pb.Lease, _ *pb.LocalCredentialDelivery) (*pb.CredentialValues, []string, error) {
	saved, err := c.settleRemoteLease(ctx, lease.RequestId)
	if err != nil {
		return nil, nil, err
	}
	if saved.Lease.State == pb.LeaseState_LEASE_STATE_APPROVED {
		if err := c.checkNotStopped(ctx, lease.RequestId); err != nil {
			return nil, nil, err
		}
		if saved, err = c.settleRemoteLease(ctx, lease.RequestId); err != nil {
			return nil, nil, err
		}
	}
	if err := ensureStillActive(saved); err != nil {
		return nil, nil, err
	}
	var result *openedRemoteCredential
	if saved.Lease.Automatic {
		result, err = c.openAutomatic(ctx, lease.RequestId)
	} else {
		result, err = c.openApproval(ctx, saved)
	}
	if err != nil {
		return nil, nil, err
	}
	values := &pb.CredentialValues{Username: result.username, Password: result.password}
	for _, code := range result.codes {
		if code.ValidFromUnixSeconds <= result.now.Unix() && result.now.Unix() < code.ValidUntilUnixSeconds {
			values.OneTimeCode = code.Code
		}
	}
	return values, result.sites, nil
}

// openAutomatic opens this computer's own copy of an Automatic password,
// while the password is still Automatic for it and its lists are fresh.
func (c *RemoteKeyringClient) openAutomatic(ctx context.Context, leaseID string) (*openedRemoteCredential, error) {
	current, err := c.refreshRemoteCatalogue(ctx)
	if err != nil {
		return nil, err
	}
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return nil, err
	}
	if !hasFreshCatalogue(state) {
		return nil, errStale
	}
	saved := findSavedLeaseRequest(state, leaseID)
	if err := ensureStillActive(saved); err != nil {
		return nil, err
	}
	now := time.Now()
	if saved.Lease.NotAfterUnixSeconds > 0 && now.Unix() >= saved.Lease.NotAfterUnixSeconds {
		return nil, errors.New("This lease has expired. Lease again if the task still needs the password.")
	}
	listed := current.findCatalogueLogin(saved.Scope.LoginId)
	var sealed *pb.SealedLogin
	if listed != nil && listed.Rule == pb.Rule_RULE_AUTOMATIC && allowsAutomatic(current.members, saved.Scope.RecipientId) {
		sealed = current.copyFor(saved.Scope.RecipientId, listed.LoginId)
	}
	if sealed == nil || keyring.VerifySealedLogin(sealed, current.members, listed) != nil {
		return nil, errors.New("This password is no longer Automatic for this computer. Ask again.")
	}
	secret, err := keyring.OpenSealedLogin(sealed, c.receiving)
	if err != nil || keyring.VerifyOpenedLoginBinding(secret, listed) != nil {
		return nil, errors.New("This computer could not open its copy of the password.")
	}
	codes, err := keyring.GenerateTOTPCodes(secret, now.Unix(), now.Unix()+1)
	if err != nil {
		return nil, err
	}
	return &openedRemoteCredential{username: secret.Username, password: secret.Password, sites: listed.Sites, codes: codes, now: now}, nil
}

// openApproval opens a device's delivery. An approval given before the user
// blocked the password is not used once this computer knows: from its update
// mailbox now, or its last catalogue if the relay does not answer in time.
func (c *RemoteKeyringClient) openApproval(ctx context.Context, saved *clientstate.ExpectedRequest) (*openedRemoteCredential, error) {
	current, err := c.refreshRemoteCatalogue(ctx)
	if err != nil {
		return nil, err
	}
	if err := loginAccessPolicyError(current.findCatalogueLogin(saved.Scope.LoginId)); err != nil {
		return nil, err
	}
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return nil, err
	}
	saved = findSavedLeaseRequest(state, saved.LeaseId)
	if err := ensureStillActive(saved); err != nil {
		return nil, err
	}
	now := time.Now()
	members, err := parseMembers(state.Members)
	if err != nil {
		return nil, err
	}
	approval := &pb.Approval{}
	if proto.Unmarshal(saved.Approval, approval) != nil || !ownRequest(approval, saved) {
		return nil, errors.New("This computer's saved approval is unreadable. Lease again.")
	}
	contents, err := keyring.OpenApprovedCredential(approval, members, c.receiving, now)
	if err != nil {
		return nil, fmt.Errorf("This approval could not be checked or opened: %w", err)
	}
	return &openedRemoteCredential{username: contents.Username, password: contents.Password, sites: contents.Sites, codes: contents.OneTimeCodes, now: now}, nil
}

func ensureStillActive(saved *clientstate.ExpectedRequest) error {
	if saved == nil {
		return errors.New("This lease is not approved. Check it with 'agent-keyring status'.")
	}
	switch saved.Lease.GetState() {
	case pb.LeaseState_LEASE_STATE_APPROVED:
		return nil
	case pb.LeaseState_LEASE_STATE_RELEASED:
		return errors.New("This lease was released. Lease again if the task still needs the password.")
	case pb.LeaseState_LEASE_STATE_ENDED:
		if by := saved.Lease.EndedBy; by != "" {
			return fmt.Errorf("This lease has ended: The user stopped it on %s. Lease again only if the task still needs the password.", sanitizeRemoteLogText(by))
		}
		return errors.New("This lease has ended. Lease again only if the task still needs the password.")
	case pb.LeaseState_LEASE_STATE_EXPIRED:
		return errors.New("This lease has expired. Lease again if the task still needs the password.")
	}
	return errors.New("This lease is not approved. Check it with 'agent-keyring status'.")
}

// unusable says why agents may not ask for or use a login, as the signed
// catalogue lists it: not listed, Blocked, or its password deleted when it was
// Blocked (version 0) and not copied from Passwords since. Nil if they may.
func loginAccessPolicyError(login *pb.Login) error {
	switch {
	case login == nil:
		return errors.New("No such password. Use 'agent-keyring find' for its login ID.")
	case login.Rule == pb.Rule_RULE_BLOCKED:
		return errors.New("This password is blocked for agents.")
	case login.Version == 0:
		return errors.New("This password was deleted from Agent Keyring when it was blocked. Ask the user to copy their passwords again from Passwords, then ask again.")
	}
	return nil
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

func findLoginDenialHold(state *clientstate.State, loginID string) *clientstate.Hold {
	for _, h := range state.Holds {
		if h.LoginId == loginID {
			return h
		}
	}
	return nil
}

// holdOff records a denial and returns when this computer may ask again.
func holdOff(state *clientstate.State, loginID, reply string, now time.Time) int64 {
	h := findLoginDenialHold(state, loginID)
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
	message := "The user denied this password for this computer. Ask again after " + time.Unix(h.UntilUnixSeconds, 0).Format("15:04:05") +
		" (in " + wait.Round(time.Second).String() + ")."
	if h.Reply != "" {
		message += " Their reply, word for word: \"" + sanitizeRemoteLogText(h.Reply) + "\""
	}
	return message
}
