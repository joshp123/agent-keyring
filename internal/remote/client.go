// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Package remote is the command's side of the relay on a machine that is not
// the MacBook (proto/agentkeyring/v2/keyring.proto). It keeps the command's
// local interface (agentkeyring.v1 WireRequest) so agents see no change, asks
// the relay in version 2, and opens what a device approved with this
// machine's own receiving key. Nothing it receives is trusted until checked
// against the Members this machine pinned when it joined.
package remote

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"syscall"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"github.com/joshp123/agent-keyring/internal/tlsid"
	"github.com/joshp123/agent-keyring/internal/wire"
	"google.golang.org/protobuf/proto"
)

type Client struct {
	Store       clientstate.Store
	Certificate tls.Certificate
	receiving   *ecdh.PrivateKey
}

func Load(ctx context.Context, store clientstate.Store) (*Client, error) {
	state, err := store.Load(ctx)
	if err != nil {
		return nil, err
	}
	if state.RecipientId == "" || len(state.Members) == 0 || len(state.RelaySpki) == 0 {
		return nil, errors.New("This machine has not joined. Run 'agent-keyring enrol --name NAME --relay HOST:PORT'.")
	}
	keys, err := store.Keys(ctx, nil)
	if err != nil {
		return nil, err
	}
	client, err := fromKeys(keys)
	if err != nil {
		return nil, err
	}
	client.Store = store
	return client, nil
}

func fromKeys(keys *clientstate.PrivateKeys) (*Client, error) {
	certificate, err := tls.X509KeyPair(keys.CertificatePem, keys.TlsKeyPem)
	if err != nil {
		return nil, errors.New("Cannot read this machine's saved TLS identity.")
	}
	receiving, err := ecdh.P256().NewPrivateKey(keys.ReceiverPrivateKey)
	if err != nil {
		return nil, errors.New("Cannot read this machine's saved receiving key.")
	}
	return &Client{Certificate: certificate, receiving: receiving}, nil
}

func (c *Client) Authority() authority.Client {
	return authority.Client{Exchange: c.exchange, OpenValues: c.openValues, Remote: true, State: c.Store}
}

var (
	tailnetIPv4 = netip.MustParsePrefix("100.64.0.0/10")
	tailnetIPv6 = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// Logins travel only over the tailnet: the command connects to its relay only
// at a tailnet address, or on this machine for tests. The check runs on the
// resolved address, so a tailnet name works and a name that resolves
// elsewhere sends nothing.
func refuseNonTailnetAddress(_, address string, _ syscall.RawConn) error {
	addressAndPort, err := netip.ParseAddrPort(address)
	if err != nil {
		return err
	}
	ip := addressAndPort.Addr().Unmap()
	if tailnetIPv4.Contains(ip) || tailnetIPv6.Contains(ip) || ip.IsLoopback() {
		return nil
	}
	return fmt.Errorf("%s is not a tailnet address; Agent Keyring only reaches its relay over the tailnet", ip)
}

func ValidateAddress(address string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil || host == "" || port == "" {
		return errors.New("Supply the relay as HOST:PORT.")
	}
	return nil
}

func stream(ctx context.Context, address string, config *tls.Config, request *pb.RelayRequest, receive func(*pb.RelayResponse) bool) error {
	dialer := tls.Dialer{NetDialer: &net.Dialer{Timeout: 5 * time.Second, Control: refuseNonTailnetAddress}, Config: config}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return fmt.Errorf("Cannot reach the relay at %s: %w", address, err)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if err = wire.Write(conn, request); err != nil {
		return errors.New("Could not send the request to the relay.")
	}
	for {
		conn.SetReadDeadline(time.Now().Add(11 * time.Minute))
		response := &pb.RelayResponse{}
		if err = wire.Read(conn, response); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if errors.Is(err, io.EOF) {
				return errors.New("The relay closed the connection before answering. Rejoin the same request; do not ask again.")
			}
			return errors.New("The relay connection ended before a result arrived. Rejoin the same request; do not ask again.")
		}
		if failure := response.GetError(); failure != nil {
			return errors.New(failure.Message)
		}
		if !receive(response) || response.EndOfStream {
			return nil
		}
	}
}

func (c *Client) relay(ctx context.Context, request *pb.RelayRequest, receive func(*pb.RelayResponse) bool) error {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return err
	}
	return stream(ctx, state.RelayAddress, tlsid.Client(c.Certificate, state.RelaySpki, nil), request, receive)
}

func (c *Client) call(ctx context.Context, request *pb.RelayRequest) (*pb.RelayResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var result *pb.RelayResponse
	err := c.relay(ctx, request, func(response *pb.RelayResponse) bool { result = response; return false })
	if err == nil && result == nil {
		err = errors.New("The relay returned nothing.")
	}
	return result, err
}

