// Written by AI on 2026.11.18 by model claude opus 5.5; joining with a code through the box relay on
// 2026.11.23; its update mailbox, and the Mac's door cut, on 2026.11.24.
package remote

import (
	"bytes"
	"cmp"
	"context"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/box"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"github.com/opentrawl/agent-keyring/internal/tlsid"
	"google.golang.org/protobuf/proto"
)

// joinWithin is how long the Mac or iPhone keeps a join open, from when it was first asked.
const joinWithin = 10 * time.Minute

// newMachine is this computer as it joins: its saved keys, made once, and
// the JoinRequest proving the code's secret.
func newMachine(ctx context.Context, store clientstate.ClientStateStore, name string, secret []byte) (*RemoteKeyringClient, *pb.Machine, *pb.JoinRequest, error) {
	keys, err := store.LoadOrCreateClientKeys(ctx, func() (*clientstate.PrivateKeys, error) {
		certificate, key, err := tlsid.GenerateDeviceTLSCertificate("Agent Keyring machine")
		if err != nil {
			return nil, err
		}
		receiving, err := ecdh.P256().GenerateKey(rand.Reader)
		if err != nil {
			return nil, err
		}
		return &clientstate.PrivateKeys{CertificatePem: certificate, TlsKeyPem: key, ReceiverPrivateKey: receiving.Bytes()}, nil
	})
	if err != nil {
		return nil, nil, nil, err
	}
	client, err := newRemoteClientFromKeys(keys)
	if err != nil {
		return nil, nil, nil, err
	}
	spki, err := tlsid.ExtractCertificateSPKI(client.Certificate)
	if err != nil {
		return nil, nil, nil, err
	}
	joining := &pb.Machine{MachineId: keyring.DeriveKeyID(spki), Label: name, TlsPublicKey: spki, ReceivingPublicKey: client.receiving.PublicKey().Bytes()}
	join := &pb.JoinRequest{Joining: &pb.JoinRequest_Machine{Machine: joining},
		RefusalKeySha256: keyring.ComputeSHA256(keyring.DeriveRefusalReplyKey(secret, joining.MachineId))}
	join.Proof = keyring.ComputeJoinProof(secret, join)
	return client, joining, join, nil
}

// EnrolWithCode joins through the box relay with a code from Add Another
// Computer on the Mac or iPhone. The JoinRequest goes in the code's request
// box, sealed with its key, and the Mac's answer comes back in its response
// box: only someone with the code can read or write either.
func EnrolComputerWithCode(ctx context.Context, store clientstate.ClientStateStore, code, name string, output io.Writer) error {
	secret, relay, err := box.ParseComputerJoinCodeOrLink(code)
	if err != nil {
		return err
	}
	relay, err = box.ValidateRelayBoxURL(cmp.Or(relay, os.Getenv("AGENT_KEYRING_RELAY_URL"), box.DefaultURL), loopbackTest())
	if err != nil {
		return err
	}
	keys := box.DeriveComputerJoinCodeKeys(secret)
	client, joining, join, err := newMachine(ctx, store, name, keys.Proof)
	if err != nil {
		return err
	}
	join.Challenge = make([]byte, 16)
	rand.Read(join.Challenge)
	raw, _ := proto.Marshal(join)
	boxes := box.NewRelayBoxClient(relay)
	asked := time.Now()
	if err := boxes.PutRelayBox(ctx, keys.RequestBox, keys.RequestKey, raw, box.RelayBoxPutOptions{}); errors.Is(err, box.ErrExists) {
		return errors.New("Another computer already used this code. Make a new one with Add Another Computer on the Mac or iPhone, one for each computer.")
	} else if err != nil {
		return err
	}
	// The request is already in its box. Keep waiting if progress output fails.
	_, _ = fmt.Fprintf(output, "Asked to add this computer. Waiting for the user to approve %q on the Mac or iPhone that showed the code, for up to 10 minutes.\n", name)
	_, _ = fmt.Fprintln(output, "If nothing appears there within a minute, the code was mistyped: stop this and enrol again with the code exactly as it is shown.")
	picked, err := boxes.WaitForRelayBox(ctx, keys.ResponseBox, keys.ResponseKey, "", asked, asked.Add(joinWithin+30*time.Second))
	switch {
	case ctx.Err() != nil:
		return errors.New("Stopped waiting to join. The request on the Mac ends by itself within 10 minutes.")
	case errors.Is(err, context.DeadlineExceeded):
		return errors.New("Nobody approved this computer within 10 minutes. Make a new code with Add Another Computer on the Mac or iPhone and enrol again.")
	case err != nil:
		return err
	}
	status := &pb.JoinStatus{}
	if proto.Unmarshal(picked.Message, status) != nil {
		return errors.New("The answer is unreadable. Update the app and this command together.")
	}
	client.Store, client.label = store, name
	credential, err := client.keepJoin(ctx, status, joining, relay, join.Challenge, keys.Proof)
	if err != nil {
		return err
	}
	// Read: the answer may go. A delete that fails only leaves it to expire.
	if err := boxes.AcknowledgeRelayBox(ctx, picked, ""); err != nil {
		client.appendRemoteEventLog("join answer not deleted error=" + strconv.Quote(err.Error()))
	}
	printEnrolmentSuccess(output, name, credential)
	return nil
}

