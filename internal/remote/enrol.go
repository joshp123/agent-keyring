// Written by AI on 2026.11.18 by model claude opus 5.5; joining the Mac's door directly on 2026.11.21.
package remote

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/door"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"github.com/joshp123/agent-keyring/internal/tlsid"
	"google.golang.org/protobuf/proto"
)

// joinWithin is how long the Mac keeps a join open, from when it was first asked.
const joinWithin = 10 * time.Minute

// ParseInvite reads the link 'agent-keyring invite' printed on the Mac. The
// Mac's door must be a Tailscale IP address: a name may resolve anywhere.
func ParseInvite(link string) (*pb.JoinInvite, error) {
	encoded, ok := strings.CutPrefix(strings.TrimSpace(link), "agentkeyring://join?invite=")
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	invite := &pb.JoinInvite{}
	if !ok || err != nil || proto.Unmarshal(raw, invite) != nil || len(invite.Secret) != 32 {
		return nil, errors.New("That is not an invitation link. Run 'agent-keyring invite' on the Mac and pass the whole link.")
	}
	if invite.DoorHost == "" || invite.DoorPort == 0 || len(invite.DoorTlsPublicKey) == 0 {
		return nil, errors.New("This invitation is for the relay, which Agent Keyring no longer uses. Update the Mac app, then run 'agent-keyring invite' on the Mac again.")
	}
	if err := door.CheckHost(invite.DoorHost); err != nil {
		return nil, fmt.Errorf("This invitation names the Mac's door as %s. %v. Run 'agent-keyring invite' on the Mac again once Tailscale is running there.", invite.DoorHost, err)
	}
	if time.Now().Unix() >= invite.ExpiresUnixSeconds {
		return nil, errors.New("This invitation has expired. Run 'agent-keyring invite' on the Mac again.")
	}
	return invite, nil
}

