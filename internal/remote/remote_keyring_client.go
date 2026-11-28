// Written by AI on 2026.11.18 by model claude opus 5.5; direct, with no relay, on 2026.11.21; the doors cut on 2026.11.24.
//
// Package remote is the command on a computer without the Mac app: Linux, a
// Mac mini. It answers the command's AgentRequest messages and keeps the lists from its update
// mailbox and from each answer, pushes each request to Josh's devices itself,
// picks up their answers from the request's answer box at the relay, and
// opens what a device approved with this computer's own receiving key.
// Nothing it receives is trusted until checked against the Members this
// computer holds (proto/agentkeyring/v2/keyring.proto, "Boxes").
package remote

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/tls"
	"errors"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/authority"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

type RemoteKeyringClient struct {
	Store       clientstate.ClientStateStore
	Certificate tls.Certificate // This machine's identity: it signs requests with its key.
	receiving   *ecdh.PrivateKey
	label       string
}

var errEnrol = errors.New("This computer has not joined. Run 'agent-keyring enrol --name NAME --code CODE' with a code from Add Another Computer on the Mac or iPhone.")

func LoadRemoteKeyringClient(ctx context.Context, store clientstate.ClientStateStore) (*RemoteKeyringClient, error) {
	state, err := store.LoadClientState(ctx)
	if err != nil {
		return nil, err
	}
	if state.RecipientId != "" && state.BoxUrl == "" {
		return nil, errors.New("This computer joined over Tailscale, which Agent Keyring no longer uses. Enrol it again with 'agent-keyring enrol --name NAME --code CODE' and a code from Add Another Computer on the Mac or iPhone.")
	}
	if state.RecipientId == "" || len(state.Members) == 0 {
		return nil, errEnrol
	}
	keys, err := store.LoadOrCreateClientKeys(ctx, nil)
	if err != nil {
		return nil, err
	}
	client, err := newRemoteClientFromKeys(keys)
	if err != nil {
		return nil, err
	}
	client.Store, client.label = store, state.MachineLabel
	return client, nil
}

func newRemoteClientFromKeys(keys *clientstate.PrivateKeys) (*RemoteKeyringClient, error) {
	certificate, err := tls.X509KeyPair(keys.CertificatePem, keys.TlsKeyPem)
	if err != nil {
		return nil, errors.New("Cannot read this machine's saved signing key.")
	}
	receiving, err := ecdh.P256().NewPrivateKey(keys.ReceiverPrivateKey)
	if err != nil {
		return nil, errors.New("Cannot read this machine's saved receiving key.")
	}
	return &RemoteKeyringClient{Certificate: certificate, receiving: receiving}, nil
}

func (c *RemoteKeyringClient) BuildRemoteAuthority() authority.KeyringAuthorityClient {
	return authority.KeyringAuthorityClient{Exchange: c.dispatchRemoteAuthorityRequest, OpenValues: c.openValues, Remote: true, State: c.Store}
}

func (c *RemoteKeyringClient) appendRemoteEventLog(event string) {
	c.Store.AppendClientLog(c.label, event)
}

// loopbackTest is AGENT_KEYRING_TEST_LOOPBACK=1, set only by end-to-end
// tests: their relay is plain HTTP on loopback (box.ValidateRelayBoxURL still refuses
// it anywhere else), Apple is a stand-in, and the push relay is off.
func loopbackTest() bool { return os.Getenv("AGENT_KEYRING_TEST_LOOPBACK") == "1" }

// ---- The lists ----------------------------------------------------------------

// remoteCatalogueView is what this computer holds from Josh's devices, each part checked.
type remoteCatalogueView struct {
	members       *pb.Members
	catalogue     *pb.Catalogue
	registrations map[string]*pb.PushRegistration // Device key id: its newest.
	copies        []*pb.SealedLogin
}

func (v *remoteCatalogueView) findCatalogueLogin(loginID string) *pb.Login {
	for _, login := range v.catalogue.GetLogins() {
		if login.LoginId == loginID {
			return login
		}
	}
	return nil
}

func (v *remoteCatalogueView) findCatalogueDevice(keyID string) *pb.Device {
	for _, device := range v.members.GetDevices() {
		if device.KeyId == keyID {
			return device
		}
	}
	return nil
}

func (v *remoteCatalogueView) copyFor(openerID, loginID string) *pb.SealedLogin {
	for _, sealed := range v.copies {
		if sealed.OpenerId == openerID && sealed.LoginId == loginID {
			return sealed
		}
	}
	return nil
}

