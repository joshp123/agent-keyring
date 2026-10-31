// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package remote

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"syscall"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

type Client struct {
	Store       clientstate.Store
	Keys        *clientstate.PrivateKeys
	Certificate tls.Certificate
}

func Load(ctx context.Context, store clientstate.Store) (*Client, error) {
	state, err := store.Load(ctx)
	if err != nil {
		return nil, err
	}
	if state.RecipientId == "" || state.Approvers == nil || len(state.RelaySpki) == 0 {
		return nil, errors.New("This machine is not enrolled. Run 'agent-keyring enrol --name NAME --relay HOST:PORT'.")
	}
	keys, err := store.Keys(ctx, nil)
	if err != nil {
		return nil, err
	}
	certificate, err := tls.X509KeyPair(keys.CertificatePem, keys.TlsKeyPem)
	if err != nil {
		return nil, errors.New("Cannot read this machine's saved TLS identity.")
	}
	return &Client{store, keys, certificate}, nil
}
func (c *Client) Authority() authority.Client {
	return authority.Client{Exchange: c.exchange, OpenValues: c.OpenValues, Remote: true, State: c.Store}
}
func (c *Client) wire(ctx context.Context, request *pb.RelayWireRequest, receive func(*pb.RelayWireResponse) bool) error {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return err
	}
	config, err := relaycrypto.ClientConfig(c.Certificate, state.RelaySpki)
	if err != nil {
		return err
	}
	return stream(ctx, state.RelayAddress, config, request, receive)
}

