// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package authority

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"google.golang.org/protobuf/proto"
)

const MaxFrame = 1 << 20

type KeyringAuthorityClient struct {
	Socket     string
	Start      func(context.Context) error
	Exchange   func(context.Context, *pb.AgentRequest, func(*pb.AgentResponse) bool) error
	OpenValues func(context.Context, *pb.Lease, *pb.LocalCredentialDelivery) (*pb.CredentialValues, []string, error)
	Remote     bool
	State      clientstate.ClientStateStore
}

func WriteSocketFrame(w io.Writer, message proto.Message) error {
	data, err := proto.Marshal(message)
	if err != nil {
		return err
	}
	if len(data) == 0 || len(data) > MaxFrame {
		return errors.New("invalid message size")
	}
	framed := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(framed, uint32(len(data)))
	copy(framed[4:], data)
	for len(framed) > 0 {
		n, err := w.Write(framed)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		framed = framed[n:]
	}
	return nil
}
func ReadSocketFrame(r io.Reader, message proto.Message) error {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return err
	}
	size := binary.BigEndian.Uint32(header[:])
	if size == 0 || size > MaxFrame {
		return errors.New("invalid message size")
	}
	data := make([]byte, size)
	defer clear(data)
	if _, err := io.ReadFull(r, data); err != nil {
		return err
	}
	return proto.Unmarshal(data, message)
}
func (c KeyringAuthorityClient) CallKeyringAuthority(ctx context.Context, request *pb.AgentRequest) (*pb.AgentResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var result *pb.AgentResponse
	err := c.StreamKeyringAuthority(ctx, request, func(response *pb.AgentResponse) bool { result = response; return false })
	return result, err
}
func (c KeyringAuthorityClient) StreamKeyringAuthority(ctx context.Context, request *pb.AgentRequest, receive func(*pb.AgentResponse) bool) error {
	if c.Exchange != nil {
		return c.Exchange(ctx, request, receive)
	}
	conn, err := c.connectAuthoritySocket(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	if err := conn.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return err
	}
	if err = WriteSocketFrame(conn, request); err != nil {
		return errors.New("Could not send the request. Rejoin an existing lease with 'status LEASE --wait'.")
	}
	for {
		if err := conn.SetReadDeadline(time.Now().Add(11 * time.Minute)); err != nil {
			return err
		}
		response := new(pb.AgentResponse)
		if err = ReadSocketFrame(conn, response); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return errors.New("The connection ended before a result arrived. Rejoin the same lease; do not request approval again.")
		}
		if failure := response.GetError(); failure != nil {
			return fmt.Errorf("%s", failure.Message)
		}
		if response.Response == nil {
			return errors.New("Agent Keyring returned an empty response. Update the app and CLI together.")
		}
		if !receive(response) || response.EndOfStream {
			return nil
		}
	}
}
func (c KeyringAuthorityClient) connectAuthoritySocket(ctx context.Context) (net.Conn, error) {
	conn, err := (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "unix", c.Socket)
	if err != nil && c.Start != nil {
		if startError := c.Start(ctx); startError != nil {
			return nil, startError
		}
		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		for err != nil {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-deadline.C:
				return nil, errors.New("Agent Keyring started, but its local connection is not ready. Try the same command again.")
			case <-time.After(100 * time.Millisecond):
				conn, err = (&net.Dialer{Timeout: time.Second}).DialContext(ctx, "unix", c.Socket)
			}
		}
	}
	if err != nil {
		return nil, errors.New("Cannot connect to Agent Keyring. Open the app, then run this command again.")
	}
	return conn, nil
}

func (c KeyringAuthorityClient) FetchAuthorityLease(ctx context.Context, id string) (*pb.Lease, error) {
	r, e := c.CallKeyringAuthority(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: id}}})
	if e != nil {
		return nil, e
	}
	if r.GetLease() == nil {
		return nil, errors.New("Agent Keyring did not return a lease.")
	}
	return r.GetLease(), nil
}
func (c KeyringAuthorityClient) DeliverAuthorityCredential(ctx context.Context, request *pb.DeliverRequest) (*pb.LocalCredentialDelivery, error) {
	response, err := c.CallKeyringAuthority(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_Deliver{Deliver: request}})
	if err != nil {
		return nil, err
	}
	if response.GetDelivery() == nil {
		return nil, errors.New("Agent Keyring did not return a delivery.")
	}
	return response.GetDelivery(), nil
}