func parseMembers(raw []byte) (*pb.Members, error) {
	signed := &pb.Signed{}
	members := &pb.Members{}
	if proto.Unmarshal(raw, signed) != nil || proto.Unmarshal(signed.Payload, members) != nil {
		return nil, errors.New("This computer's saved list of devices is unreadable. Enrol it again.")
	}
	return members, nil
}

// loadSavedCatalogueView is the view from the saved state alone.
func loadSavedCatalogueView(state *clientstate.State) (*remoteCatalogueView, error) {
	members, err := parseMembers(state.Members)
	if err != nil {
		return nil, err
	}
	v := &remoteCatalogueView{members: members, registrations: map[string]*pb.PushRegistration{}}
	bundle := &pb.Bundle{}
	if proto.Unmarshal(state.Bundle, bundle) != nil {
		return v, nil
	}
	if catalogue := (&pb.Catalogue{}); bundle.Catalogue != nil && proto.Unmarshal(bundle.Catalogue.Payload, catalogue) == nil {
		v.catalogue = catalogue
	}
	for _, signed := range bundle.PushRegistrations {
		registration := &pb.PushRegistration{}
		if proto.Unmarshal(signed.Payload, registration) == nil {
			v.registrations[registration.DeviceKeyId] = registration
		}
	}
	v.copies = bundle.Copies
	return v, nil
}

// refreshRemoteCatalogue reads this computer's update mailbox (readMailbox), within
// mailboxLimit, and returns the lists it then holds. A relay out of reach
// leaves what it held.
func (c *RemoteKeyringClient) refreshRemoteCatalogue(ctx context.Context) (*remoteCatalogueView, error) {
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return nil, err
	}
	if state.Mailbox != nil && !state.Removed {
		c.readMailbox(ctx, state)
		if state, err = c.Store.LoadClientState(ctx); err != nil {
			return nil, err
		}
	}
	if state.Removed {
		return nil, errRemoved
	}
	return loadSavedCatalogueView(state)
}

// keepBundle checks a bundle's parts: the lists by their signatures and
// revisions, each copy by its signer and the catalogue's version, the
// freshness by its signer. A Members chain that checks is always taken, so a
// removal is never held back. A catalogue or freshness that does not check, or
// a catalogue of the revision held that differs from it, refuses everything
// else in the bundle: it extends no freshness, its catalogue and copies are not
// kept, and keepBundle returns an error, so its mailbox slot is not deleted. A
// list older than the one held is no fault: another device's mailbox brought
// the newer one. A copy or push registration that does not check (one from a
// device removed since, or for another version) is dropped on its own. merge
// is a bundle from an answer or the update mailbox, not the join's: the copies
// it brings go before those held, which are checked again against its lists
// and kept. A Members that leaves this computer out removes it: every copy and
// approval it holds goes (keyring.proto, "Update mailboxes").
func (c *RemoteKeyringClient) keepBundle(ctx context.Context, bundle *pb.Bundle, merge bool) error {
	var refused error
	err := c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		members, err := c.keepMembers(state, bundle)
		if err != nil {
			return err
		}
		if !allowsAutomatic(members, state.RecipientId) {
			markRemoteComputerRemoved(state)
			c.appendRemoteEventLog(fmt.Sprintf("removed members=%d", members.Revision))
			return nil
		}
		// Commit verified Members even if the rest of the bundle is refused.
		refused = c.keepBundleParts(state, bundle, members, merge)
		return nil
	})
	if err != nil {
		return err
	}
	return refused
}

func (c *RemoteKeyringClient) keepMembers(state *clientstate.State, bundle *pb.Bundle) (*pb.Members, error) {
	current := &pb.Signed{}
	members := &pb.Members{}
	if proto.Unmarshal(state.Members, current) != nil || proto.Unmarshal(current.Payload, members) != nil {
		return nil, errors.New("This computer's saved list of devices is unreadable. Enrol it again.")
	}
	// Each revision since the one held is checked against the one before
	// it, so a list signed by a device added since still checks. A conflicting
	// historical revision at the same number is remembered and refused unless a
	// later revision verified against trusted membership supersedes it.
	var memberConflict error
	for _, document := range slices.Concat(bundle.MembersSince, []*pb.Signed{bundle.Members}) {
		if document == nil {
			continue
		}
		next, err := keyring.VerifySignedMembers(document, members)
		if errors.Is(err, keyring.ErrStale) {
			cand := &pb.Members{}
			if proto.Unmarshal(document.GetPayload(), cand) == nil && cand.Revision == members.Revision && !bytes.Equal(document.GetPayload(), current.GetPayload()) {
				memberConflict = fmt.Errorf("members refused revision=%d: another list of the same revision is held", cand.Revision)
			}
			continue
		}
		if err != nil {
			// Record the failure without returning early: a later revision in the bundle
			// (such as a removal) may still verify directly against our last trusted Members.
			if memberConflict == nil {
				memberConflict = fmt.Errorf("members refused: %w", err)
			}
			continue
		}
		members = next
		current = document
		memberConflict = nil
		state.Members, err = proto.Marshal(document)
		if err != nil {
			return nil, err
		}
		c.appendRemoteEventLog(fmt.Sprintf("members taken revision=%d", next.Revision))
	}
	if memberConflict != nil {
		return nil, memberConflict
	}
	return members, nil
}