var (
	tailnetIPv4 = netip.MustParsePrefix("100.64.0.0/10")
	tailnetIPv6 = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// Josh's logins only travel over the tailnet, so the client connects to its
// relay only at a tailnet address, or on this machine for local proofs. The
// check runs on the resolved address before connecting, so a tailnet name
// such as mac-mini works and a name that resolves elsewhere sends nothing.
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
func stream(ctx context.Context, address string, config *tls.Config, request *pb.RelayWireRequest, receive func(*pb.RelayWireResponse) bool) error {
	dialer := tls.Dialer{NetDialer: &net.Dialer{Timeout: 5 * time.Second, Control: refuseNonTailnetAddress}, Config: config}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return fmt.Errorf("Agent Keyring unreachable at %s: %w", address, err)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if err = authority.WriteFrame(conn, request); err != nil {
		return errors.New("Could not send the relay request. Rejoin the same lease after reconnecting.")
	}
	for {
		conn.SetReadDeadline(time.Now().Add(11 * time.Minute))
		response := new(pb.RelayWireResponse)
		if err = authority.ReadFrame(conn, response); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return errors.New("The relay connection ended before a result arrived. Rejoin the same request or lease; do not ask again.")
		}
		if failure := response.GetError(); failure != nil {
			return errors.New(failure.Message)
		}
		if !receive(response) || response.EndOfStream {
			return nil
		}
	}
}
func (c *Client) call(ctx context.Context, request *pb.RelayWireRequest) (*pb.RelayWireResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var result *pb.RelayWireResponse
	err := c.wire(ctx, request, func(response *pb.RelayWireResponse) bool { result = response; return false })
	return result, err
}
func (c *Client) refreshKeys(ctx context.Context) error {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return err
	}
	set, err := keySet(state.Approvers)
	if err != nil {
		return err
	}
	response, err := c.call(ctx, &pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetApproverKeyChain{GetApproverKeyChain: &pb.GetApproverKeyChainRequest{FromRevision: set.Revision}}})
	if err != nil {
		return err
	}
	chain := response.GetApproverKeyChain()
	if chain == nil {
		return errors.New("The relay did not return the signed approver key chain.")
	}
	return c.Store.Update(ctx, func(current *clientstate.State) error {
		latest, err := keySet(current.Approvers)
		if err != nil {
			return err
		}
		// Another CLI may have saved the same verified chain while this call waited.
		remaining := &pb.ApproverKeyChain{}
		for _, signed := range chain.KeySets {
			next, err := keySet(signed)
			if err != nil {
				return err
			}
			if next.Revision <= latest.Revision {
				if next.Revision == latest.Revision && !proto.Equal(signed, current.Approvers) {
					return errors.New("The relay returned conflicting approver keys.")
				}
				continue
			}
			remaining.KeySets = append(remaining.KeySets, signed)
		}
		return advanceKeys(current, remaining)
	})
}
func (c *Client) refreshConfiguration(ctx context.Context) error {
	response, err := c.call(ctx, &pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}})
	if err != nil {
		return err
	}
	var membershipError error
	err = c.Store.Update(ctx, func(state *clientstate.State) error {
		configuration, err := verifyConfiguration(state, response.GetConfiguration())
		if err != nil {
			return err
		}
		clientSPKI, err := relaycrypto.CertificateSPKI(c.Certificate)
		if err != nil {
			return err
		}
		receiver, err := ecdh.P256().NewPrivateKey(c.Keys.ReceiverPrivateKey)
		if err != nil {
			return err
		}
		enrolled := machine(configuration, state.RecipientId)
		if enrolled == nil || !bytesEqual(enrolled.TlsPublicKey, clientSPKI) || !bytesEqual(enrolled.ReceiverPublicKey, receiver.PublicKey().Bytes()) || enrolled.ReceiverKeyId != state.ReceiverKeyId {
			membershipError = errors.New("The current signed configuration no longer enrolls this machine's keys.")
		}
		state.Configuration = proto.Clone(response.GetConfiguration()).(*pb.SignedConfiguration)
		return nil
	})
	if err != nil {
		return err
	}
	return membershipError
}
func (c *Client) find(ctx context.Context, query string) (*pb.WireResponse, error) {
	if err := c.refreshKeys(ctx); err != nil {
		return nil, err
	}
	if err := c.refreshConfiguration(ctx); err != nil {
		return nil, err
	}
	state, err := c.Store.Load(ctx)
	if err != nil {
		return nil, err
	}
	configuration, err := verifyConfiguration(state, state.Configuration)
	if err != nil {
		return nil, err
	}
	results := &pb.FindLoginsResponse{MirrorRefreshedUnixSeconds: configuration.MirrorRefreshedUnixSeconds}
	query = strings.ToLower(query)
	for _, login := range configuration.Logins {
		if strings.Contains(strings.ToLower(strings.Join(append([]string{login.LoginId, login.Title, login.Account}, login.Sites...), " ")), query) {
			results.Logins = append(results.Logins, login)
		}
	}
	return &pb.WireResponse{Response: &pb.WireResponse_Logins{Logins: results}, EndOfStream: true}, nil
}
func validateLease(state *clientstate.State, lease *pb.Lease) error {
	scope, err := expected(state, lease.LeaseId)
	if err != nil {
		return err
	}
	if lease.LoginId != scope.LoginId || lease.Purpose != scope.Purpose || lease.TaskRef != scope.TaskRef || lease.Reason != scope.Reason || lease.GetRecipient().GetRecipientId() != scope.RecipientId || !proto.Equal(lease.Program, scope.Program) {
		return errors.New("The relay changed the saved scope of this lease.")
	}
	// Sites in relay status are metadata. Only a signed, opened bundle can
	// authorize browser delivery, so they cannot pass the pre-fill check.
	lease.Sites = nil
	return nil
}
func (c *Client) exchange(ctx context.Context, request *pb.WireRequest, receive func(*pb.WireResponse) bool) error {
	if find := request.GetFindLogins(); find != nil {
		result, err := c.find(ctx, find.Query)
		if err == nil {
			receive(result)
		}
		return err
	}
	if leaseRequest := request.GetRequestLease(); leaseRequest != nil {
		err := c.Store.Update(ctx, func(state *clientstate.State) error {
			leaseRequest.RecipientId = state.RecipientId
			for _, saved := range state.Requests {
				if saved.Scope.RequestId == leaseRequest.RequestId {
					if !proto.Equal(saved.Scope, leaseRequest) {
						return errors.New("That request ID already names a different task or program.")
					}
					return nil
				}
			}
			state.Requests = append(state.Requests, &clientstate.ExpectedRequest{Scope: proto.Clone(leaseRequest).(*pb.RequestLeaseRequest)})
			return nil
		})
		if err != nil {
			return err
		}
	}
	var transformError error
	err := c.wire(ctx, &pb.RelayWireRequest{Request: &pb.RelayWireRequest_Client{Client: request}}, func(relay *pb.RelayWireResponse) bool {
		response := relay.GetClient()
		if response == nil {
			transformError = errors.New("The relay returned no client result.")
			return false
		}
		if failure := response.GetError(); failure != nil {
			transformError = errors.New(failure.Message)
			return false
		}
		if lease := response.GetLease(); lease != nil {
			lease.Reply = ""        // Remote replies need their signed decision before display.
			lease.StatusLines = nil // Relay status prose must not carry unsigned instructions.
			canVerifyReply := lease.SignedDenial != nil && c.refreshKeys(ctx) == nil
			transformError = c.Store.Update(ctx, func(state *clientstate.State) error {
				if lease.LeaseId == "" {
					return errors.New("The relay returned no lease reference.")
				}
				if r := request.GetRequestLease(); r != nil {
					if _, err := expected(state, lease.LeaseId); err != nil {
						for _, saved := range state.Requests {
							if saved.Scope.RequestId == r.RequestId {
								saved.LeaseId = lease.LeaseId
								break
							}
						}
					}
				}
				if err := validateLease(state, lease); err != nil {
					return err
				}
				if canVerifyReply {
					lease.Reply = denialReply(state, lease)
				}
				return nil
			})
			if transformError != nil {
				return false
			}
		}
		return receive(response)
	})
	if transformError != nil {
		return transformError
	}
	return err
}
func createKeys(label string) (*clientstate.PrivateKeys, error) {
	cert, key, err := relaycrypto.NewIdentity(label)
	if err != nil {
		return nil, err
	}
	receiver, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return &clientstate.PrivateKeys{CertificatePem: cert, TlsKeyPem: key, ReceiverPrivateKey: receiver.Bytes()}, nil
}
func ValidateAddress(address string) error {
	host, port, err := net.SplitHostPort(address)
	portNumber, portError := strconv.ParseUint(port, 10, 16)
	if err != nil || host == "" || portError != nil || portNumber == 0 || strings.ContainsAny(host, "/@?#\\ \t\r\n") {
		return errors.New("Supply the relay as HOST:PORT, for example mac-mini:7443.")
	}
	return nil
}
func Enrol(ctx context.Context, store clientstate.Store, address, name string, output io.Writer) error {
	if strings.TrimSpace(name) == "" {
		return errors.New("Give this machine a name with --name NAME.")
	}
	state, err := store.Load(ctx)
	if err != nil {
		return err
	}
	if state.RecipientId != "" {
		if address != "" && state.RelayAddress != address {
			return errors.New("This machine is already enrolled with another relay. Keep its existing identity.")
		}
		fmt.Fprintln(output, "This machine is already enrolled as", state.MachineLabel+".")
		return nil
	}
	if address == "" {
		address = state.RelayAddress
	}
	if err = ValidateAddress(address); err != nil {
		return err
	}
	if state.RelayAddress != "" && state.RelayAddress != address {
		fmt.Fprintln(output, "Replacing the unfinished enrolment at", state.RelayAddress+".")
	}
	keys, err := store.Keys(ctx, func() (*clientstate.PrivateKeys, error) { return createKeys(name) })
	if err != nil {
		return err
	}
	cert, err := tls.X509KeyPair(keys.CertificatePem, keys.TlsKeyPem)
	if err != nil {
		return err
	}
	clientSPKI, err := relaycrypto.CertificateSPKI(cert)
	if err != nil {
		return err
	}
	receiver, err := ecdh.P256().NewPrivateKey(keys.ReceiverPrivateKey)
	if err != nil {
		return err
	}
	if err = store.Update(ctx, func(s *clientstate.State) error { s.RelayAddress = address; s.MachineLabel = name; return nil }); err != nil {
		return err
	}
	var observed []byte
	config := relaycrypto.ObservingClientConfig(cert, func(key []byte) error { observed = append([]byte(nil), key...); return nil })
	var result error
	approved := false
	var displayed []byte
	err = stream(ctx, address, config, &pb.RelayWireRequest{Request: &pb.RelayWireRequest_Enrol{Enrol: &pb.EnrolRequest{MachineLabel: name, ClientLabel: "agent-keyring", TlsPublicKey: clientSPKI, ReceiverPublicKey: receiver.PublicKey().Bytes()}}}, func(response *pb.RelayWireResponse) bool {
		status := response.GetEnrolStatus()
		if status == nil {
			result = errors.New("The relay returned no enrolment status.")
			return false
		}
		if status.ApproverKeySet != nil {
			if _, e := keySet(status.ApproverKeySet); e != nil {
				result = e
				return false
			}
			if !bytesEqual(displayed, status.ApproverKeySet.KeySet) {
				if displayed != nil {
					fmt.Fprintln(output, "The approver keys changed. Compare the new fingerprint from the start.")
				}
				displayed = append([]byte(nil), status.ApproverKeySet.KeySet...)
				fmt.Fprintln(output, "Compare every group with Agent Keyring on your approving device:")
				fmt.Fprintln(output, relaycrypto.Fingerprint(relaycrypto.EnrolTranscript(observed, clientSPKI, receiver.PublicKey().Bytes(), displayed)))
				fmt.Fprintln(output, "Approve this machine there only if all eight groups match. Waiting for approval.")
			}
		}
		switch status.State {
		case pb.EnrolState_ENROL_STATE_PENDING:
			return true
		case pb.EnrolState_ENROL_STATE_APPROVED:
			result = acceptEnrolment(ctx, store, status, displayed, observed, clientSPKI, receiver.PublicKey().Bytes())
			approved = result == nil
			return false
		case pb.EnrolState_ENROL_STATE_DENIED:
			result = errors.New("This machine's enrolment was denied.")
		case pb.EnrolState_ENROL_STATE_EXPIRED:
			result = errors.New("The enrolment timed out. Run enrol again when your approving device is available.")
		default:
			result = errors.New("The relay returned an unknown enrolment state.")
		}
		return false
	})
	if err != nil {
		return err
	}
	if result != nil {
		return result
	}
	if !approved {
		return errors.New("Enrolment ended before a signed approval arrived. Run the same enrol command to rejoin it.")
	}
	fmt.Fprintln(output, "Enrolled. Use find to choose a login, then lease it for your task.")
	return nil
}
func bytesEqual(a, b []byte) bool { return string(a) == string(b) }
func acceptEnrolment(ctx context.Context, store clientstate.Store, status *pb.EnrolStatus, compared, relaySPKI, clientSPKI, receiver []byte) error {
	if len(compared) == 0 || status.ApproverKeySet == nil || !bytesEqual(compared, status.ApproverKeySet.KeySet) {
		return errors.New("The enrolled approver keys do not match the compared fingerprint.")
	}
	if _, err := keySet(status.ApproverKeySet); err != nil {
		return err
	}
	receiverID := fmt.Sprintf("%x", relaycrypto.Hash(receiver))
	return store.Update(ctx, func(state *clientstate.State) error {
		if state.RecipientId != "" && state.RecipientId != status.RecipientId {
			return errors.New("Another enrolment already assigned this machine a different identity.")
		}
		state.Approvers = proto.Clone(status.ApproverKeySet).(*pb.SignedApproverKeySet)
		configuration, err := verifyConfiguration(state, status.Configuration)
		if err != nil {
			return err
		}
		enrolled := machine(configuration, status.RecipientId)
		if status.RecipientId == "" || enrolled == nil || !bytesEqual(enrolled.TlsPublicKey, clientSPKI) || !bytesEqual(enrolled.ReceiverPublicKey, receiver) || enrolled.ReceiverKeyId != receiverID {
			return errors.New("The signed configuration does not enroll this machine's keys.")
		}
		state.Configuration = proto.Clone(status.Configuration).(*pb.SignedConfiguration)
		state.RelaySpki = append([]byte(nil), relaySPKI...)
		state.RecipientId = enrolled.RecipientId
		state.ReceiverKeyId = receiverID
		return nil
	})
}