// Enrol asks the Mac's door to join, with the invitation's proof, and waits
// until Josh approves on the Mac, refuses, or ten minutes pass. Interrupted,
// it withdraws the join. It trusts only that Mac's key and that inviter.
func Enrol(ctx context.Context, store clientstate.Store, invite *pb.JoinInvite, name string, output io.Writer) error {
	// Without Tailscale nothing can reach this computer, so say that first.
	if _, err := door.Address(); err != nil {
		return err
	}
	address := net.JoinHostPort(invite.DoorHost, strconv.Itoa(int(invite.DoorPort)))
	keys, err := store.Keys(ctx, func() (*clientstate.PrivateKeys, error) {
		certificate, key, err := tlsid.New("Agent Keyring machine")
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
		return err
	}
	client, err := fromKeys(keys)
	if err != nil {
		return err
	}
	spki, err := tlsid.SPKI(client.Certificate)
	if err != nil {
		return err
	}
	joining := &pb.Machine{MachineId: keyring.KeyID(spki), Label: name, TlsPublicKey: spki, ReceivingPublicKey: client.receiving.PublicKey().Bytes()}
	join := &pb.JoinRequest{Joining: &pb.JoinRequest_Machine{Machine: joining},
		RefusalKeySha256: keyring.SHA256(keyring.RefusalKey(invite.Secret, joining.MachineId))}
	join.Proof = keyring.JoinProof(invite.Secret, join)
	mac := macClient(client.Certificate, invite.DoorTlsPublicKey, nil)

	status, err := waitForJoin(ctx, mac, address, join, name, output)
	if err != nil {
		if ctx.Err() != nil {
			withdraw, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if macDo(withdraw, mac, http.MethodPost, address, "/v2/join/withdraw", join, nil) == nil {
				return errors.New("Stopped asking to join. The request on the Mac was withdrawn.")
			}
			return errors.New("Stopped asking to join. The Mac could not be told; its request ends by itself within 10 minutes.")
		}
		return err
	}
	switch status.GetState() {
	case pb.JoinState_JOIN_STATE_APPROVED:
	case pb.JoinState_JOIN_STATE_EXPIRED:
		return errors.New("Nobody approved this computer within 10 minutes. Run 'agent-keyring invite' on the Mac and enrol again.")
	case pb.JoinState_JOIN_STATE_WITHDRAWN:
		return errors.New("The Mac withdrew this join: another computer used the same invitation, so neither was shown. Run 'agent-keyring invite' on the Mac for a new link for each computer.")
	case pb.JoinState_JOIN_STATE_REFUSED:
		refusal := status.GetRefusal()
		if !hmac.Equal(refusal.GetReplyProof(), keyring.RefusalReplyProof(invite.Secret, joining.MachineId, refusal.GetReply())) {
			return errors.New("The Mac's door says this computer was denied, but the denial is not from the Mac that invited it.")
		}
		text := "Josh denied adding this computer."
		if refusal.Reply != "" {
			text += " Reply: " + printable(refusal.Reply)
		}
		return errors.New(text)
	default:
		return errors.New("This computer was not approved.")
	}

	members, err := keyring.VerifiedMembers(status.Members, nil)
	if err != nil || status.Members.SignerKeyId != invite.InviterKeyId {
		return errors.New("The approval is not signed by the Mac that invited this computer. Nothing was saved.")
	}
	listed, macListed := false, false
	for _, m := range members.Machines {
		listed = listed || (m.MachineId == joining.MachineId && bytes.Equal(m.TlsPublicKey, spki) && bytes.Equal(m.ReceivingPublicKey, joining.ReceivingPublicKey))
		macListed = macListed || bytes.Equal(m.TlsPublicKey, invite.DoorTlsPublicKey)
	}
	if !listed || !macListed {
		return errors.New("The approval does not list this computer's keys beside the Mac's. Nothing was saved.")
	}
	var credential []byte
	if sealed := status.GetPushCredential(); sealed != nil {
		if sealed.OpenerId != joining.MachineId {
			return errors.New("The Mac's push credential is sealed to another computer. Nothing was saved.")
		}
		if _, err := keyring.OpenPushCredential(sealed, client.receiving); err != nil {
			return errors.New("This computer cannot open the Mac's push credential. Nothing was saved.")
		}
		credential, _ = proto.Marshal(sealed)
	}
	raw, _ := proto.Marshal(status.Members)
	if err := store.Update(ctx, func(state *clientstate.State) error {
		state.RelayAddress, state.RelaySpki = "", nil
		state.MacDoor, state.MacTlsPublicKey, state.RecipientId, state.MachineLabel, state.Members = address, invite.DoorTlsPublicKey, joining.MachineId, name, raw
		state.PushCredential, state.Bundle, state.LocalAuthority = credential, nil, nil
		return nil
	}); err != nil {
		return err
	}
	client.Store, client.label = store, name
	client.log("joined machine=" + joining.MachineId)
	if _, err := client.refresh(ctx, 10*time.Second); err != nil {
		return err
	}
	fmt.Fprintf(output, "Joined as %q. Agents here can ask for passwords.\n", name)
	if credential == nil {
		fmt.Fprintln(output, "The Mac gave this computer no push credential, so its requests cannot reach Josh's iPhone or Apple Watch until the Mac has one and this computer enrols again.")
	}
	return nil
}

// waitForJoin posts the join and posts it again while it waits: the Mac
// answers each within 25 seconds. A Mac that cannot be reached at first is
// an error at once; one lost while waiting is tried again until the join
// would have expired.
func waitForJoin(ctx context.Context, mac *http.Client, address string, join *pb.JoinRequest, name string, output io.Writer) (*pb.JoinStatus, error) {
	started := time.Now()
	told, reached := false, false
	for {
		status := &pb.JoinStatus{}
		postCtx, cancel := context.WithTimeout(ctx, 40*time.Second)
		err := macDo(postCtx, mac, http.MethodPost, address, "/v2/join", join, status)
		cancel()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if err != nil {
			if !reached || strings.HasPrefix(err.Error(), "The Mac refused") {
				return nil, err
			}
			if time.Since(started) > joinWithin {
				return &pb.JoinStatus{State: pb.JoinState_JOIN_STATE_EXPIRED}, nil
			}
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(2 * time.Second):
			}
			continue
		}
		reached = true
		if status.State != pb.JoinState_JOIN_STATE_WAITING {
			return status, nil
		}
		if !told {
			fmt.Fprintf(output, "Waiting for Josh to approve %q on his Mac.\n", name)
			told = true
		}
	}
}