func (c *RemoteKeyringClient) keepBundleParts(state *clientstate.State, bundle *pb.Bundle, members *pb.Members, merge bool) error {
	old := &pb.Bundle{}
	if err := proto.Unmarshal(state.Bundle, old); err != nil {
		c.appendRemoteEventLog("saved bundle unreadable error=" + strconv.Quote(err.Error()))
		old.Reset() // Continue with a verified update and keep the revision floor.
	}
	catalogue, document, err := c.selectCatalogue(old.Catalogue, bundle.Catalogue, members, state.CatalogueRevision)
	if err != nil {
		return err
	}
	var fresh *pb.Freshness
	if bundle.Freshness != nil {
		fresh, err = keyring.VerifySignedFreshness(bundle.Freshness, members, state.RecipientId, time.Now())
		if err != nil {
			return fmt.Errorf("freshness refused: %w", err)
		}
		if fresh.MembersRevision > members.Revision || fresh.CatalogueRevision > max(catalogue.Revision, state.CatalogueRevision) {
			return errors.New("freshness refused: it vouches for lists newer than the ones held")
		}
	}
	registrations, copies := bundle.PushRegistrations, bundle.Copies
	if merge {
		registrations = slices.Concat(old.PushRegistrations, registrations)
		// A newer copy of a password takes the place of the one held.
		copies = slices.Concat(copies, old.Copies)
	}
	kept := &pb.Bundle{
		Catalogue:         document,
		PushRegistrations: c.keepRegistrations(registrations, members),
		Copies:            c.keepCopies(copies, members, catalogue, state.RecipientId),
	}
	data, err := proto.Marshal(kept)
	if err != nil {
		return err
	}
	state.Bundle = data
	if document != nil && document != old.Catalogue {
		state.CatalogueRevision = catalogue.Revision
	}
	if fresh != nil && fresh.ValidUntilUnixSeconds > state.FreshUntilUnixSeconds {
		state.FreshUntilUnixSeconds = fresh.ValidUntilUnixSeconds
	}
	return nil
}

func (c *RemoteKeyringClient) selectCatalogue(old, incoming *pb.Signed, members *pb.Members, revision uint64) (*pb.Catalogue, *pb.Signed, error) {
	catalogue := &pb.Catalogue{}
	if old != nil {
		if err := proto.Unmarshal(old.Payload, catalogue); err != nil {
			c.appendRemoteEventLog("saved catalogue unreadable error=" + strconv.Quote(err.Error()))
			catalogue.Reset()
			old = nil
		}
	}
	if incoming == nil || old != nil && bytes.Equal(old.Payload, incoming.Payload) {
		// Already held, even if the device that signed it has since been removed.
		return catalogue, old, nil
	}
	candidate := &pb.Catalogue{}
	if old != nil && proto.Unmarshal(incoming.Payload, candidate) == nil && candidate.Revision < revision {
		c.appendRemoteEventLog(fmt.Sprintf("catalogue older revision=%d held=%d", candidate.Revision, revision))
		return catalogue, old, nil
	}
	next, err := keyring.VerifySignedCatalogue(incoming, members, nil)
	switch {
	case err != nil:
		return nil, nil, fmt.Errorf("catalogue refused: %w", err)
	case next.Revision < revision:
		c.appendRemoteEventLog(fmt.Sprintf("catalogue older revision=%d held=%d", next.Revision, revision))
		return catalogue, old, nil
	case next.Revision == revision && old != nil:
		return nil, nil, fmt.Errorf("catalogue refused revision=%d: another catalogue of the same revision is held", next.Revision)
	default:
		return next, incoming, nil
	}
}

func (c *RemoteKeyringClient) keepRegistrations(registrations []*pb.Signed, members *pb.Members) []*pb.Signed {
	newest := map[string]*pb.Signed{}
	registered := map[string]int64{}
	for _, signed := range registrations {
		registration, err := checkRegistration(signed, members)
		if err != nil {
			c.appendRemoteEventLog("push registration refused error=" + strconv.Quote(err.Error()))
			continue
		}
		prev, hasPrev := newest[registration.DeviceKeyId]
		prevTime := registered[registration.DeviceKeyId]
		if !hasPrev || registration.RegisteredUnixSeconds > prevTime ||
			(registration.RegisteredUnixSeconds == prevTime && bytes.Compare(signed.Payload, prev.Payload) > 0) {
			newest[registration.DeviceKeyId], registered[registration.DeviceKeyId] = signed, registration.RegisteredUnixSeconds
		}
	}
	var kept []*pb.Signed
	for _, signed := range newest {
		kept = append(kept, signed)
	}
	return kept
}