func (client *RemoteKeyringClient) keepJoin(ctx context.Context, status *pb.JoinStatus, joining *pb.Machine, relay string, challenge, proof []byte) ([]byte, error) {
	if !hmac.Equal(status.Challenge, challenge) {
		return nil, errors.New("The answer is not for this request to join. Nothing was saved. Make a new code with Add Another Computer on the Mac or iPhone and enrol again.")
	}
	if err := joinOutcome(status, proof, joining.MachineId, "Make a new code with Add Another Computer on the Mac or iPhone and enrol again."); err != nil {
		return nil, err
	}
	_, credential, err := checkApproval(status, client, joining)
	if err != nil {
		return nil, err
	}
	mailbox := status.GetMailbox()
	if len(mailbox.GetSeed()) != 32 || len(mailbox.GetReadAuth()) < 32 || mailbox.GetMachineId() != joining.MachineId {
		return nil, errors.New("The approval has no update mailbox for this computer. Update the app on the Mac or iPhone, then enrol again.")
	}
	mailbox.WriteAuth = "" // The devices' alone.
	members, _ := proto.Marshal(status.Members)
	if err := client.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		state.BoxUrl, state.RecipientId, state.MachineLabel, state.Members = relay, joining.MachineId, client.label, members
		state.PushCredential, state.Bundle, state.LocalAuthority, state.CatalogueRevision = credential, nil, nil, 0
		state.ApnsToken, state.ApnsTokenIssuedUnixSeconds = "", 0
		state.Mailbox, state.FreshUntilUnixSeconds, state.Removed = mailbox, 0, false
		return nil
	}); err != nil {
		return nil, err
	}

	client.appendRemoteEventLog("joined machine=" + joining.MachineId + " route=box")
	if status.Bundle != nil {
		if err := client.keepBundle(ctx, status.Bundle, false); err != nil {
			return nil, err
		}
	}
	return credential, nil
}

func printEnrolmentSuccess(output io.Writer, name string, credential []byte) {
	// Enrolment has already been saved even if the output has closed.
	_, _ = fmt.Fprintf(output, "Joined as %q. Agents here can ask for passwords.\n", name)
	if credential == nil && pushRelayURL() == "" {
		_, _ = fmt.Fprintln(output, "The Mac gave this computer no push credential, so its requests cannot reach the user's iPhone or Apple Watch until the Mac has one and this computer enrols again.")
	}
}

func joinOutcome(status *pb.JoinStatus, secret []byte, machineID, again string) error {
	switch status.GetState() {
	case pb.JoinState_JOIN_STATE_APPROVED:
		return nil
	case pb.JoinState_JOIN_STATE_EXPIRED:
		return errors.New("Nobody approved this computer within 10 minutes. " + again)
	case pb.JoinState_JOIN_STATE_WITHDRAWN:
		return errors.New("The join was withdrawn. " + again)
	case pb.JoinState_JOIN_STATE_REFUSED:
		refusal := status.GetRefusal()
		if !hmac.Equal(refusal.GetReplyProof(), keyring.ComputeRefusalReplyProof(secret, machineID, refusal.GetReply())) {
			return errors.New("The answer says this computer was denied, but the denial is not from the device that showed the code.")
		}
		text := "The user denied adding this computer."
		if refusal.Reply != "" {
			text += " Reply: " + sanitizeRemoteLogText(refusal.Reply)
		}
		return errors.New(text)
	default:
		return errors.New("This computer was not approved.")
	}
}

// checkApproval checks an approval lists exactly this computer's keys, signed
// by a device it lists, and that the push credential is this computer's.
func checkApproval(status *pb.JoinStatus, client *RemoteKeyringClient, joining *pb.Machine) (*pb.Members, []byte, error) {
	members, err := keyring.VerifySignedMembers(status.Members, nil)
	if err != nil {
		return nil, nil, errors.New("The approval is not signed by a device it lists. Nothing was saved.")
	}
	listed := false
	for _, m := range members.Machines {
		listed = listed || (m.MachineId == joining.MachineId && bytes.Equal(m.TlsPublicKey, joining.TlsPublicKey) && bytes.Equal(m.ReceivingPublicKey, joining.ReceivingPublicKey))
	}
	if !listed {
		return nil, nil, errors.New("The approval does not list this computer's keys. Nothing was saved.")
	}
	sealed := status.GetPushCredential()
	if sealed == nil {
		return members, nil, nil
	}
	if sealed.OpenerId != joining.MachineId {
		return nil, nil, errors.New("The Mac's push credential is sealed to another computer. Nothing was saved.")
	}
	if _, err := keyring.OpenPushCredential(sealed, client.receiving); err != nil {
		return nil, nil, errors.New("This computer cannot open the Mac's push credential. Nothing was saved.")
	}
	credential, _ := proto.Marshal(sealed)
	return members, credential, nil
}