// members returns the pinned Members, first taking any newer revision the
// relay has that a pinned device signed.
func (c *Client) members(ctx context.Context) (*pb.Members, error) {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return nil, err
	}
	pinned, err := parseMembers(state.Members)
	if err != nil {
		return nil, err
	}
	response, err := c.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_MembersSince{MembersSince: pinned.Revision}})
	if err != nil {
		return pinned, nil // Checking needs only the pinned devices.
	}
	// Each revision must be signed by a device of the one before it.
	current, latest := pinned, []byte(nil)
	for _, document := range response.GetMembersChain().GetRevisions() {
		next, err := keyring.VerifiedMembers(document, current)
		if err != nil {
			break
		}
		current = next
		latest, _ = proto.Marshal(document)
	}
	if latest != nil {
		if err := c.Store.Update(ctx, func(state *clientstate.State) error { state.Members = latest; return nil }); err != nil {
			return nil, err
		}
	}
	return current, nil
}

func parseMembers(raw []byte) (*pb.Members, error) {
	signed := &pb.Signed{}
	members := &pb.Members{}
	if proto.Unmarshal(raw, signed) != nil || proto.Unmarshal(signed.Payload, members) != nil {
		return nil, errors.New("This machine's saved list of devices is unreadable. Enrol it again.")
	}
	return members, nil
}

// ParseInvite reads the link 'agentkeyring invite' printed on the Mac.
func ParseInvite(link string) (*pb.JoinInvite, error) {
	encoded, ok := strings.CutPrefix(strings.TrimSpace(link), "agentkeyring://join?invite=")
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	invite := &pb.JoinInvite{}
	if !ok || err != nil || proto.Unmarshal(raw, invite) != nil || invite.RelayHost == "" || len(invite.Secret) != 32 {
		return nil, errors.New("That is not an invitation link. Run 'agent-keyring invite' on the Mac and pass the whole link.")
	}
	if time.Now().Unix() >= invite.ExpiresUnixSeconds {
		return nil, errors.New("This invitation has expired. Run 'agent-keyring invite' on the Mac again.")
	}
	return invite, nil
}

// Enrol asks to join with an invitation's proof and waits until Josh approves
// on the device that invited it. It trusts only that relay and that device.
func Enrol(ctx context.Context, store clientstate.Store, invite *pb.JoinInvite, name string, output io.Writer) error {
	address := net.JoinHostPort(invite.RelayHost, strconv.Itoa(int(invite.RelayPort)))
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
	join := &pb.JoinRequest{Joining: &pb.JoinRequest_Machine{Machine: joining}}
	join.Proof = keyring.JoinProof(invite.Secret, join)
	var observed []byte
	var status *pb.JoinStatus
	err = stream(ctx, address, tlsid.PinnedByHash(client.Certificate, invite.RelayTlsSha256, &observed),
		&pb.RelayRequest{Method: &pb.RelayRequest_Join{Join: join}},
		func(response *pb.RelayResponse) bool {
			status = response.GetJoin()
			if status.GetState() == pb.JoinState_JOIN_STATE_WAITING {
				fmt.Fprintf(output, "Waiting for Josh to approve %q on his Mac.\n", name)
			}
			return status.GetState() == pb.JoinState_JOIN_STATE_WAITING
		})
	if err != nil {
		return err
	}
	switch status.GetState() {
	case pb.JoinState_JOIN_STATE_APPROVED:
	case pb.JoinState_JOIN_STATE_EXPIRED:
		return errors.New("Nobody approved this machine within 10 minutes. Run 'agent-keyring invite' on the Mac and enrol again.")
	default:
		return errors.New("This machine was not approved.")
	}
	members, err := keyring.VerifiedMembers(status.Members, nil)
	if err != nil || status.Members.SignerKeyId != invite.InviterKeyId {
		return errors.New("The approval is not signed by the device that invited this machine. Nothing was saved.")
	}
	listed := false
	for _, m := range members.Machines {
		listed = listed || (m.MachineId == joining.MachineId && bytes.Equal(m.TlsPublicKey, spki) && bytes.Equal(m.ReceivingPublicKey, joining.ReceivingPublicKey))
	}
	if !listed || !bytes.Equal(members.RelayTlsPublicKey, observed) {
		return errors.New("The approval does not list this machine's keys with this relay. Nothing was saved.")
	}
	raw, _ := proto.Marshal(status.Members)
	if err := store.Update(ctx, func(state *clientstate.State) error {
		state.RelayAddress, state.RelaySpki, state.RecipientId, state.MachineLabel, state.Members = address, observed, joining.MachineId, name, raw
		state.LocalAuthority = nil
		return nil
	}); err != nil {
		return err
	}
	fmt.Fprintf(output, "Joined as %q. Agents here can ask for logins.\n", name)
	return nil
}