func (c *RemoteKeyringClient) keepCopies(copies []*pb.SealedLogin, members *pb.Members, catalogue *pb.Catalogue, recipient string) []*pb.SealedLogin {
	var kept []*pb.SealedLogin
	listed := map[string]*pb.Login{}
	for _, login := range catalogue.Logins {
		listed[login.LoginId] = login
	}
	seen := map[string]bool{}
	for _, sealed := range copies {
		if seen[sealed.LoginId] {
			continue
		}
		// This computer's own copy only, of a password still Automatic: one switched back to Ask goes.
		listedLogin := listed[sealed.LoginId]
		if sealed.OpenerId != recipient || listedLogin.GetRule() != pb.Rule_RULE_AUTOMATIC ||
			keyring.VerifySealedLogin(sealed, members, listedLogin) != nil {
			c.appendRemoteEventLog("copy refused login=" + sealed.LoginId)
			continue
		}
		seen[sealed.LoginId] = true
		kept = append(kept, sealed)
	}
	return kept
}

// markRemoteComputerRemoved forgets everything a removed computer held: its copies, the
// catalogue, and every approval, which it releases.
func markRemoteComputerRemoved(state *clientstate.State) {
	state.Removed, state.FreshUntilUnixSeconds, state.Bundle = true, 0, nil
	now := time.Now().Unix()
	for _, request := range state.Requests {
		request.Approval = nil
		switch request.Lease.GetState() {
		case pb.LeaseState_LEASE_STATE_WAITING:
			request.Lease.State = pb.LeaseState_LEASE_STATE_CANCELLED
			request.Lease.EndedAtUnixSeconds = now
		case pb.LeaseState_LEASE_STATE_APPROVED:
			request.Lease.State = pb.LeaseState_LEASE_STATE_RELEASED
			request.Lease.EndedAtUnixSeconds = now
		}
	}
}

var errRemoved = errors.New("The user removed this computer from their devices, so every password and approval it held is gone. To use it again, enrol it again with a new code from Add Another Computer on the Mac or iPhone.")

// checkRegistration accepts a push registration signed by the reply key of
// the device it names, or for an Apple Watch by its iPhone's.
func checkRegistration(signed *pb.Signed, members *pb.Members) (*pb.PushRegistration, error) {
	registration := &pb.PushRegistration{}
	if proto.Unmarshal(signed.GetPayload(), registration) != nil || registration.Domain != keyring.PushDomain {
		return nil, keyring.ErrWrongDomain
	}
	signer, err := keyring.VerifySignedDocument(signed, members, true)
	if err != nil {
		return nil, err
	}
	if signed.SignerKeyId != signer.ReplyKeyId {
		return nil, keyring.ErrNotAllowed
	}
	for _, device := range members.Devices {
		if device.KeyId == registration.DeviceKeyId &&
			(device.KeyId == signer.KeyId || (device.Kind == pb.DeviceKind_DEVICE_KIND_WATCH && signer.Kind == pb.DeviceKind_DEVICE_KIND_IPHONE)) {
			return registration, nil
		}
	}
	return nil, keyring.ErrNotAllowed
}

// ---- Logs ---------------------------------------------------------------------

// ReadRemoteDeviceLogs is this computer's own lines, in time order.
func (c *RemoteKeyringClient) ReadRemoteDeviceLogs(since int64, requestID string) []string {
	var kept []string
	cutoff := time.Unix(since, 0).UTC().Format("2006-01-02T15:04:05.000Z")
	for _, line := range c.Store.ReadClientLogLines() {
		if line == "" || (since > 0 && line < cutoff) || (requestID != "" && !strings.Contains(line, requestID)) {
			continue
		}
		kept = append(kept, line)
	}
	sortLines(kept)
	return kept
}

func sortLines(lines []string) {
	for i := 1; i < len(lines); i++ {
		for j := i; j > 0 && lines[j] < lines[j-1]; j-- {
			lines[j], lines[j-1] = lines[j-1], lines[j]
		}
	}
}

// sanitizeRemoteLogText replaces control characters, so words from a device cannot
// rewrite the agent's terminal.
func sanitizeRemoteLogText(value string) string {
	return strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return ' '
		}
		return r
	}, value)
}
